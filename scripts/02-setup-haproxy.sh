#!/usr/bin/env bash
# ============================================================================
# 02 — Ingress controller, Redis Enterprise operator, REC and wildcard DNS
# ============================================================================
# For each of the two clusters:
#   1. install the HAProxy ingress controller
#   2. install the Redis Enterprise operator (pinned bundle) + admission webhook
#   3. create the RedisEnterpriseCluster (REC)
#   4. publish a wildcard DNS record  *.<cluster>.<DNS_ZONE>  -> ingress address
#
# Active/Active identifies participating clusters by FQDN, not IP, which is why
# step 4 is mandatory and a real DNS zone is a prerequisite.
#
# PROVIDER-AGNOSTIC: kubeconfig comes from providers/<cloud>/get-credentials.sh
# and DNS from common/dns-<cloud>.sh. No cloud CLI is invoked directly here.
#
# Run from anywhere. Log: debug/02-setup-haproxy-<timestamp>.log
# HOST ONLY — needs cloud credentials.
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
re_log_init "02-setup-haproxy"
re_yaml_dir_init --clean

# --- Pinned versions (see docs/TODO.md §G) ---------------------------------
HAPROXY_CHART_VERSION="${HAPROXY_CHART_VERSION:-0.16.1}"
OPERATOR_VERSION="${OPERATOR_VERSION:-v8.2.0-13}"
OPERATOR_BUNDLE="https://raw.githubusercontent.com/RedisLabs/redis-enterprise-k8s-docs/${OPERATOR_VERSION}/bundle.yaml"
DNS_TTL="${DNS_TTL:-60}"

re_log "chart haproxy-ingress=$HAPROXY_CHART_VERSION  operator=$OPERATOR_VERSION"

# ============================================================================
# wait_until <command> <max_attempts> <sleep_seconds> <message>
# ============================================================================
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

# ============================================================================
# Credentials + Helm repo
# ============================================================================
# Provider-specific: delegates to providers/$CLOUD_PROVIDER/get-credentials.sh
re_kube_credentials

# Provider-specific: gives us create_dns_record for aws/gcp (azure is inline)
re_dns_lib

re_log "Available kubectl contexts:"
kubectl config get-contexts -o name 2>/dev/null | sed 's/^/    /' || true

re_run helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts
re_run helm repo update

# ============================================================================
# Per-cluster setup
# ============================================================================
# Pairs of "<kubectl context>:<Redis Enterprise name>". The two are decoupled:
# the context is the CLOUD cluster name (unique per operator on a shared
# project), the RE name is the short public identity used in every FQDN.
for PAIR in "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"; do
  CLUSTER="${PAIR%%:*}"; REC_NAME="${PAIR##*:}"
  re_log ""
  re_log "══════ $CLUSTER  (RE: $REC_NAME) ══════"

  kubectl config use-context "$CLUSTER" >/dev/null \
    || re_die "no kubectl context '$CLUSTER' (did get-credentials.sh run?)"

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
done

# ============================================================================
# Wait for both RECs to reach Running
# ============================================================================
re_log ""
for PAIR in "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"; do
  CLUSTER="${PAIR%%:*}"; REC_NAME="${PAIR##*:}"
  wait_until "[ \"\$(kubectl --context=$CLUSTER get rec $REC_NAME -n $NS -o jsonpath='{.status.state}' 2>/dev/null)\" = \"Running\" ]" \
    60 10 "$CLUSTER: REC $REC_NAME reaching Running" \
    || re_die "$CLUSTER: REC did not reach Running — run ./scripts/get-logs.sh"
done

# ============================================================================
# Verify DNS actually resolves before step 03 relies on it
# ============================================================================
re_log "🔎 Checking DNS resolution"
for REC_NAME in "$REC_NAME1" "$REC_NAME2"; do
  host="api.$REC_NAME.$DNS_ZONE"
  if command -v dig >/dev/null 2>&1; then
    if [ -n "$(dig +short "$host" 2>/dev/null)" ]; then
      re_log "   ✅ $host resolves"
    else
      re_warn "   $host does not resolve yet — step 03 may fail until DNS propagates"
    fi
  fi
done

re_log "✅ Both RECs Running. Manifests in ${YAML_DIR#"$REPO_ROOT"/}/"
