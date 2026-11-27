#!/usr/bin/env bash
# scripts/delete-all-resources.sh: it removes the clusters the Terraform STATE holds (stubbed tools).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "▶ teardown"

STUBS="$ROOT/tests/shell/stubs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$ROOT/tests/shell/fixtures/gcp.config.sh"
CL1=$(REPO_ROOT="$ROOT" bash -c ". '$CFG' >/dev/null 2>&1; echo \"\$CLUSTER1\"")
CL2=$(REPO_ROOT="$ROOT" bash -c ". '$CFG' >/dev/null 2>&1; echo \"\$CLUSTER2\"")

run_teardown() {  # run_teardown <name> -> OUT, RC, STUB_DIR
  STUB_DIR="$TMP/$1"; mkdir -p "$STUB_DIR"
  OUT=$(env STUB_DIR="$STUB_DIR" PATH="$STUBS:$PATH" RE_CONFIG_FILE="$CFG" DEBUG_DIR="$STUB_DIR/debug" \
        "$ROOT/scripts/delete-all-resources.sh" 2>&1 </dev/null)
  RC=$?
}
kubectl_ctxs() { grep -o -- '--context[= ][^ ]*' "$STUB_DIR/calls.log" 2>/dev/null | sed 's/--context[= ]//' | sort -u | tr '\n' ' '; }

# both deployed, both reachable
STUB_TOFU_STATE=$'google_container_cluster.region1[0]\ngoogle_container_cluster.region2[0]' run_teardown both
assert_rc $RC 0 "two clusters in state: teardown ok"
assert_contains "$(kubectl_ctxs)" "$CL1" "cluster 1 cleaned"
assert_contains "$(kubectl_ctxs)" "$CL2" "cluster 2 cleaned"

# single-cluster deployment: cluster 2 only. No flag, no failure about the cluster that never existed.
STUB_TOFU_STATE='google_container_cluster.region2[0]' run_teardown single2
assert_rc $RC 0 "only cluster 2 in state: teardown ok (no false 'still in state' failure)"
assert_not_contains "$(kubectl_ctxs)" "$CL1" "cluster 1 is never touched"
assert_contains "$(kubectl_ctxs)" "$CL2" "cluster 2 cleaned"

# a deployed cluster that cannot be reached IS a failure (disks / load balancer may leak)
STUB_TOFU_STATE=$'google_container_cluster.region1[0]\ngoogle_container_cluster.region2[0]' STUB_UNREACHABLE="$CL1" run_teardown unreachable
assert_rc $RC 1 "deployed but unreachable cluster: teardown reports the failure"
assert_contains "$OUT" "still in Terraform state but unreachable" "...and says why"

# state unreadable: falls back to both clusters, no crash
STUB_TOFU_FAIL=1 run_teardown nostate
assert_contains "$OUT" "clusters to remove" "unreadable state: still runs"

finish
