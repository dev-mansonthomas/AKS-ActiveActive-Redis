#!/usr/bin/env bash
# ============================================================================
# 03 — Establish mutual Remote Cluster (RERC) trust between the two RECs
# ============================================================================
# For each cluster: read its admin credentials, render the RERC secret and the
# RedisEnterpriseRemoteCluster object. Then apply BOTH clusters' objects to
# BOTH clusters — Active/Active trust is mutual, so each side must know the
# other. Finally raise the UI session timeout so a demo doesn't log you out.
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
re_yaml_dir_init

UI_SESSION_TIMEOUT_MINUTES="${RE_UI_SESSION_TIMEOUT_MINUTES:-1440}"

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

# ============================================================================
# Raise the UI session timeout (done last: needs the admin credentials above)
# ============================================================================
re_log "🔧 Setting Cluster Manager session timeout to ${UI_SESSION_TIMEOUT_MINUTES} min"
for PAIR in "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"; do
  CLUSTER="${PAIR%%:*}"; REC_NAME="${PAIR##*:}"
  ADMIN_USERNAME=$(kubectl --context="$CLUSTER" -n "$NS" get secret "$REC_NAME" \
    -o jsonpath='{.data.username}' | re_b64_decode)
  ADMIN_PASSWORD=$(kubectl --context="$CLUSTER" -n "$NS" get secret "$REC_NAME" \
    -o jsonpath='{.data.password}' | re_b64_decode)

  API_HOST=$(kubectl --context="$CLUSTER" get ingress -n "$NS" \
    -o jsonpath='{range .items[*].spec.rules[*]}{.host}{"\n"}{end}' 2>/dev/null \
    | grep -E '^api\.' | head -1)

  if [ -z "$API_HOST" ]; then
    re_warn "$CLUSTER: no 'api.*' ingress host found — skipping UI timeout"
    continue
  fi

  # PUT /v1/cluster with cm_session_timeout_minutes — verified against the
  # Redis Software REST API reference. The previous code used
  # `PATCH /v1/settings/ui` with `ui_session_timeout` in SECONDS: wrong method,
  # wrong path (404) and wrong unit.
  # -k: the operator issues self-signed certs. --fail so a non-2xx is visible.
  if curl -sS -k --fail -u "$ADMIN_USERNAME:$ADMIN_PASSWORD" \
      -X PUT "https://$API_HOST/v1/cluster" \
      -H "Content-Type: application/json" \
      -d "{\"cm_session_timeout_minutes\": $UI_SESSION_TIMEOUT_MINUTES}" >/dev/null; then
    re_log "✅ $REC_NAME: session timeout set to ${UI_SESSION_TIMEOUT_MINUTES} min"
  else
    re_warn "$CLUSTER: PUT /v1/cluster failed on https://$API_HOST (non-fatal)"
    re_warn "   the Cluster Manager will log you out after its default 15 min"
  fi
done

re_log "✅ RERC trust established. Manifests in ${YAML_DIR#"$REPO_ROOT"/}/"
