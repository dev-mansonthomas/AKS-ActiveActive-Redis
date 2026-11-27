#!/usr/bin/env bash
# Runs every credential-free test of the chaos web console. Usable in the VM and on the host.
#   ./tests/run.sh            # all
#   ./tests/run.sh py|js|shell|lint
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
what="${1:-all}"
fail=0
run() { echo; echo "━━ $*"; "$@" || fail=$((fail + 1)); }

if [ "$what" = all ] || [ "$what" = py ]; then
  run uv run --no-project --quiet --with-requirements flask/requirements.txt \
        --with-requirements flask/requirements-dev.txt pytest flask/tests -q
fi
if [ "$what" = all ] || [ "$what" = js ]; then
  run node --test flask/tests/js/*.test.js
fi
if [ "$what" = all ] || [ "$what" = shell ]; then
  for t in tests/shell/test_*.sh; do [ -e "$t" ] && run bash "$t"; done
fi
if [ "$what" = all ] || [ "$what" = lint ]; then
  # Scripts people RUN must be executable (editors and `sed -i` on some mounts silently drop the bit).
  # Sourced libraries (common/*.sh, config*.sh) are exempt.
  nonexec=$(for f in ./*.sh scripts/*.sh tests/run.sh tests/shell/test_*.sh providers/*/*.sh; do
              [ -e "$f" ] && head -1 "$f" | grep -q '^#!' && [ ! -x "$f" ] && echo "$f"
            done | grep -v -E '^\./config(\.example)?\.sh$')
  if [ -n "$nonexec" ]; then echo "❌ not executable (chmod 700): $nonexec"; fail=$((fail + 1)); else echo "✅ executable bits"; fi
  # shellcheck disable=SC2046
  run shellcheck -S warning chaos-webui-start.sh chaos-webui-stop.sh scripts/chaos.sh common/chaos-notify.sh tests/run.sh $(ls tests/shell/*.sh 2>/dev/null)
  run ruff check flask common
fi
echo
if [ "$fail" -eq 0 ]; then echo "✅ all test groups passed"; else echo "❌ $fail test group(s) failed"; fi
exit "$fail"
