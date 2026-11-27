#!/usr/bin/env bash
# ============================================================================
# AWS EKS — load kubeconfig contexts
# ============================================================================
# Contract: on exit, kubectl has contexts named exactly $CLUSTER1 and $CLUSTER2
# (as derived in config.sh). Steps 02-05 rely on those names.
# Run from anywhere. HOST ONLY — needs aws auth.
# ============================================================================

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common/lib.sh"

re_load_config

re_log "🔑 Configuring kubectl for EKS"

for pair in "$CLUSTER1:$AWS_REGION1" "$CLUSTER2:$AWS_REGION2"; do
  cluster="${pair%%:*}"
  region="${pair##*:}"

  re_log "📍 $cluster ($region)"
  # --alias sets the context name directly, avoiding the default ARN name.
  re_run aws eks update-kubeconfig \
    --name "$cluster" --region "$region" --alias "$cluster" \
    || re_die "failed to get credentials for $cluster in $region"

  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$cluster" \
    || re_die "context '$cluster' not present after update-kubeconfig"
  re_log "✅ context $cluster ready"
done

re_log "✅ kubectl configured for $CLUSTER1 and $CLUSTER2"
