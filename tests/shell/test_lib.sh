#!/usr/bin/env bash
# common/lib.sh helpers: bash guard, re_cluster_in_state, re_disable_client_auth (stubbed kubectl / tofu).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "▶ common/lib.sh"

STUBS="$ROOT/tests/shell/stubs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- bash 5 is required (macOS /bin/bash is 3.2: put Homebrew's bash first in PATH) ----------
out=$(RE_MIN_BASH_MAJOR=99 bash -c ". '$ROOT/common/lib.sh'" 2>&1); rc=$?
assert_rc $rc 1 "a too-old bash is refused (exit 1)"
assert_contains "$out" "brew install bash" "...with the command that fixes it"
assert_contains "$out" "PATH" "...and the PATH hint (the shebang is env bash)"
out=$(bash -c ". '$ROOT/common/lib.sh'; echo loaded" 2>&1); rc=$?
assert_eq "$out" "loaded" "the bash running the tests is accepted silently"

# every script people run asks the PATH for bash (portable: Homebrew's bash 5 wins when it comes first)
bad_shebang=$(cd "$ROOT" && git ls-files '*.sh' | while read -r f; do [ -f "$f" ] && head -1 "$f" | grep -qv '^#!/usr/bin/env bash' && echo "$f"; done)
assert_eq "$bad_shebang" "" "every tracked *.sh uses #!/usr/bin/env bash"

# ---- re_cluster_in_state: yes / no / cannot tell ------------------------------------------------
run_state() { ( export PATH="$STUBS:$PATH" STUB_DIR="$TMP" CLOUD_PROVIDER=gcp; . "$ROOT/common/lib.sh"; re_cluster_in_state ); }
run_state; assert_rc $? 0 "cluster in the Terraform state: 0"
STUB_TOFU_STATE="" run_state; assert_rc $? 1 "empty state: 1 (the cluster is gone)"
STUB_TOFU_FAIL=1 run_state; assert_rc $? 2 "state unreadable (locked, not initialised): 2, NOT 'gone'"

# ---- re_disable_client_auth: the peer instance may not have its database yet ---------------------
run_auth() { ( export PATH="$STUBS:$PATH" STUB_DIR="$TMP" NS=rec AA_DB_NAME=aadb RE_REST_RETRY_DELAY=0 RE_REST_RETRIES=5
               . "$ROOT/common/lib.sh"; re_disable_client_auth cl-b rec-b ) 2>&1; }
rm -f "$TMP/bdb_calls"; out=$(run_auth); rc=$?
assert_rc $rc 0 "database visible at once: done"
rm -f "$TMP/bdb_calls"; out=$(STUB_BDB_MISSING=2 run_auth); rc=$?
assert_rc $rc 0 "database appears on the 3rd look-up: retried, done"
assert_eq "$(cat "$TMP/bdb_calls")" 3 "...after exactly 3 look-ups"
rm -f "$TMP/bdb_calls"; out=$(STUB_BDB_MISSING=99 run_auth); rc=$?
assert_rc $rc 1 "database never appears: gives up (exit 1)"
assert_eq "$(cat "$TMP/bdb_calls")" 5 "...after the configured number of attempts"
assert_contains "$out" "not found" "...and says why"
rm -f "$TMP/bdb_calls"; out=$(STUB_PUT_CODE=500 run_auth); rc=$?
assert_rc $rc 1 "REST PUT refused: fails"
assert_contains "$out" "HTTP 500" "...with the HTTP code"

finish
