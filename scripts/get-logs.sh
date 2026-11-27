#!/usr/bin/env bash
# ============================================================================
# get-logs.sh — collect runtime diagnostics from the live demo into debug/
# ============================================================================
# Gathers everything you need to explain (or debug) a demo: cluster state,
# Redis Enterprise operator + REC/RERC/REAADB status, pod logs, ingress and
# DNS resolution. Writes a timestamped bundle under debug/.
#
# Usage:
#   ./scripts/get-logs.sh              # both clusters, default tail
#   ./scripts/get-logs.sh --tail 500   # more pod log lines
#   ./scripts/get-logs.sh --cluster redis-us-central1
#   ./scripts/get-logs.sh --archive    # also produce a .tar.gz to share
#
# Read-only: it never mutates the clusters. Needs a working kubeconfig, so it
# runs wherever kubectl is authenticated (normally the host).
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

TAIL_LINES=200
ONLY_CLUSTER=""
ARCHIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tail)    TAIL_LINES="${2:?--tail needs a value}"; shift 2 ;;
    --cluster) ONLY_CLUSTER="${2:?--cluster needs a value}"; shift 2 ;;
    --archive) ARCHIVE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

re_load_config
re_log_init "get-logs"

BUNDLE="$DEBUG_DIR/diag-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BUNDLE"
re_log "📦 Collecting into ${BUNDLE#"$REPO_ROOT"/}"

CLUSTERS="${ONLY_CLUSTER:-$CLUSTER1 $CLUSTER2}"

# --- capture <file> <command...> : run, store, never abort the collection ----
capture() {
  local out="$BUNDLE/$1"; shift
  mkdir -p "$(dirname "$out")"
  {
    echo "\$ $*"
    echo "---"
    "$@" 2>&1 || echo "(command failed, exit $?)"
  } > "$out"
}

# ============================================================================
# Environment / configuration snapshot (owner comes from config.sh)
# shellcheck disable=SC2154
# ============================================================================
{
  echo "collected     : $(date -Iseconds)"
  echo "cloud provider: $CLOUD_PROVIDER"
  echo "clusters      : $CLUSTERS"
  echo "namespace     : $NS"
  echo "AA DB         : $AA_DB_NAME"
  echo "DNS zone      : $DNS_ZONE"
  echo "owner         : $owner"
} > "$BUNDLE/00-context.txt"

capture "01-versions.txt" sh -c 'kubectl version --client=true 2>/dev/null; helm version --short 2>/dev/null; tofu version 2>/dev/null'
capture "02-contexts.txt" kubectl config get-contexts

