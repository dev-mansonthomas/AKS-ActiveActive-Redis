#!/usr/bin/env bash
# ============================================================================
# 02a — Set up ONE cluster: ingress, operator, REC, wildcard DNS, webhook
# ============================================================================
# Called by 02-setup-haproxy.sh, once per cluster, IN PARALLEL. Each run writes
# its own log: debug/02a-setup-<rec name>-<timestamp>.log
#
#   1. install the HAProxy ingress controller
#   2. install the Redis Enterprise operator (pinned bundle) + admission webhook
#   3. create the RedisEnterpriseCluster (REC)
#   4. publish a wildcard DNS record  *.<rec name>.<DNS_ZONE>  -> ingress address
#   5. wait until the REC is Running
#
# Parallel-safety: nothing here touches shared state. In particular there is NO
# `kubectl config use-context` (it rewrites ~/.kube/config); every command takes
# its own --context. The parent has already loaded the kubeconfig, added the
# helm repo and cleaned yaml/.
#
# Usage (normally not run by hand):
#   ./scripts/02a-setup-cluster.sh <kubectl-context> <rec-name>
# Exit: 0 REC Running, 1 failure. HOST ONLY — needs cloud credentials.
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

[ $# -eq 2 ] || { echo "Usage: $0 <kubectl-context> <rec-name>" >&2; exit 2; }
CLUSTER="$1"; REC_NAME="$2"

re_load_config
re_log_init "02a-setup-$REC_NAME"
re_yaml_dir_init            # no --clean: the parent did it, and the sibling is writing here

HAPROXY_CHART_VERSION="${HAPROXY_CHART_VERSION:-0.16.1}"
OPERATOR_VERSION="${OPERATOR_VERSION:-v8.2.0-13}"
OPERATOR_BUNDLE="https://raw.githubusercontent.com/RedisLabs/redis-enterprise-k8s-docs/${OPERATOR_VERSION}/bundle.yaml"
DNS_TTL="${DNS_TTL:-60}"

# wait_until <command> <max_attempts> <sleep_seconds> <message>
wait_until() {
  local cmd="$1" max_attempts="$2" sleep_seconds="$3" message="$4"
  re_log "⏳ $message"
  local attempt=0
  until eval "$cmd"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
      re_warn "timeout after $((max_attempts * sleep_seconds))s: $message"
      return 1
    fi
    attempt=$((attempt + 1))
    re_log "   still waiting... ($attempt/$max_attempts)"
    sleep "$sleep_seconds"
  done
  re_log "✅ $message"
}

# Provider-specific: gives us create_dns_record for aws/gcp (azure is inline)
re_dns_lib

re_log "══════ $CLUSTER  (RE: $REC_NAME) ══════"

kubectl --context="$CLUSTER" version >/dev/null 2>&1 \
  || re_die "cluster '$CLUSTER' unreachable (did get-credentials.sh run?)"

re_ns_ensure "$CLUSTER" "$NS"

# --- ingress controller -------------------------------------------------
re_log "📦 Installing haproxy-ingress $HAPROXY_CHART_VERSION"
re_run helm upgrade --install haproxy-ingress haproxy-ingress/haproxy-ingress \
  --kube-context "$CLUSTER" \
  --create-namespace --namespace ingress-controller \
  --version "$HAPROXY_CHART_VERSION" \
  -f "$TEMPLATES_DIR/haproxy-ingress-values.yaml" \
  || re_die "$CLUSTER: haproxy-ingress install failed"

# --- Redis Enterprise operator -----------------------------------------
re_log "📦 Installing Redis Enterprise operator $OPERATOR_VERSION"
re_run kubectl --context="$CLUSTER" apply -n "$NS" -f "$OPERATOR_BUNDLE" \
  || re_die "$CLUSTER: operator bundle failed"

wait_until "kubectl --context=$CLUSTER -n $NS get secret admission-tls >/dev/null 2>&1" \
  24 5 "$CLUSTER: admission-tls secret" || re_die "$CLUSTER: admission-tls never appeared"

CERT=$(kubectl --context="$CLUSTER" -n "$NS" get secret admission-tls -o jsonpath='{.data.cert}')

CRD_NAME="redisenterpriseclusters.app.redislabs.com"
wait_until "kubectl --context=$CLUSTER get crd $CRD_NAME >/dev/null 2>&1" \
  24 5 "$CLUSTER: CRD $CRD_NAME" || re_die "$CLUSTER: REC CRD never registered"

# --- RedisEnterpriseCluster --------------------------------------------
re_render rec.yaml "$YAML_DIR/rec-$REC_NAME.yaml" "REC_NAME=$REC_NAME"

re_run kubectl --context="$CLUSTER" apply -n "$NS" -f "$YAML_DIR/rec-$REC_NAME.yaml" \
  || re_die "$CLUSTER: REC apply failed"

wait_until "kubectl --context=$CLUSTER get rec $REC_NAME -n $NS >/dev/null 2>&1" \
  24 5 "$CLUSTER: REC object $REC_NAME" || re_die "$CLUSTER: REC object missing"

# --- ingress address + wildcard DNS ------------------------------------
# Azure/GCP publish .ip, AWS ELBs publish .hostname — re_ingress_address
# returns whichever is set.
wait_until "[ -n \"\$(re_ingress_address $CLUSTER ingress-controller haproxy-ingress)\" ]" \
  36 10 "$CLUSTER: ingress LoadBalancer address" \
  || re_die "$CLUSTER: ingress never got an external address"

CLUSTER_ADDR=$(re_ingress_address "$CLUSTER" ingress-controller haproxy-ingress)
re_log "🌐 $CLUSTER ingress address: $CLUSTER_ADDR"

re_dns_upsert "*.$REC_NAME" "$CLUSTER_ADDR" "$DNS_TTL" \
  || re_warn "$CLUSTER: DNS record for *.$REC_NAME may not be set"

# --- admission webhook --------------------------------------------------
sed -e "s/NAMESPACE/$NS/g" \
    -e "s|CERT|$CERT|g" \
    "$TEMPLATES_DIR/webhook.yaml" > "$YAML_DIR/webhook-$REC_NAME.yaml"

re_run kubectl --context="$CLUSTER" apply -n "$NS" -f "$YAML_DIR/webhook-$REC_NAME.yaml" \
  || re_warn "$CLUSTER: webhook apply failed (non-fatal)"

# --- REC Running ---------------------------------------------------------
wait_until "[ \"\$(kubectl --context=$CLUSTER get rec $REC_NAME -n $NS -o jsonpath='{.status.state}' 2>/dev/null)\" = \"Running\" ]" \
  60 10 "$CLUSTER: REC $REC_NAME reaching Running" \
  || re_die "$CLUSTER: REC did not reach Running — run ./scripts/get-logs.sh"

# --- Cluster Manager session timeout -------------------------------------
# Raise it so a demo does not log you out. `rladmin cluster config
# cm_session_timeout_minutes` runs INSIDE the REC pod (the same way scripts/rladmin.sh
# does): no credentials, nothing on the wire, no TLS verification to disable.
# (It used to live in step 03, which a single-cluster deployment skips.)
UI_SESSION_TIMEOUT_MINUTES="${RE_UI_SESSION_TIMEOUT_MINUTES:-1440}"
if out=$(kubectl --context="$CLUSTER" -n "$NS" exec "$REC_NAME-0" -c redis-enterprise-node -- \
     rladmin cluster config cm_session_timeout_minutes "$UI_SESSION_TIMEOUT_MINUTES" 2>&1); then
  re_log "✅ $REC_NAME: Cluster Manager session timeout set to ${UI_SESSION_TIMEOUT_MINUTES} min"
else
  re_warn "$CLUSTER: could not set the session timeout on $REC_NAME-0 (non-fatal)"
  re_warn "   cause: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
  re_warn "   the Cluster Manager will log you out after its default 15 min"
fi

re_log "✅ $CLUSTER ($REC_NAME) ready"
