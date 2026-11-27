#!/usr/bin/env bash
# gcp-deploy.sh / common/deploy-lib.sh: the --single option (stubbed tofu / gcloud, no cloud).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "▶ deploy options"

STUBS="$ROOT/tests/shell/stubs"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ---- option parsing (unit level) ---------------------------------------------------------------
parse() { ( DEPLOY_CLOUD="${CLOUD:-gcp}"; . "$ROOT/common/deploy-lib.sh"; deploy_parse_args "$@"; echo "SINGLE=${SINGLE:-} PLAN_ONLY=$PLAN_ONLY DESTROY=$DESTROY" ) 2>&1; }
assert_eq "$(parse)" "SINGLE= PLAN_ONLY=0 DESTROY=0" "no option: both clusters (SINGLE empty)"
assert_eq "$(parse --single)" "SINGLE=1 PLAN_ONLY=0 DESTROY=0" "--single alone = cluster 1"
assert_eq "$(parse --single 2)" "SINGLE=2 PLAN_ONLY=0 DESTROY=0" "--single 2 = cluster 2"
assert_eq "$(parse --single 1)" "SINGLE=1 PLAN_ONLY=0 DESTROY=0" "--single 1 = cluster 1"
assert_eq "$(parse --single --plan-only)" "SINGLE=1 PLAN_ONLY=1 DESTROY=0" "--single followed by another option does not eat it"
assert_eq "$(parse --plan-only --single 2)" "SINGLE=2 PLAN_ONLY=1 DESTROY=0" "options in any order"
out=$(parse --single 3); rc=$?
assert_rc $rc 2 "--single 3 is refused (2)"
assert_contains "$out" "unknown option: 3" "...the 3 is not swallowed silently"
out=$(CLOUD=aws parse --single); rc=$?
assert_rc $rc 2 "--single on aws is refused (2)"
assert_contains "$out" "only supported on gcp" "...with the reason"
out=$(CLOUD=azure parse --single 2); assert_rc $? 2 "--single on azure is refused (2)"
assert_contains "$(parse --help)" "--single" "--help documents the option"

# ---- banner -------------------------------------------------------------------------------------
banner() { ( export DEPLOY_CLOUD=gcp CLUSTER1=cl-a CLUSTER2=cl-b REGION1=r-a REGION2=r-b INSTANCE_TYPE=m DNS_ZONE=z owner=o; . "$ROOT/common/deploy-lib.sh"; deploy_banner "X" ); }
assert_contains "$(banner)" "cl-a, cl-b" "banner: both clusters by default"
assert_contains "$(RE_CLUSTERS=2 banner)" "cl-b" "banner: the selected cluster"
assert_not_contains "$(RE_CLUSTERS=2 banner)" "cl-a" "banner: ...and only that one"

# ---- end to end up to `tofu plan` (stubs) ------------------------------------------------------
run_deploy() {  # run_deploy <name> <args...> -> OUT, RC, STUB_DIR
  local name="$1"; shift
  STUB_DIR="$TMP/$name"; mkdir -p "$STUB_DIR"
  OUT=$(env STUB_DIR="$STUB_DIR" PATH="$STUBS:$PATH" RE_CONFIG_FILE="$ROOT/tests/shell/fixtures/gcp.config.sh" \
        DEBUG_DIR="$STUB_DIR/debug" "$ROOT/gcp-deploy.sh" --skip-preflight "$@" 2>&1 </dev/null)
  RC=$?
}
run_deploy plan2 --plan-only
assert_rc $RC 0 "--plan-only, both clusters"
assert_contains "$(cat "$STUB_DIR/calls.log")" 'TF_VAR_clusters=["1","2"]' "Terraform receives both clusters"
run_deploy plan1 --plan-only --single
assert_rc $RC 0 "--plan-only --single"
assert_contains "$(grep 'tofu plan' "$STUB_DIR/calls.log")" 'TF_VAR_clusters=["1"]' "Terraform receives cluster 1 only"
STUB_TOFU_STATE='' run_deploy plan1b --plan-only --single 2
assert_contains "$(grep 'tofu plan' "$STUB_DIR/calls.log")" 'TF_VAR_clusters=["2"]' "--single 2: Terraform receives cluster 2 only"

# narrowing would delete a deployed cluster: refused before any plan
STUB_TOFU_STATE='google_container_cluster.region2[0]' run_deploy narrow --plan-only --single 1
assert_rc $RC 2 "--single 1 while cluster 2 is deployed: refused (2)"
assert_contains "$OUT" "--destroy" "...and says how to get out"
grep -q 'tofu plan' "$STUB_DIR/calls.log" && bad "tofu plan ran despite the refusal" || ok "no tofu plan after the refusal"
STUB_TOFU_STATE='google_container_cluster.region1[0]' run_deploy same --plan-only --single 1
assert_rc $RC 0 "same cluster again: allowed"

# --destroy follows the state, whatever the flag says
STUB_TOFU_STATE='google_container_cluster.region2[0]' run_deploy destroy --destroy --single 1
assert_contains "$OUT" "ignored" "--destroy --single: the flag is ignored (the state decides)"

# ---- 05-get-cluster-info.sh run on its own must not touch a cluster that is not deployed ----------
CFG="$ROOT/tests/shell/fixtures/gcp.config.sh"
CL2=$(REPO_ROOT="$ROOT" bash -c ". '$CFG' >/dev/null 2>&1; echo \"\$CLUSTER2\"")
STUB_DIR="$TMP/info"; mkdir -p "$STUB_DIR"
OUT=$(env STUB_DIR="$STUB_DIR" PATH="$STUBS:$PATH" RE_CONFIG_FILE="$CFG" DEBUG_DIR="$STUB_DIR/debug" \
      STUB_TOFU_STATE='google_container_cluster.region1[0]' "$ROOT/scripts/05-get-cluster-info.sh" 2>&1 </dev/null)
assert_not_contains "$(cat "$STUB_DIR/calls.log")" "$CL2" "05 alone, state holds cluster 1: cluster 2 (stale kubeconfig context?) is never queried"
assert_contains "$OUT" "single-cluster deployment" "05 says there is no database in a single-cluster deployment"

finish
