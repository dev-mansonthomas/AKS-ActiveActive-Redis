#!/usr/bin/env bash
# ============================================================================
# rladmin.sh — run rladmin on a Redis Enterprise cluster
# ============================================================================
# rladmin is the Redis Enterprise cluster CLI. It lives INSIDE the RE pods, so
# there is nothing to install: we exec into node 0 of the chosen cluster.
#
# Everything after the cluster selector is passed VERBATIM to rladmin, so any
# rladmin command works — not just status.
#
# Usage:
#   ./scripts/rladmin.sh <1|2|--both|context> [rladmin args...]
#
#   ./scripts/rladmin.sh                       # cluster 1, `rladmin status` (default)
#   ./scripts/rladmin.sh 1 --shell             # interactive rladmin prompt
#   ./scripts/rladmin.sh 1 status databases
#   ./scripts/rladmin.sh 1 info db active-active-db
#   ./scripts/rladmin.sh 1 tune db active-active-db max_connections 200
#   ./scripts/rladmin.sh 1 upgrade db active-active-db
#   ./scripts/rladmin.sh 1 node 1 remove
#   ./scripts/rladmin.sh 1 recover all         # prompts — a TTY is allocated
#   ./scripts/rladmin.sh --both status shards  # same command on both clusters
#   ./scripts/rladmin.sh --list                # which pods are available
#
# A TTY is allocated whenever your stdin is one, so commands that ask for
# confirmation (recover, reset, remove...) behave normally.
#
# Cloud-agnostic: it only uses kubectl and the contexts that
# providers/*/get-credentials.sh created.
# HOST ONLY — needs a working kubeconfig. Log: debug/rladmin-<timestamp>.log
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

# The StatefulSet is named after the RedisEnterpriseCluster object (REC_NAME),
# which is decoupled from the cloud cluster name. Node 0 always exists.
_rec_for() {
  case "$1" in
    "$CLUSTER1") echo "$REC_NAME1" ;;
    "$CLUSTER2") echo "$REC_NAME2" ;;
    *)           echo "$1" ;;
  esac
}
_pod_for() { echo "$(_rec_for "$1")-0"; }

_list() {
  echo "Redis Enterprise pods per cluster (namespace $NS):"
  for c in "$CLUSTER1" "$CLUSTER2"; do
    echo "  == $c"
    if kubectl config get-contexts -o name 2>/dev/null | grep -qx "$c"; then
      kubectl --context="$c" -n "$NS" get pods -l redis.io/cluster="$(_rec_for "$c")" \
        -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName \
        2>/dev/null || kubectl --context="$c" -n "$NS" get pods 2>/dev/null | grep "^rec-" || echo "     (no RE pods)"
    else
      echo "     ❌ context not in kubeconfig — bash providers/$CLOUD_PROVIDER/get-credentials.sh"
    fi
  done
}

case "${1:-1}" in
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  --list|-l) re_load_config >/dev/null 2>&1; _list; exit 0 ;;
  --both|-b) TARGETS="$CLUSTER1 $CLUSTER2"; shift ;;
  1) TARGETS="$CLUSTER1"; shift ;;
  2) TARGETS="$CLUSTER2"; shift ;;
  -*) TARGETS="$CLUSTER1" ;;          # options only: default to cluster 1
  *)  TARGETS="$1"; shift ;;          # explicit context name
esac

INTERACTIVE=0
if [ "${1:-}" = "--shell" ]; then
  INTERACTIVE=1
  shift
fi

re_log_init "rladmin"
re_cloud_select_account

# Everything left on the command line is passed straight to rladmin.
if [ "$#" -gt 0 ]; then
  ARGS=("$@")
else
  ARGS=(status)
fi

rc_all=0
for CLUSTER in $TARGETS; do
  POD=$(_pod_for "$CLUSTER")

  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CLUSTER"; then
    re_warn "context '$CLUSTER' not in kubeconfig — run: bash providers/$CLOUD_PROVIDER/get-credentials.sh"
    rc_all=1
    continue
  fi
  if ! kubectl --context="$CLUSTER" -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    re_warn "pod $POD not found in namespace $NS on $CLUSTER"
    re_warn "   is the REC Running?  kubectl --context=$CLUSTER -n $NS get rec"
    rc_all=1
    continue
  fi

  if [ "$INTERACTIVE" -eq 1 ]; then
    re_log "⛓️  interactive rladmin on $CLUSTER ($POD) — Ctrl-D to quit"
    # -it needs a TTY; do not capture, hand the terminal over.
    exec kubectl --context="$CLUSTER" -n "$NS" exec -it "$POD" -- rladmin
  fi

  re_log "══════ $CLUSTER ($POD) ── rladmin ${ARGS[*]}"
  # Allocate a TTY when we started on one: several rladmin commands (recover,
  # reset, node remove, upgrade) ask for confirmation and would otherwise hang
  # or fail on a closed stdin.
  # NOTE: test RE_STDIN_TTY, not `[ -t 0 ]`/`[ -t 1 ]` — re_log_init pipes
  # stdout through tee, so `[ -t 1 ]` is false from that point on.
  if [ "${RE_STDIN_TTY:-0}" = "1" ]; then
    _tty=(-it)
  else
    _tty=()
  fi
  if ! kubectl --context="$CLUSTER" -n "$NS" exec "${_tty[@]}" "$POD" -- rladmin "${ARGS[@]}"; then
    re_warn "$CLUSTER: rladmin ${ARGS[*]} failed"
    rc_all=1
  fi
  echo
done

exit "$rc_all"
