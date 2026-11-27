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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
re_load_config
re_log_init "02-setup-haproxy"
re_yaml_dir_init --clean

# --- Pinned versions (see docs/TODO.md §G) ---------------------------------
HAPROXY_CHART_VERSION="${HAPROXY_CHART_VERSION:-0.16.1}"
OPERATOR_VERSION="${OPERATOR_VERSION:-v8.2.0-13}"
export HAPROXY_CHART_VERSION OPERATOR_VERSION   # inherited by 02a-setup-cluster.sh
export DNS_TTL="${DNS_TTL:-60}"

re_log "chart haproxy-ingress=$HAPROXY_CHART_VERSION  operator=$OPERATOR_VERSION"

# ============================================================================
# Credentials + Helm repo
# ============================================================================
# Provider-specific: delegates to providers/$CLOUD_PROVIDER/get-credentials.sh
re_kube_credentials

re_log "Available kubectl contexts:"
kubectl config get-contexts -o name 2>/dev/null | sed 's/^/    /' || true

re_run helm repo add haproxy-ingress https://haproxy-ingress.github.io/charts
re_run helm repo update

# ============================================================================
# Per-cluster setup — both clusters IN PARALLEL
# ============================================================================
# The work for one cluster lives in 02a-setup-cluster.sh, which writes its own
# log (debug/02a-setup-<rec name>-<ts>.log). Here the two run side by side; their
# output is also echoed below, prefixed with the RE name, so the console and this
# log stay readable. A failure on either one fails the step.
#
# Pairs of "<kubectl context>:<Redis Enterprise name>". The two are decoupled:
# the context is the CLOUD cluster name (unique per operator on a shared
# project), the RE name is the short public identity used in every FQDN.
SETUP_CLUSTER="$SCRIPT_DIR/02a-setup-cluster.sh"
[ -r "$SETUP_CLUSTER" ] || re_die "missing $SETUP_CLUSTER"

PIDS=(); NAMES=()
for PAIR in "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"; do
  CLUSTER="${PAIR%%:*}"; REC_NAME="${PAIR##*:}"
  re_log "🚀 starting $REC_NAME on $CLUSTER  (own log: debug/02a-setup-$REC_NAME-*.log)"
  (
    bash "$SETUP_CLUSTER" "$CLUSTER" "$REC_NAME" 2>&1 \
      | awk -v p="[$REC_NAME] " '{ print p $0; fflush() }'
    exit "${PIPESTATUS[0]}"
  ) &
  PIDS+=("$!"); NAMES+=("$REC_NAME")
done

SETUP_FAILED=0
for i in "${!PIDS[@]}"; do
  if wait "${PIDS[$i]}"; then
    re_log "✅ ${NAMES[$i]}: cluster setup finished"
  else
    re_warn "❌ ${NAMES[$i]}: cluster setup FAILED — see debug/02a-setup-${NAMES[$i]}-latest.log"
    SETUP_FAILED=1
  fi
done
[ "$SETUP_FAILED" -eq 0 ] || re_die "cluster setup failed on at least one cluster"

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

re_log "✅ Both RECs Running (set up in parallel). Manifests in ${YAML_DIR#"$REPO_ROOT"/}/"
