#!/usr/bin/env bash
# ============================================================================
# webui.sh — open the Redis Enterprise Cluster Manager UI through tunnels
# ============================================================================
# Usage:
#   ./scripts/webui.sh        # BOTH clusters: 8443 -> cluster 1, 8444 -> cluster 2
#   ./scripts/webui.sh 1      # cluster 1 only  (https://localhost:8443)
#   ./scripts/webui.sh 2      # cluster 2 only  (https://localhost:8444)
#
# One browser tab per tunnel. Works from any directory. Uses
# `kubectl --context` (never switches your global kubectl context) and pins the
# cloud account from config.sh, like k9s-cluster.sh. Ctrl-C closes all tunnels.
#
# The REC ingress only publishes the REST API (api.<rec>.<zone>) and the
# databases; the Cluster Manager UI is the in-cluster service <rec>-ui:8443,
# hence the port-forward. HOST ONLY — needs a kubeconfig.
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

case "${1:-both}" in
  both) TARGETS="1 2" ;;
  1|2)  TARGETS="$1" ;;
  -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  *)    echo "usage: $0 [1|2]   (no argument = both clusters)" >&2; exit 2 ;;
esac

re_load_config
re_cloud_select_account

PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

open_url() {
  case "$OSTYPE" in
    darwin*)    open "$1" ;;
    linux-gnu*) xdg-open "$1" >/dev/null 2>&1 || true ;;
    *)          echo "   open $1 manually" ;;
  esac
}

for IDX in $TARGETS; do
  if [ "$IDX" -eq 1 ]; then
    CTX="$CLUSTER1"; REC="$REC_NAME1"; LOCAL_PORT="${RE_UI_LOCAL_PORT1:-8443}"
  else
    CTX="$CLUSTER2"; REC="$REC_NAME2"; LOCAL_PORT="${RE_UI_LOCAL_PORT2:-8444}"
  fi

  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$CTX"; then
    echo "❌ context '$CTX' is not in your kubeconfig — run: bash providers/$CLOUD_PROVIDER/get-credentials.sh" >&2
    exit 1
  fi

  echo "⛓️  cluster $IDX: context '$CTX', service $NS/$REC-ui → localhost:$LOCAL_PORT"
  kubectl --context="$CTX" -n "$NS" port-forward "svc/$REC-ui" "$LOCAL_PORT:8443" >/dev/null &
  PF_PID=$!
  PIDS="$PIDS $PF_PID"

  # Wait (max ~15 s) for THIS tunnel before opening its tab.
  UP=0
  for _ in $(seq 1 30); do
    kill -0 "$PF_PID" 2>/dev/null || break
    if (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; then UP=1; break; fi
    sleep 0.5
  done
  if [ "$UP" -ne 1 ]; then
    echo "❌ cluster $IDX: tunnel did not come up (port $LOCAL_PORT busy, or $REC-ui missing?)" >&2
    exit 1
  fi

  URL="https://localhost:$LOCAL_PORT/#/"
  echo "🔓 cluster $IDX ($REC): $URL"
  open_url "$URL"
done

echo "Tunnels open — Ctrl-C to close them all."
wait
