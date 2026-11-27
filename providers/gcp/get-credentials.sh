#!/usr/bin/env bash
# ============================================================================
# GCP GKE — load kubeconfig contexts
# ============================================================================
# Contract: on exit, kubectl has contexts named exactly after the selected clusters
# ($CLUSTER1 and/or $CLUSTER2 as derived in config.sh; RE_CLUSTERS, see re_selected_indexes).
# Steps 02-05 rely on those names.
# Run from anywhere. HOST ONLY — needs gcloud auth.
# ============================================================================

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common/lib.sh"

re_load_config
re_resolve_clusters   # standalone: only the clusters that exist (RE_CLUSTERS set by a deploy wins)

re_log "🔑 Configuring kubectl for GKE (project $GCP_PROJECT_ID)"

selected=$(re_selected_indexes) || exit 2
for idx in $selected; do
  cluster="$(re_cluster_name "$idx")"
  region="$(re_region_of "$idx")"

  re_log "📍 $cluster ($region)"
  re_run gcloud container clusters get-credentials "$cluster" \
    --region "$region" --project "$GCP_PROJECT_ID" \
    || re_die "failed to get credentials for $cluster in $region"

  # gcloud names the context gke_<project>_<region>_<cluster>; normalise it.
  gke_ctx="gke_${GCP_PROJECT_ID}_${region}_${cluster}"
  if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$gke_ctx"; then
    kubectl config rename-context "$gke_ctx" "$cluster" >/dev/null 2>&1 || true
  fi

  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$cluster" \
    || re_die "context '$cluster' not present after get-credentials"
  re_log "✅ context $cluster ready"
done

re_log "✅ kubectl configured for: $(for i in $selected; do printf '%s ' "$(re_cluster_name "$i")"; done)"
