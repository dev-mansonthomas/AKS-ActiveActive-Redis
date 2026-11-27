#!/usr/bin/env bash
# chaos-webui-start.sh / chaos-webui-stop.sh — spec docs/specs/chaos-webui.md, slice 1.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "▶ launcher"

START="$ROOT/chaos-webui-start.sh"; STOP="$ROOT/chaos-webui-stop.sh"
[ -x "$START" ] && ok "start script is executable" || bad "start script missing or not executable"
[ -x "$STOP" ] && ok "stop script is executable" || bad "stop script missing or not executable"
[ "$(stat -c %a "$START" 2>/dev/null || stat -f %Lp "$START")" = 700 ] && ok "start is chmod 700" || bad "start is not chmod 700"
[ "$(stat -c %a "$STOP" 2>/dev/null || stat -f %Lp "$STOP")" = 700 ] && ok "stop is chmod 700" || bad "stop is not chmod 700"
[ -e "$ROOT/scripts/launch-flask-console.sh" ] && bad "scripts/launch-flask-console.sh still exists" || ok "old duplicate removed"
[ -e "$ROOT/launch-flask-console.sh" ] && bad "launch-flask-console.sh still exists" || ok "old launcher renamed"

STATE="$(mktemp -d)"; PORT="$(free_port)"
export CHAOS_WEBUI_STATE_DIR="$STATE" CHAOS_WEBUI_PORT="$PORT"
export RE_CONFIG_FILE="$ROOT/flask/tests/fixtures/config.test.sh"
CHAOS_WEBUI_PYTHON="$(test_python)"; export CHAOS_WEBUI_PYTHON
cleanup() { "$STOP" >/dev/null 2>&1; kill "${BUSY_PID:-0}" "${FOREIGN_PID:-0}" 2>/dev/null; rm -rf "$STATE"; }
trap cleanup EXIT

# --- start prints exactly one line, quickly, and nothing on stderr
t0=$SECONDS
out=$("$START" --no-open 2>"$STATE/err"); rc=$?
assert_rc $rc 0 "start exits 0"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1 "start prints exactly one line"
assert_contains "$out" "Chaos console: http://127.0.0.1:$PORT/" "line carries the URL"
assert_contains "$out" "pid " "line carries the pid"
assert_contains "$out" "log " "line carries the log path"
assert_eq "$(cat "$STATE/err")" "" "start writes nothing on stderr"
[ $((SECONDS - t0)) -lt 15 ] && ok "start took < 15 s" || bad "start took $((SECONDS - t0)) s"
PID1=$(cut -d' ' -f1 "$STATE/chaos-webui.pid")
kill -0 "$PID1" 2>/dev/null && ok "pid file points to a live process" || bad "pid file does not point to a live process"

# --- request lines land in the log, not on the terminal
curl -fsS "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1
sleep 0.5
assert_contains "$(cat "$STATE/chaos-webui-latest.log")" "GET /api/health" "HTTP access log is in the log file"

# --- second start is idempotent
out2=$("$START" --no-open 2>&1); rc=$?
assert_rc $rc 0 "second start exits 0"
assert_contains "$out2" "pid $PID1" "second start reports the same pid"
assert_eq "$(cut -d' ' -f1 "$STATE/chaos-webui.pid")" "$PID1" "no second process started"

# --- stop
out3=$("$STOP" 2>&1); rc=$?
assert_rc $rc 0 "stop exits 0"
assert_contains "$out3" "stopped (pid $PID1)" "stop reports the pid"
kill -0 "$PID1" 2>/dev/null && bad "process still alive after stop" || ok "process is gone"
[ -e "$STATE/chaos-webui.pid" ] && bad "pid file left behind" || ok "pid file removed"
assert_contains "$("$STOP" 2>&1)" "not running" "stop when nothing runs says so"
"$STOP" >/dev/null 2>&1; assert_rc $? 0 "stop when nothing runs exits 0"

# --- foreign pid in the pid file is never killed
sleep 300 & FOREIGN_PID=$!
echo "$FOREIGN_PID $PORT" > "$STATE/chaos-webui.pid"
out4=$("$STOP" 2>&1); rc=$?
assert_rc $rc 0 "stop with foreign pid exits 0"
assert_contains "$out4" "refusing" "stop warns it refuses to kill a foreign process"
kill -0 "$FOREIGN_PID" 2>/dev/null && ok "foreign process survived" || bad "foreign process was killed"
[ -e "$STATE/chaos-webui.pid" ] && bad "stale pid file left" || ok "stale pid file removed"

# --- port already used by something else
python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 & BUSY_PID=$!
sleep 1
"$START" --no-open >/dev/null 2>"$STATE/err5"; rc=$?
assert_rc $rc 1 "start exits 1 when the port is busy"
[ -s "$STATE/err5" ] && ok "log tail printed on stderr" || bad "nothing on stderr"
[ -e "$STATE/chaos-webui.pid" ] && bad "pid file left after failed start" || ok "no stale pid file after failed start"
kill "$BUSY_PID" 2>/dev/null

# --- nothing references the old name outside archives
refs=$(cd "$ROOT" && grep -rIl "launch-flask-console" . 2>/dev/null | grep -v -E '^\./(debug|docs/archive|\.git|docs/adr|\.idea|\.claude|flask/tests/\.logs)/|chaos-webui.md|docs/specs/demo-console.md|docs/product/brief.md|tests/shell/test_launcher.sh' || true)
assert_eq "$refs" "" "no stale reference to launch-flask-console.sh"

finish
