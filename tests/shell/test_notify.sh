#!/usr/bin/env bash
# common/chaos-notify.sh — spec docs/specs/chaos-webui.md, slice 2 (chaos.sh -> console events).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "▶ chaos_notify"

LIB="$ROOT/common/chaos-notify.sh"
[ -r "$LIB" ] || { bad "common/chaos-notify.sh missing"; finish; exit 1; }

STATE="$(mktemp -d)"; PORT="$(free_port)"
export CHAOS_WEBUI_STATE_DIR="$STATE" CHAOS_WEBUI_PORT="$PORT"
export RE_CONFIG_FILE="$ROOT/flask/tests/fixtures/config.test.sh"
CHAOS_WEBUI_PYTHON="$(test_python)"; export CHAOS_WEBUI_PYTHON
BLACKHOLE=""
cleanup() { "$ROOT/chaos-webui-stop.sh" >/dev/null 2>&1; kill "$BLACKHOLE" 2>/dev/null; rm -rf "$STATE"; }
trap cleanup EXIT

state() { curl -fsS "http://127.0.0.1:$PORT/api/chaos/state"; }
jget()  { python3 -c "import sys,json; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

# --- server down: fast, silent exit status 0 under strict mode, one log line at most
(
  set -euo pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  export CHAOS_RUN_ID=r-down
  t0=$SECONDS
  chaos_notify run_start target=rec-a >"$STATE/down.out" 2>&1
  chaos_notify step phase=pod name=x status=PASS >>"$STATE/down.out" 2>&1
  chaos_notify run_end status=PASS >>"$STATE/down.out" 2>&1
  [ $((SECONDS - t0)) -le 3 ]
); assert_rc $? 0 "server down: returns fast and never fails under set -euo pipefail"
assert_eq "$(grep -c . "$STATE/down.out")" 1 "server down: exactly one line written (first failure only)"

# --- server that accepts but never answers: bounded by curl -m 2
python3 - "$PORT" <<'PY' &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5); time.sleep(30)
PY
BLACKHOLE=$!
sleep 0.5
(
  set -euo pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  export CHAOS_RUN_ID=r-hang
  t0=$SECONDS
  chaos_notify run_start >/dev/null 2>&1
  [ $((SECONDS - t0)) -le 4 ]
); assert_rc $? 0 "hanging server: call returns within the 2 s budget"
kill "$BLACKHOLE" 2>/dev/null; wait "$BLACKHOLE" 2>/dev/null; BLACKHOLE=""

# --- real server: a full run shows up in /api/chaos/state
"$ROOT/chaos-webui-start.sh" --no-open >/dev/null 2>&1; assert_rc $? 0 "console started for the test"
NOTE=$'say "hi"\nback\\slash <b>&'
(
  set -euo pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  export CHAOS_RUN_ID=r-full
  chaos_notify run_start target=rec-a witness=rec-b
  chaos_notify phase_start phase=node
  chaos_notify inject phase=node note="$NOTE"
  chaos_notify step phase=node name=node-recovery status=PASS seconds=61.5 note="recovered"
  chaos_notify phase_end phase=node status=PASS
  chaos_notify run_end status=PASS
); assert_rc $? 0 "full run sent"
S="$(state)"
assert_eq "$(printf '%s' "$S" | jget "d['run']['run_id']")" "r-full" "run id arrives"
assert_eq "$(printf '%s' "$S" | jget "d['run']['status']")" "PASS" "run ends PASS"
assert_eq "$(printf '%s' "$S" | jget "d['run']['recovered_seconds']")" "61.5" "seconds is a number"
assert_eq "$(printf '%s' "$S" | jget "d['run']['steps'][0]['note']" )" "$NOTE" "quotes, newline, backslash, markup survive JSON escaping"
assert_eq "$(printf '%s' "$S" | jget "d['run']['scenario']['title']")" "Node failure" "scenario text attached"

# --- invalid values never reach the server as broken JSON
(
  set -euo pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  export CHAOS_RUN_ID=r-bad
  chaos_notify run_start
  chaos_notify step phase=pod name=n status=PASS seconds=notanumber
); assert_rc $? 0 "non-numeric seconds does not break the call"
assert_eq "$(state | jget "len(d['run']['steps'])")" 1 "step still delivered (seconds dropped)"

# --- the notifier is not noisy when called with no run id
(
  set -euo pipefail
  # shellcheck source=/dev/null
  . "$LIB"
  unset CHAOS_RUN_ID
  chaos_notify run_start
); assert_rc $? 0 "missing run id is tolerated"

finish
