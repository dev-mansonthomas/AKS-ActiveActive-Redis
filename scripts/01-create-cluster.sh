#!/usr/bin/env bash
# ============================================================================
# 01 — Create the two Kubernetes clusters (multi-cloud)
# ============================================================================
# Dispatches on CLOUD_PROVIDER, provisions with OpenTofu, then loads kubectl
# credentials. All Terraform input comes from config.sh via re_export_tf_vars.
#
# Run from anywhere:  ./scripts/01-create-cluster.sh
# Log:                debug/01-create-cluster-<timestamp>.log
#
# HOST ONLY — needs cloud credentials. Never run inside the VM.
# ============================================================================

set -euo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

re_load_config
re_log_init "01-create-cluster"

re_log "🚀 Creating Kubernetes clusters on $CLOUD_PROVIDER"

# Export every TF_VAR_* Terraform needs, straight from config.sh.
re_export_tf_vars
re_log "Terraform inputs:"
re_dump_tf_vars

PROVIDER_DIR="$REPO_ROOT/providers/$CLOUD_PROVIDER"
[ -d "$PROVIDER_DIR" ] || re_die "no provider directory: $PROVIDER_DIR"
cd "$PROVIDER_DIR"

case "$CLOUD_PROVIDER" in
  azure) re_log "📍 Azure AKS in $AZURE_REGION1 / $AZURE_REGION2" ;;
  aws)   re_log "📍 AWS EKS $AWS_EKS_VERSION in $AWS_REGION1 / $AWS_REGION2" ;;
  gcp)
    re_log "📍 GCP GKE, cluster(s) $(re_selected_indexes) in $(for i in $(re_selected_indexes); do printf '%s ' "$(re_region_of "$i")"; done)(project $GCP_PROJECT_ID)"
    re_run gcloud config set project "$GCP_PROJECT_ID"
    ;;
esac

re_tofu_init || re_die "tofu init failed after retries — network or registry issue"

re_tofu_apply || re_die "tofu apply failed after retries — see ${RE_LOG_FILE#"$REPO_ROOT"/}"

re_log "🔑 Loading kubectl credentials"
re_run ./get-credentials.sh || re_die "get-credentials.sh failed"

re_log "Contexts now available:"
kubectl config get-contexts -o name 2>/dev/null | sed 's/^/    /' || true

re_log "✅ Clusters created: $(for i in $(re_selected_indexes); do printf '%s ' "$(re_cluster_name "$i")"; done)"
