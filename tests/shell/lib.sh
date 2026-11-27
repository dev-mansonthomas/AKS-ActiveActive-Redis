#!/usr/bin/env bash
# Tiny assertion helpers for the shell tests. Source it; call `finish` at the end.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ✅ $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ❌ $*"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected '$2', got '$1')"; fi; }
assert_contains() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 ('$2' not in: ${1:0:200})" ;; esac; }
assert_not_contains() { case "$1" in *"$2"*) bad "$3 ('$2' found)" ;; *) ok "$3" ;; esac; }
assert_rc() { if [ "$1" -eq "$2" ]; then ok "$3"; else bad "$3 (exit $1, expected $2)"; fi; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
finish() { echo "  → $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }

# venv with the console's dependencies, cached between runs (uv is fast, the VM python has no Flask).
test_python() {
  local venv="${TMPDIR:-/tmp}/chaos-webui-test-venv"
  if [ ! -x "$venv/bin/python" ]; then
    uv venv --quiet "$venv" >/dev/null 2>&1 && \
    uv pip install --quiet --python "$venv/bin/python" -r "$ROOT/flask/requirements.txt" >/dev/null 2>&1
  fi
  echo "$venv/bin/python"
}
