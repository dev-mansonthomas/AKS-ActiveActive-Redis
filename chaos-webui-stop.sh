#!/usr/bin/env bash
# Stop the chaos web console started by ./chaos-webui-start.sh.
# Only kills a process whose command line contains flask/app.py (a recycled pid is never touched).
# Environment: CHAOS_WEBUI_PORT (5050), CHAOS_WEBUI_STATE_DIR (<repo>/debug).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CHAOS_WEBUI_STATE_DIR:-$ROOT/debug}"
PORT="${CHAOS_WEBUI_PORT:-5050}"
PIDFILE="$STATE_DIR/chaos-webui.pid"

is_console() { case "$(ps -p "$1" -o command= 2>/dev/null)" in *flask/app.py*) return 0 ;; *) return 1 ;; esac; }

pid=""
if [ -r "$PIDFILE" ]; then
  read -r pid _ < "$PIDFILE"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && ! is_console "$pid"; then
    echo "pid $pid is not the chaos console — refusing to kill it, removing the stale pid file" >&2
    rm -f "$PIDFILE"
    exit 0
  fi
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || pid=""
fi

# no usable pid file: fall back to the listener on our port, if it is the console
if [ -z "$pid" ] && command -v lsof >/dev/null 2>&1; then
  for cand in $(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null); do
    if is_console "$cand"; then pid="$cand"; break; fi
  done
fi

if [ -z "$pid" ]; then
  rm -f "$PIDFILE"
  echo "not running"
  exit 0
fi

kill "$pid" 2>/dev/null
for _ in $(seq 1 20); do   # up to 5 s for a clean exit
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.25
done
kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
rm -f "$PIDFILE"
echo "stopped (pid $pid)"
