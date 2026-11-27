#!/usr/bin/env bash
# ============================================================================
# Delete all resources (multi-cloud)
# ============================================================================
# Removes K8s workloads, DNS records and the cloud infrastructure.
# All Terraform input comes from config.sh via re_export_tf_vars — which is
# why GCP teardown now works (project_id used to be unset, so `tofu destroy`
# could not run and resources leaked).
#
# Run from anywhere:  ./scripts/delete-all-resources.sh
# Log:                debug/delete-all-resources-<timestamp>.log
#
# HOST ONLY — needs cloud credentials. Never run inside the VM.
# ============================================================================

set -uo pipefail   # NOT -e: teardown must continue past individual failures.

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

re_load_config
re_log_init "delete-all-resources"

total_start=$SECONDS
FAILED=0

re_log "🗑️  Deleting all resources on $CLOUD_PROVIDER"

# Pin the cloud identity and (re)load kubeconfig BEFORE touching Kubernetes.
# Otherwise kubectl/gcloud use whatever account is globally active, cannot
# reach the cluster, and the PVCs / LoadBalancer are silently never deleted.
re_cloud_select_account
bash "$REPO_ROOT/providers/$CLOUD_PROVIDER/get-credentials.sh" >/dev/null 2>&1 \
  || re_warn "could not load kubeconfig for $CLOUD_PROVIDER (clusters may already be gone)"

re_log "🧹 Cleaning up Kubernetes resources (ordered, bounded — see re_k8s_teardown)"
# Phase 1 on BOTH clusters first: an RERC can only be finalised while the REC
# it points at still exists, so no cluster may lose its REC before every RERC
# is gone.
for CLUSTER in "$CLUSTER1" "$CLUSTER2"; do
  re_k8s_teardown "$CLUSTER" crs || true
done
for CLUSTER in "$CLUSTER1" "$CLUSTER2"; do
  re_k8s_teardown "$CLUSTER" infra
  rc=$?
  if [ "$rc" -eq 3 ]; then
    # Unreachable is fine ONLY if the cluster no longer exists.
    re_cluster_in_state; st=$?
    if [ "$st" -eq 2 ]; then
      re_warn "$CLUSTER: unreachable and the Terraform state cannot be read — cannot tell whether the"
      re_warn "   cluster still exists: PVC disks and the ingress LoadBalancer may be orphaned"
      FAILED=$((FAILED + 1))
    elif [ "$st" -eq 0 ]; then
      re_warn "$CLUSTER: still in Terraform state but unreachable — PVC disks and the"
      re_warn "   ingress LoadBalancer may be orphaned (see the disk check at the end)"
      FAILED=$((FAILED + 1))
    fi
  elif [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
  fi
done

re_log "🌐 Cleaning up DNS records"
# CURRENT names AND LEGACY ones. Before the 2026-09-07 rename the wildcard was
# *.<cloud cluster name>; now it is *.<REC name>. Covering both is what stops
# a rename from orphaning records forever — the teardown would otherwise no
# longer know the old names, and nothing else would ever remove them.
# A missing record is not an error here, hence `|| true`.
DNS_TARGETS="$REC_NAME1 $REC_NAME2 $CLUSTER1 $CLUSTER2"
case $CLOUD_PROVIDER in
  azure)
    for C in $DNS_TARGETS; do
      re_run az network dns record-set a delete \
        -g "$DNS_RESOURCE_GROUP" -z "$DNS_ZONE" -n "*.$C" -y || true
    done
    ;;
  aws)
    # shellcheck source=/dev/null
    . "$REPO_ROOT/common/dns-aws.sh"
    for C in $DNS_TARGETS; do
      re_run delete_dns_record "$DNS_ZONE" "*.$C" || true
    done
    ;;
  gcp)
    # shellcheck source=/dev/null
    . "$REPO_ROOT/common/dns-gcp.sh"
    for C in $DNS_TARGETS; do
      re_run delete_dns_record "$DNS_ZONE" "$GCP_PROJECT_ID" "*.$C" || true
    done
    ;;
esac

# GKE's LoadBalancer firewall rules survive the cluster and would block the
# VPC deletion. Clear them up front rather than discovering it 9 minutes in.
re_gcp_clean_orphan_firewalls

re_log "🔥 Destroying infrastructure with OpenTofu"

re_export_tf_vars
re_dump_tf_vars

cd "$REPO_ROOT/providers/$CLOUD_PROVIDER" || re_die "no provider directory for $CLOUD_PROVIDER"

re_tofu_init >/dev/null 2>&1 || re_warn "tofu init failed; destroy may not work"
re_tofu_destroy || FAILED=$((FAILED + 1))


# CSI-provisioned disks are named pvc-<uuid> and are NOT in Terraform state.
# If a PVC was not deleted before its cluster, the disk survives and bills.
if [ "$CLOUD_PROVIDER" = "gcp" ]; then
  re_log "🔎 Checking for orphaned persistent disks"
  orphans=$(gcloud compute disks list --project "$GCP_PROJECT_ID" \
    --filter="name~^pvc- AND users.len()=0 AND (zone~$GCP_REGION1 OR zone~$GCP_REGION2)" \
    --format='value(name,zone,sizeGb)' 2>/dev/null || true)
  if [ -n "$orphans" ]; then
    re_warn "orphaned disks still billing (Terraform does not know them):"
    printf '%s\n' "$orphans" | sed 's/^/       /' >&2
    re_warn "   Re-running --destroy will NOT remove them: Terraform has no"
    re_warn "   record of them. Delete each one explicitly:"
    printf '%s\n' "$orphans" | while read -r d z _; do
      [ -n "$d" ] || continue
      re_warn "     gcloud compute disks delete $d --zone=${z##*/} --project $GCP_PROJECT_ID --quiet"
    done
    re_warn "   (not deleted automatically: on a shared project another"
    re_warn "    operator's detached pvc-* disk would match the same filter)"
    FAILED=$((FAILED + 1))
  else
    re_log "  ✅ no orphaned pvc-* disks"
  fi
fi

elapsed=$((SECONDS - total_start))
re_log "════════════════════════════════════════"
re_log "⏱️  Teardown finished in $((elapsed / 60))m $((elapsed % 60))s"
if [ "$FAILED" -gt 0 ]; then
  re_warn "$FAILED step(s) failed — resources may remain."
  re_warn "Verify with:  ./check-tags.sh   (expect 0 resources found)"
  exit 1
fi

re_log "✅ Teardown complete. Verify with: ./check-tags.sh --expect-empty"