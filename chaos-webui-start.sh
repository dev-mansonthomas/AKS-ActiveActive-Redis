#!/usr/bin/env bash
# ============================================================================
# Start the chaos web console (Flask) — quietly.
# ============================================================================
# Prints ONE line (URL, pid, log) and returns. The HTTP server's output goes to
# debug/chaos-webui-<timestamp>.log (+ debug/chaos-webui-latest.log), never to this
# terminal. Idempotent: a console already running is reported, not restarted.
#
#   ./chaos-webui-start.sh              # start, then open the browser (macOS/Linux)
#   ./chaos-webui-start.sh --no-open
#   ./chaos-webui-stop.sh               # stop it
#
# Environment (all optional):
#   CHAOS_WEBUI_PORT       listen port, default 5050 (5000 is taken by AirPlay on recent macOS)
#   CHAOS_WEBUI_STATE_DIR  pid file + logs, default <repo>/debug (gitignored)
#   CHAOS_WEBUI_PYTHON     python to use; default: .venv, redis-enterprise-testing/.venv, else
#                          a new .venv is created from flask/requirements.txt
# Spec: docs/specs/chaos-webui.md. HOST ONLY (needs kubectl contexts and credentials).
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${CHAOS_WEBUI_STATE_DIR:-$ROOT/debug}"
PORT="${CHAOS_WEBUI_PORT:-5050}"
PIDFILE="$STATE_DIR/chaos-webui.pid"
URL="http://127.0.0.1:$PORT/"
OPEN=1
case "${1:-}" in
  --no-open) OPEN=0 ;;
  "") ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

mkdir -p "$STATE_DIR"

healthy() { curl -fsS -m 2 "${URL}api/health" >/dev/null 2>&1; }

# pid of OUR console from the pid file, empty if stale/foreign
live_pid() {
  local pid
  [ -r "$PIDFILE" ] || return 0
  read -r pid _ < "$PIDFILE"
  [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null || return 0
  case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *flask/app.py*) echo "$pid" ;;
  esac
}

rel() { case "$1" in "$ROOT"/*) echo "${1#"$ROOT"/}" ;; *) echo "$1" ;; esac; }

# --- already running?
pid="$(live_pid)"
if [ -n "$pid" ] && healthy; then
  echo "Chaos console: $URL  (pid $pid, log $(rel "$STATE_DIR")/chaos-webui-latest.log)"
  exit 0
fi
rm -f "$PIDFILE"

LOG="$STATE_DIR/chaos-webui-$(date +%Y%m%d-%H%M%S).log"
ln -sfn "$(basename "$LOG")" "$STATE_DIR/chaos-webui-latest.log"

# --- python with the console's dependencies (all chatter goes to the log)
deps_ok() { "$1" -c 'import flask, redis, requests, kubernetes' >/dev/null 2>&1; }
PY=""
for cand in "${CHAOS_WEBUI_PYTHON:-}" "$ROOT/.venv/bin/python" "$ROOT/redis-enterprise-testing/.venv/bin/python"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  PY="$cand"; break
done
if [ -z "$PY" ]; then
  { echo "creating $ROOT/.venv"; python3 -m venv "$ROOT/.venv"; } >>"$LOG" 2>&1 \
    || { echo "cannot create $ROOT/.venv (see $(rel "$LOG"))" >&2; exit 1; }
  PY="$ROOT/.venv/bin/python"
fi
if ! deps_ok "$PY"; then
  echo "installing flask/requirements.txt into $PY" >>"$LOG"
  "$PY" -m pip install -r "$ROOT/flask/requirements.txt" >>"$LOG" 2>&1 \
    || { echo "pip install failed (see $(rel "$LOG"))" >&2; tail -20 "$LOG" >&2; exit 1; }
fi

# --- start detached, stdout/stderr to the log
CHAOS_WEBUI_LOG_FILE="$LOG" CHAOS_WEBUI_PORT="$PORT" \
  nohup "$PY" "$ROOT/flask/app.py" >>"$LOG" 2>&1 </dev/null &
pid=$!
disown "$pid" 2>/dev/null || true
echo "$pid $PORT" > "$PIDFILE"

for _ in $(seq 1 40); do   # 40 x 0.25 s = 10 s
  if ! kill -0 "$pid" 2>/dev/null; then break; fi
  if healthy; then
    echo "Chaos console: $URL  (pid $pid, log $(rel "$LOG"))"
    if [ "$OPEN" -eq 1 ]; then
      if command -v open >/dev/null 2>&1; then open "$URL" >/dev/null 2>&1
      elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$URL" >/dev/null 2>&1; fi
    fi
    exit 0
  fi
  sleep 0.25
done

echo "chaos console did not become healthy on $URL — last log lines ($(rel "$LOG")):" >&2
tail -20 "$LOG" >&2
kill "$pid" 2>/dev/null
rm -f "$PIDFILE"
exit 1