# ============================================================================
# Per-cluster state
# ============================================================================
for CLUSTER in $CLUSTERS; do
  # Map the kubectl context back to its Redis Enterprise name.
  case "$CLUSTER" in
    "$CLUSTER1") REC_NAME="$REC_NAME1" ;;
    "$CLUSTER2") REC_NAME="$REC_NAME2" ;;
    *)           REC_NAME="$CLUSTER" ;;
  esac
  re_log "🔍 $CLUSTER (RE: $REC_NAME)"
  D="$CLUSTER"

  capture "$D/nodes.txt"            kubectl --context="$CLUSTER" get nodes -o wide
  capture "$D/all-ns.txt"           kubectl --context="$CLUSTER" get ns
  capture "$D/events.txt"           kubectl --context="$CLUSTER" get events -n "$NS" --sort-by=.lastTimestamp
  capture "$D/pods.txt"             kubectl --context="$CLUSTER" get pods -n "$NS" -o wide
  capture "$D/svc.txt"              kubectl --context="$CLUSTER" get svc -A -o wide
  capture "$D/ingress.txt"          kubectl --context="$CLUSTER" get ingress -n "$NS" -o wide
  capture "$D/pvc.txt"              kubectl --context="$CLUSTER" get pvc -n "$NS"

  # rladmin: the Redis Enterprise cluster CLI, only reachable from inside a pod.
  # This is the single most useful artefact when Active-Active misbehaves, and
  # the collector was missing it entirely.
  _pod="$REC_NAME-0"
  if kubectl --context="$CLUSTER" -n "$NS" get pod "$_pod" >/dev/null 2>&1; then
    capture "$D/rladmin-status.txt"    kubectl --context="$CLUSTER" -n "$NS" exec "$_pod" -- rladmin status
    capture "$D/rladmin-info-cluster.txt" kubectl --context="$CLUSTER" -n "$NS" exec "$_pod" -- rladmin info cluster
    capture "$D/rladmin-crdb-list.txt" kubectl --context="$CLUSTER" -n "$NS" exec "$_pod" -- rladmin status databases
  else
    echo "pod $_pod absent — REC not ready?" > "$BUNDLE/$D/rladmin-status.txt"
  fi

  # Redis Enterprise custom resources — the ones that actually matter
  capture "$D/rec.yaml"             kubectl --context="$CLUSTER" get rec -n "$NS" -o yaml
  capture "$D/rec-status.txt"       kubectl --context="$CLUSTER" get rec -n "$NS" \
                                      -o "custom-columns=NAME:.metadata.name,STATE:.status.state,SPEC:.spec.nodes"
  capture "$D/pvc-and-disks.txt"    kubectl --context="$CLUSTER" -n "$NS" get pvc -o wide
  capture "$D/rerc.yaml"            kubectl --context="$CLUSTER" get rerc -n "$NS" -o yaml
  capture "$D/reaadb.yaml"          kubectl --context="$CLUSTER" get reaadb -n "$NS" -o yaml
  capture "$D/redb.yaml"            kubectl --context="$CLUSTER" get redb -n "$NS" -o yaml

  # Operator + ingress controller logs
  for dep in redis-enterprise-operator haproxy-ingress; do
    ns="$NS"; [ "$dep" = "haproxy-ingress" ] && ns="ingress-controller"
    capture "$D/logs-$dep.txt" kubectl --context="$CLUSTER" logs -n "$ns" \
      "deployment/$dep" --tail="$TAIL_LINES" --all-containers=true
  done

  # Redis Enterprise cluster pods (rec-<cluster>-0/1/2)
  while IFS= read -r pod; do
    [ -n "$pod" ] || continue
    capture "$D/logs-pod-$pod.txt" kubectl --context="$CLUSTER" logs -n "$NS" \
      "$pod" --tail="$TAIL_LINES" --all-containers=true
  done < <(kubectl --context="$CLUSTER" get pods -n "$NS" \
             -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')

  # DNS resolution — the usual Active/Active failure cause
  {
    for host in "api.$REC_NAME.$DNS_ZONE" "$AA_DB_NAME-db.$REC_NAME.$DNS_ZONE"; do
      echo "== $host"
      if command -v dig >/dev/null 2>&1; then
        dig +short "$host" 2>&1 | sed 's/^/   /' || true
      else
        getent hosts "$host" 2>&1 | sed 's/^/   /' || echo "   (unresolved)"
      fi
    done
  } > "$BUNDLE/$D/dns.txt"
done

# ============================================================================
# Terraform state summary (no secrets, no plan)
# ============================================================================
if [ -f "$REPO_ROOT/providers/$CLOUD_PROVIDER/terraform.tfstate" ]; then
  capture "03-tofu-resources.txt" sh -c \
    "cd '$REPO_ROOT/providers/$CLOUD_PROVIDER' && tofu state list"
fi

# ============================================================================
# Summary
# ============================================================================
FILES=$(find "$BUNDLE" -type f | wc -l)
re_log "✅ $FILES files collected in ${BUNDLE#"$REPO_ROOT"/}"

# Quick health readout so you don't have to open the bundle
echo
re_log "── quick status ──"
for CLUSTER in $CLUSTERS; do
  state=$(grep -A99 'STATE' "$BUNDLE/$CLUSTER/rec-status.txt" 2>/dev/null | tail -n +2 | head -1 || true)
  re_log "  $CLUSTER REC: ${state:-<no data>}"
done

if [ "$ARCHIVE" -eq 1 ]; then
  tar -czf "$BUNDLE.tar.gz" -C "$DEBUG_DIR" "$(basename "$BUNDLE")"
  re_log "📦 archive: ${BUNDLE#"$REPO_ROOT"/}.tar.gz"
fi
