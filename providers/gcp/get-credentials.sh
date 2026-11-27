#!/usr/bin/env bash
# ============================================================================
# GCP GKE — load kubeconfig contexts
# ============================================================================
# Contract: on exit, kubectl has contexts named exactly $CLUSTER1 and $CLUSTER2
# (as derived in config.sh). Steps 02-05 rely on those names.
# Run from anywhere. HOST ONLY — needs gcloud auth.
# ============================================================================

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common/lib.sh"

re_load_config

re_log "🔑 Configuring kubectl for GKE (project $GCP_PROJECT_ID)"

for pair in "$CLUSTER1:$GCP_REGION1" "$CLUSTER2:$GCP_REGION2"; do
  cluster="${pair%%:*}"
  region="${pair##*:}"

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

re_log "✅ kubectl configured for $CLUSTER1 and $CLUSTER2"
