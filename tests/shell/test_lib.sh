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
bad_shebang=$(cd "$ROOT" && git ls-files '*.sh' | while read -r f; do [ -f "$f" ] && head -1 "$f" | grep -q '^#!' && ! head -1 "$f" | grep -q '^#!/usr/bin/env bash' && echo "$f"; done)
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

# ---- single-cluster selection (RE_CLUSTERS) ----------------------------------------------------
sel() { ( . "$ROOT/common/lib.sh"; CLUSTER1=cl-a CLUSTER2=cl-b REC_NAME1=rec-a REC_NAME2=rec-b REGION1=r-a REGION2=r-b "$@" ); }
assert_eq "$(sel re_selected_indexes)" "1 2" "no selection = both clusters (today's behaviour)"
assert_eq "$(RE_CLUSTERS=1 sel re_selected_indexes)" "1" "RE_CLUSTERS=1 -> cluster 1"
assert_eq "$(RE_CLUSTERS=2 sel re_selected_indexes)" "2" "RE_CLUSTERS=2 -> cluster 2"
assert_eq "$(RE_CLUSTERS='2 1' sel re_selected_indexes)" "1 2" "order is canonical"
assert_eq "$(RE_CLUSTERS='1 1' sel re_selected_indexes)" "1" "duplicates collapse"
RE_CLUSTERS=3 sel re_selected_indexes >/dev/null 2>&1; assert_rc $? 2 "RE_CLUSTERS=3 is refused (2)"
RE_CLUSTERS='x' sel re_selected_indexes >/dev/null 2>&1; assert_rc $? 2 "RE_CLUSTERS=x is refused (2)"
RE_CLUSTERS='  ' sel re_selected_indexes >/dev/null 2>&1; assert_rc $? 2 "blank selection is refused (2)"
assert_eq "$(sel re_cluster_name 2)/$(sel re_rec_name 2)/$(sel re_region_of 2)" "cl-b/rec-b/r-b" "name helpers by index"
sel re_is_single; assert_rc $? 1 "both clusters: not single"
RE_CLUSTERS=2 sel re_is_single; assert_rc $? 0 "RE_CLUSTERS=2: single"

# ---- which clusters does the Terraform state hold? ---------------------------------------------
st() { ( export PATH="$STUBS:$PATH" STUB_DIR="$TMP" CLOUD_PROVIDER="${CP:-gcp}"; . "$ROOT/common/lib.sh"; "$@" ); }
assert_eq "$(STUB_TOFU_STATE=$'google_compute_network.vpc\ngoogle_container_cluster.region1[0]\ngoogle_container_cluster.region2[0]' st re_clusters_in_state)" "1 2" "state with both clusters (count addresses)"
assert_eq "$(STUB_TOFU_STATE='google_container_cluster.region2' st re_clusters_in_state)" "2" "un-indexed address (state written before count) is recognised"
assert_eq "$(STUB_TOFU_STATE='google_compute_network.vpc' st re_clusters_in_state)" "" "no cluster in state: empty"
STUB_TOFU_FAIL=1 st re_clusters_in_state >/dev/null; assert_rc $? 2 "state unreadable: 2, not 'empty'"
assert_eq "$(CP=azure STUB_TOFU_STATE='azurerm_kubernetes_cluster.k8s2' st re_clusters_in_state)" "2" "azure addresses (k8s1/k8s2)"
STUB_TOFU_STATE='google_container_cluster.region2[0]' st re_cluster_in_state 2; assert_rc $? 0 "cluster 2 in state"
STUB_TOFU_STATE='google_container_cluster.region2[0]' st re_cluster_in_state 1; assert_rc $? 1 "cluster 1 not in state (cluster 2 is): per-cluster answer"
STUB_TOFU_STATE='google_container_cluster.region2[0]' st re_cluster_in_state; assert_rc $? 0 "no argument = any cluster, as before"

# ---- a selection must never silently delete a deployed cluster ----------------------------------
guard() { ( export PATH="$STUBS:$PATH" STUB_DIR="$TMP" CLOUD_PROVIDER=gcp CLUSTER1=cl-a CLUSTER2=cl-b; . "$ROOT/common/lib.sh"; re_selection_guard ) 2>&1; }
out=$(RE_CLUSTERS=1 STUB_TOFU_STATE='google_container_cluster.region2[0]' guard); rc=$?
assert_rc $rc 1 "selection 1 while cluster 2 is deployed: refused"
assert_contains "$out" "Cluster 2 (cl-b)" "...naming the cluster that would be deleted"
assert_contains "$out" "--destroy" "...and the way out"
RE_CLUSTERS=1 STUB_TOFU_STATE='google_container_cluster.region1[0]' guard >/dev/null; assert_rc $? 0 "same cluster again: fine (idempotent re-run)"
RE_CLUSTERS="1 2" STUB_TOFU_STATE='google_container_cluster.region1[0]' guard >/dev/null; assert_rc $? 0 "widening to both: fine (adds cluster 2)"
RE_CLUSTERS=1 STUB_TOFU_FAIL=1 guard >/dev/null; assert_rc $? 0 "state unreadable (fresh checkout): not blocked"

# ---- scripts run on their own follow the state when no flag set RE_CLUSTERS ----------------------
resolve() { ( export PATH="$STUBS:$PATH" STUB_DIR="$TMP" CLOUD_PROVIDER=gcp; unset RE_CLUSTERS; . "$ROOT/common/lib.sh"; re_resolve_clusters; printf '%s' "$RE_CLUSTERS" ); }
assert_eq "$(STUB_TOFU_STATE='google_container_cluster.region1[0]' resolve)" "1" "state holds cluster 1: RE_CLUSTERS=1"
assert_eq "$(STUB_TOFU_STATE='google_container_cluster.region2[0]' resolve)" "2" "state holds cluster 2: RE_CLUSTERS=2"
assert_eq "$(STUB_TOFU_STATE=$'google_container_cluster.region1[0]\ngoogle_container_cluster.region2[0]' resolve)" "1 2" "state holds both: 1 2"
assert_eq "$(STUB_TOFU_STATE='' resolve)" "1 2" "empty state: both (nothing deployed yet)"
assert_eq "$(STUB_TOFU_FAIL=1 resolve)" "1 2" "state unreadable: both"
resolve_keep() { ( export PATH="$STUBS:$PATH" STUB_DIR="$TMP" CLOUD_PROVIDER=gcp RE_CLUSTERS=2; . "$ROOT/common/lib.sh"; re_resolve_clusters; printf '%s' "$RE_CLUSTERS" ); }
assert_eq "$(STUB_TOFU_STATE='google_container_cluster.region1[0]' resolve_keep)" "2" "an explicit RE_CLUSTERS (set by a deploy) is never overridden"

# ---- the variable Terraform receives -------------------------------------------------------------
tfv() { ( export RE_OFFLINE=1 RE_CONFIG_FILE="$ROOT/tests/shell/fixtures/gcp.config.sh"; . "$ROOT/common/lib.sh" >/dev/null 2>&1; re_load_config >/dev/null 2>&1; re_export_tf_vars >/dev/null 2>&1; printf '%s' "${TF_VAR_clusters:-<unset>}" ); }
assert_eq "$(tfv)" '["1","2"]' "TF_VAR_clusters defaults to both clusters"
assert_eq "$(RE_CLUSTERS=2 tfv)" '["2"]' "TF_VAR_clusters follows RE_CLUSTERS"

finish
