#!/usr/bin/env bash
# ============================================================================
# k9s-cluster.sh — open k9s on one of the two clusters
# ============================================================================
# Usage:
#   ./scripts/k9s-cluster.sh            # cluster 1, namespace $NS
#   ./scripts/k9s-cluster.sh 2          # cluster 2
#   ./scripts/k9s-cluster.sh 1 default  # explicit namespace
#   ./scripts/k9s-cluster.sh --list     # show the contexts and exit
#
# Why a wrapper rather than `k9s --context ...` directly:
# a GKE kubeconfig authenticates through the gke-gcloud-auth-plugin, which
# resolves the CURRENTLY ACTIVE gcloud account. Our deploy scripts pin the
# account from config.sh (GCP_ACCOUNT) for their own process only, so a bare
# k9s can end up authenticating as a different identity than the one that
# created the cluster — and fail with a confusing RBAC/permission error.
# This wrapper exports the same account for k9s.
#
# HOST ONLY — needs a kubeconfig. Read-only by itself; k9s can of course edit.
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

re_load_config

case "${1:-1}" in
  --list|-l)
    echo "Contexts for this deployment:"
    printf '  1  %s  (%s)\n' "$CLUSTER1" "$REGION1"
    printf '  2  %s  (%s)\n' "$CLUSTER2" "$REGION2"
    echo
    echo "Present in your kubeconfig:"
    for c in "$CLUSTER1" "$CLUSTER2"; do
      if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$c"; then
        echo "  ✅ $c"
      else
        echo "  ❌ $c  — run: ./scripts/01-create-cluster.sh (or providers/$CLOUD_PROVIDER/get-credentials.sh)"
      fi
    done
    exit 0 ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  1) CTX="$CLUSTER1" ;;
  2) CTX="$CLUSTER2" ;;
  *) CTX="$1" ;;   # allow a full context name
esac
NAMESPACE="${2:-$NS}"

if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX"; then
  echo "context '$CTX' is not in your kubeconfig." >&2
  echo "Available:" >&2
  kubectl config get-contexts -o name 2>/dev/null | sed 's/^/  /' >&2
  echo "Load them with: bash providers/$CLOUD_PROVIDER/get-credentials.sh" >&2
  exit 1
fi

command -v k9s >/dev/null 2>&1 || {
  echo "k9s not found. Install it:  brew install derailed/k9s/k9s" >&2
  exit 1
}

# GKE also needs the auth plugin; without it kubectl fails cryptically.
if [ "$CLOUD_PROVIDER" = "gcp" ] && ! command -v gke-gcloud-auth-plugin >/dev/null 2>&1; then
  echo "⚠️  gke-gcloud-auth-plugin not found — GKE auth will fail." >&2
  echo "   gcloud components install gke-gcloud-auth-plugin" >&2
fi

# Pin the same identity the deploy used, so the auth plugin does not silently
# authenticate as whatever account happens to be globally active.
re_cloud_select_account

echo "⛓️  k9s → context '$CTX', namespace '$NAMESPACE'"
echo "    :ctx to switch cluster · :ns to switch namespace · :q to quit"
exec k9s --context "$CTX" -n "$NAMESPACE"
