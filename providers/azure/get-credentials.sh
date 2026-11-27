#!/usr/bin/env bash
# ============================================================================
# Azure AKS — load kubeconfig contexts
# ============================================================================
# Contract: on exit, kubectl has contexts named exactly $CLUSTER1 and $CLUSTER2
# (as derived in config.sh). Steps 02-05 rely on those names.
# Run from anywhere. HOST ONLY — needs az auth.
# ============================================================================

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/common/lib.sh"

re_load_config

re_log "🔑 Configuring kubectl for AKS (resource group $AZURE_CLUSTER_RESOURCE_GROUP)"

for cluster in "$CLUSTER1" "$CLUSTER2"; do
  re_log "📍 $cluster"
  re_run az aks get-credentials \
    --resource-group "$AZURE_CLUSTER_RESOURCE_GROUP" \
    --name "$cluster" --context "$cluster" --overwrite-existing \
    || re_die "failed to get credentials for $cluster"

  kubectl config get-contexts -o name 2>/dev/null | grep -qx "$cluster" \
    || re_die "context '$cluster' not present after get-credentials"
  re_log "✅ context $cluster ready"
done

re_log "✅ kubectl configured for $CLUSTER1 and $CLUSTER2"
