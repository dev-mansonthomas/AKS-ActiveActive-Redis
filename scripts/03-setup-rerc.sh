#!/usr/bin/env bash
# ============================================================================
# 03 — Establish mutual Remote Cluster (RERC) trust between the two RECs
# ============================================================================
# For each cluster: read its admin credentials, render the RERC secret and the
# RedisEnterpriseRemoteCluster object. Then apply BOTH clusters' objects to
# BOTH clusters — Active/Active trust is mutual, so each side must know the
# other. (The UI session timeout is raised per cluster by step 02a.)
#
# Generated manifests land in yaml/ (gitignored) so you can inspect exactly
# what the operator was given.
#
# Run from anywhere. Log: debug/03-setup-rerc-<timestamp>.log
# HOST ONLY — needs a working kubeconfig.
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
re_log_init "03-setup-rerc"
if re_is_single; then
  re_die "step 03 links TWO clusters: not applicable to a single-cluster deployment (RE_CLUSTERS=$(re_selected_indexes))"
fi
re_yaml_dir_init


# ============================================================================
# Render the RERC secret + object for each cluster
# ============================================================================
# The operator names the admin secret after the REC object.
for PAIR in "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"; do
  CLUSTER="${PAIR%%:*}"; REC_NAME="${PAIR##*:}"
  re_log "📝 Rendering RERC manifests for $REC_NAME (on $CLUSTER)"

  B64_USERNAME=$(kubectl --context="$CLUSTER" -n "$NS" get secret "$REC_NAME" \
    -o jsonpath='{.data.username}' 2>/dev/null) \
    || re_die "$CLUSTER: cannot read secret $REC_NAME — is the REC Running?"
  B64_PASSWORD=$(kubectl --context="$CLUSTER" -n "$NS" get secret "$REC_NAME" \
    -o jsonpath='{.data.password}' 2>/dev/null)

  [ -n "$B64_USERNAME" ] || re_die "$CLUSTER: empty username in secret $REC_NAME"

  re_render rerc-secret.yaml "$YAML_DIR/secret-$REC_NAME.yaml" \
    "REC_NAME=$REC_NAME" "B64_PASSWORD=$B64_PASSWORD" "B64_USERNAME=$B64_USERNAME"

  re_render rerc.yaml "$YAML_DIR/rerc-$REC_NAME.yaml" "REC_NAME=$REC_NAME"
done

# ============================================================================
# Apply both clusters' secrets and RERC objects to both clusters
# ============================================================================
re_log "🔗 Establishing mutual RERC trust"
for CLUSTER in "$CLUSTER1" "$CLUSTER2"; do
  re_log "→ applying to $CLUSTER"
  for PEER in "$REC_NAME1" "$REC_NAME2"; do
    re_run kubectl --context="$CLUSTER" -n "$NS" apply -f "$YAML_DIR/secret-$PEER.yaml" \
      || re_die "$CLUSTER: failed to apply secret for $PEER"
    re_run kubectl --context="$CLUSTER" -n "$NS" apply -f "$YAML_DIR/rerc-$PEER.yaml" \
      || re_die "$CLUSTER: failed to apply RERC for $PEER"
  done
done

re_log "✅ RERC trust established. Manifests in ${YAML_DIR#"$REPO_ROOT"/}/"
