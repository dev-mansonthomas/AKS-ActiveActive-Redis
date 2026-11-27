#!/usr/bin/env bash
# scripts/chaos.sh with stubbed kubectl / gcloud / curl — spec docs/specs/chaos-webui.md (2a, 2).
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "▶ chaos.sh"

CHAOS="$ROOT/scripts/chaos.sh"
STUBS="$ROOT/tests/shell/stubs"
ROOT_TMP="$(mktemp -d)"
trap 'rm -rf "$ROOT_TMP"' EXIT

# run_chaos <name> <args...>  -> sets OUT, RC, STUB_DIR (events.log, calls.log inside)
run_chaos() {
  local name="$1"; shift
  STUB_DIR="$ROOT_TMP/$name"; mkdir -p "$STUB_DIR"
  OUT=$(env STUB_DIR="$STUB_DIR" PATH="$STUBS:$PATH" RE_CONFIG_FILE="$ROOT/tests/shell/fixtures/chaos.config.sh" \
        DEBUG_DIR="$STUB_DIR/debug" CHAOS_DEGRADE_WAIT=0 CHAOS_TIMEOUT=20 CHAOS_WEBUI_PORT=5999 CHAOS_INJECT_VERIFY_WAIT=${CHAOS_INJECT_VERIFY_WAIT:-4} CHAOS_AUTOSCALER_SETTLE=0 \
        "$CHAOS" "$@" 2>&1 </dev/null)
  RC=$?
}
# phases announced, in order
phases() { python3 - "$STUB_DIR/events.log" <<'PY'
import json, sys
seen = []
for line in open(sys.argv[1]):
    e = json.loads(line)
    if e["type"] == "phase_start":
        seen.append(e["phase"])
print(" ".join(seen))
PY
}
types() { python3 - "$STUB_DIR/events.log" <<'PY'
import json, sys
print(" ".join(json.loads(l)["type"] for l in open(sys.argv[1])))
PY
}
has_event() { python3 - "$STUB_DIR/events.log" "$1" <<'PY'
import json, sys
want = json.loads(sys.argv[2])
for line in open(sys.argv[1]):
    e = json.loads(line)
    if all(e.get(k) == v for k, v in want.items()):
        sys.exit(0)
sys.exit(1)
PY
}

# ---------------------------------------------------------------- --list
before=$(ls "$ROOT/debug" 2>/dev/null | wc -l)
LIST=$(env -i PATH=/usr/bin:/bin RE_CONFIG_FILE=/nonexistent "$CHAOS" --list 2>&1); rc=$?
assert_rc $rc 0 "--list exits 0 with no config, no cloud CLI"
for id in pod node region region-recover; do assert_contains "$LIST" "$id" "--list shows $id"; done
assert_eq "$(ls "$ROOT/debug" 2>/dev/null | wc -l)" "$before" "--list writes no log"
listed=$(printf '%s\n' "$LIST" | awk '$1 ~ /^(pod|node|region|region-recover)$/ {print $1}' | tr '\n' ' ' | sed 's/ $//')
py=$(python3 -c "import sys; sys.path.insert(0,'$ROOT/flask'); import scenarios; print(' '.join(scenarios.SELECTABLE))")
assert_eq "$listed" "$py" "--list ids == flask/scenarios.py SELECTABLE (same order)"

# ------------------------------------------------------ bad scenario id
run_chaos bad --scenario nope
assert_rc $RC 2 "unknown scenario exits 2"
assert_contains "$OUT" "pod" "message lists the valid ids"
[ -e "$STUB_DIR/events.log" ] && bad "events sent for a rejected command" || ok "nothing was sent or injected"

# ------------------------------------------------------ one scenario
run_chaos node --no-prompt --scenario node
assert_rc $RC 0 "--scenario node exits 0 (healthy stubs)"
assert_eq "$(phases)" "health node" "only health gate + node were announced"
grep -q "instances reset" "$STUB_DIR/calls.log" && ok "VM reset was played" || bad "no VM reset"
grep -q "delete pod" "$STUB_DIR/calls.log" && bad "pod scenario ran by mistake" || ok "pod scenario did not run"
has_event '{"type":"inject","phase":"node"}' && ok "inject event for node" || bad "no inject event"
has_event '{"type":"step","name":"node-recovery","status":"PASS"}' && ok "node-recovery step sent" || bad "no node-recovery step"
assert_eq "$(types | awk '{print $1, $NF}')" "run_start run_end" "run starts and ends"
has_event '{"type":"run_end","status":"PASS"}' && ok "run_end PASS" || bad "run_end not PASS"

# ------------------------------------------------------ which pod is killed
deleted_pod() { grep -o 'delete pod [^ ]*' "$STUB_DIR/calls.log" | head -1 | awk '{print $3}'; }
reset_vm()    { grep -o 'instances reset [^ ]*' "$STUB_DIR/calls.log" | head -1 | awk '{print $3}'; }
run_chaos pod-auto --no-prompt --scenario pod
assert_eq "$(deleted_pod)" "rec-a-1" "default: RE node 2 (rec-a-1), not the master rec-a-0 nor rec-a-2"
assert_contains "$OUT" "rec-a-1" "the chosen pod is announced"
has_event '{"type":"inject","phase":"pod"}' && ok "inject names the pod" || bad "no inject"
assert_contains "$(grep '"type":"inject"' "$STUB_DIR/events.log")" "rec-a-1" "inject note carries the pod name"
STUB_TOPOLOGY=failed-over run_chaos pod-fo --no-prompt --scenario pod
assert_eq "$(deleted_pod)" "rec-a-1" "after a failover (master+endpoint on node 3, shards on nodes 1 AND 2): still node 2, not the lower index"
STUB_TOPOLOGY=master-on-3 run_chaos pod-auto2 --no-prompt --scenario pod
assert_eq "$(deleted_pod)" "rec-a-1" "node 2 is eligible whatever its shard role (it holds no shard here): rec-a-1"
STUB_TOPOLOGY=master-on-2 run_chaos pod-auto3 --no-prompt --scenario pod
assert_eq "$(deleted_pod)" "rec-a-0" "node 2 is master+endpoint: never killed; falls back to the replica holding a shard (rec-a-0)"
run_chaos pod-idx --no-prompt --scenario pod --pod 0
assert_eq "$(deleted_pod)" "rec-a-0" "--pod 0 forces the primary pod (worst case)"
assert_contains "$OUT" "cluster primary" "forced primary pod is described as such"
run_chaos pod-name --no-prompt --scenario pod --pod rec-a-1
assert_eq "$(deleted_pod)" "rec-a-1" "--pod rec-a-1 by name"
run_chaos pod-bad --no-prompt --scenario pod --pod 9
assert_rc $RC 2 "--pod out of range exits 2"
run_chaos pod-bad2 --no-prompt --scenario pod --pod rec-b-1
assert_rc $RC 2 "--pod of the other cluster exits 2"
run_chaos node-vm --no-prompt --scenario node
assert_eq "$(reset_vm)" "vm-of-rec-a-1" "node scenario resets the VM hosting the chosen replica, not an arbitrary node"

# ------------------------------------------------------ the console hears about the recovery at once
run_chaos fast --no-prompt --scenario pod
ev=$(grep -n 'EVENT.*"name":"pod-recovery"' "$STUB_DIR/order.log" | head -1 | cut -d: -f1)
inj=$(grep -n 'EVENT.*"type":"inject"' "$STUB_DIR/order.log" | head -1 | cut -d: -f1)
between=$(sed -n "${inj},${ev}p" "$STUB_DIR/order.log" | grep -c "get events" || true)
[ -n "$ev" ] && [ "$between" -eq 0 ] && ok "pod-recovery is sent BEFORE the (slow) snapshot, not after it" || bad "pod-recovery delayed by a snapshot (events between inject and recovery: $between)"
STUB_SLOW=2 run_chaos base --no-prompt --scenario pod
secs=$(grep '"name":"pod-recovery"' "$STUB_DIR/events.log" | head -1 | sed 's/.*"seconds":\([0-9.]*\).*/\1/')
[ "${secs%.*}" -ge 2 ] && ok "recovery time is measured from the injection (got ${secs}s for a 2 s delete)" || bad "recovery time ${secs}s ignores the time spent injecting"

# ------------------------------------------------------ order is canonical
run_chaos order --no-prompt --scenario node,pod
assert_eq "$(phases)" "health pod node" "node,pod is played as pod then node"

# ------------------------------------------------------ default = all three
run_chaos all --no-prompt
assert_rc $RC 0 "default run exits 0"
assert_eq "$(phases)" "health pod node region" "no option plays pod, node, region"
grep -q "resize" "$STUB_DIR/calls.log" && ok "region outage played" || bad "no region resize"
has_event '{"type":"step","name":"region-recovery","status":"PASS"}' && ok "region-recovery total sent (timer freezes on it)" || bad "no region-recovery step"

# ------------------------------------------------------ announce before the prompt
grep -q '"type":"phase_start","run_id"' "$STUB_DIR/events.log" && ok "phase_start events exist" || bad "no phase_start"
first=$(grep -n "phase_start" "$STUB_DIR/events.log" | sed -n 2p | cut -d: -f1)
inj=$(grep -n '"type":"inject"' "$STUB_DIR/events.log" | head -1 | cut -d: -f1)
[ -n "$first" ] && [ -n "$inj" ] && [ "$first" -lt "$inj" ] && ok "phase_start precedes inject (console shows 'ready' before the presenter acts)" || bad "ordering phase_start/inject"

# ------------------------------------------------------ region-recover alone
run_chaos rr --no-prompt --scenario region-recover
assert_rc $RC 0 "region-recover on a healthy stub exits 0"
assert_eq "$(phases)" "region-recover" "no health gate for region-recover"
assert_contains "$OUT" "skipped" "the skipped gate is announced"
grep -q "patch rec" "$STUB_DIR/calls.log" && bad "recovery commands issued on an already healthy cluster" || ok "healthy cluster: nothing to recover, no clusterRecovery patch"
STUB_RECOVER_NEEDED=1 run_chaos rr2 --no-prompt --scenario region-recover
assert_rc $RC 0 "region-recover on a degraded stub exits 0"
grep -q "patch rec" "$STUB_DIR/calls.log" && ok "clusterRecovery issued" || bad "no clusterRecovery"
grep -q "rladmin recover all" "$STUB_DIR/calls.log" && ok "rladmin recover all issued" || bad "no rladmin recover all"
grep -q "resize" "$STUB_DIR/calls.log" && ok "node pool restored" || bad "node pool not restored"

# ------------------------------------------------------ health gate: refuses a broken setup, --skip-check bypasses it
STUB_RECOVER_NEEDED=1 run_chaos gate-bad --no-prompt --scenario pod
assert_rc $RC 3 "unhealthy setup: the gate refuses (exit 3)"
grep -q "delete pod" "$STUB_DIR/calls.log" && bad "pod deleted despite a failed gate" || ok "nothing injected after a failed gate"
# the operator's own replicationStatus can lag behind reality (seen after pod kills): advisory, the
# real write/read through both regions stays the hard check
STUB_REAADB=active/down run_chaos repl-down --no-prompt --check-only
assert_rc $RC 0 "operator says replication 'down' but data flows: the gate passes"
assert_contains "$OUT" "⚠️" "...with a visible warning"
assert_contains "$OUT" "replication" "...that names the replication status"
STUB_REAADB=pending/up run_chaos aadb-pending --no-prompt --check-only
assert_rc $RC 3 "REAADB not active: the gate refuses"
run_chaos skip --no-prompt --skip-check --scenario pod
assert_rc $RC 0 "--skip-check exits 0 on a healthy stub"
assert_eq "$(phases)" "pod" "--skip-check: no health phase announced"
assert_contains "$OUT" "skipped" "--skip-check says the gate is skipped"
grep -q "delete pod" "$STUB_DIR/calls.log" && ok "pod scenario ran" || bad "pod scenario did not run"
has_event '{"type":"step","name":"health-check","status":"INFO"}' && ok "console told the check was skipped" || bad "console not told"
run_chaos skip-co --no-prompt --skip-check --check-only
assert_rc $RC 2 "--skip-check with --check-only is contradictory (exit 2)"

# ------------------------------------------------------ cloud login: checked by the gate, with the command to fix it
run_chaos auth-ok --no-prompt --check-only
assert_contains "$OUT" "cloud authentication" "the gate reports the cloud login"
STUB_GCLOUD_UNAUTH=1 run_chaos auth-bad --no-prompt --scenario pod
assert_rc $RC 3 "not logged in: the gate refuses (exit 3)"
assert_contains "$OUT" "gcloud auth login tester@example.com" "...and prints the command to log in again"
grep -q "delete pod" "$STUB_DIR/calls.log" && bad "pod deleted while not logged in" || ok "nothing injected while not logged in"
# the login can lapse DURING a long run: the region scenario re-checks right before touching the pool
STUB_GCLOUD_UNAUTH=1 run_chaos auth-bad2 --no-prompt --skip-check --scenario region
assert_rc $RC 1 "login lapsed before region: the run fails"
grep -q "resize" "$STUB_DIR/calls.log" && bad "node pool touched while not logged in" || ok "node pool untouched while not logged in"

# ------------------------------------------------------ an option without its value is a usage error (2), with a message
run_chaos novalue --scenario
assert_rc $RC 2 "--scenario without a value exits 2"
assert_contains "$OUT" "--scenario" "...and says which option lacks its value"
run_chaos novalue2 --no-prompt --pod
assert_rc $RC 2 "--pod without a value exits 2"

# ------------------------------------------------------ the nodes never come back: bounded, not an endless loop
STUB_POOL_STUCK=1 CHAOS_NODES_TIMEOUT=3 run_chaos stuck --no-prompt --scenario region
assert_rc $RC 1 "pool that never returns Ready nodes: the run FAILS instead of hanging"
has_event '{"type":"step","name":"region-restore","status":"FAIL"}' && ok "region-restore FAIL reported" || bad "no region-restore FAIL"

# ------------------------------------------------------ --check-only ignores --scenario
run_chaos co --no-prompt --check-only --scenario node
assert_rc $RC 0 "--check-only exits 0"
assert_eq "$(phases)" "health" "--check-only announces only the health gate"
grep -q "instances reset" "$STUB_DIR/calls.log" && bad "check-only injected" || ok "check-only injected nothing"


# ------------------------------------------------------ audit trail: what a reviewer needs in the log
run_chaos audit --no-prompt --scenario region
LOG=$(ls "$STUB_DIR"/debug/chaos-2*.log | head -1)
EVF="${LOG%.log}.events.jsonl"
[ -s "$EVF" ] && ok "machine-readable events file next to the log" || bad "no events file ($EVF)"
bad_lines=$(python3 - "$EVF" <<'PY'
import json, sys
n = 0
for l in open(sys.argv[1]):
    try: json.loads(l)
    except ValueError: n += 1
print(n)
PY
)
assert_eq "$bad_lines" 0 "every events line is valid JSON"
for t in run_start phase_start inject step run_end; do
  grep -q "\"type\":\"$t\"" "$EVF" && ok "events file has $t" || bad "events file lacks $t"
done
grep -q '"t":' "$EVF" && ok "events carry the elapsed seconds (t)" || bad "no elapsed time in events"
assert_contains "$(cat "$LOG")" "Tooling" "header names the tooling (git revision, kubectl, gcloud)"
assert_contains "$(cat "$LOG")" "▶ gcloud" "provider commands are announced with a timestamp"
assert_contains "$(cat "$LOG")" "◀ gcloud" "...and closed with their exit code and duration"
assert_contains "$(cat "$LOG")" "[sample" "state samples (nodes, pods, instances) are logged during the outage"
assert_contains "$(cat "$LOG")" "autoscaling.enabled according to the API" "autoscaling state is read back from the API before the resize"
assert_contains "$(cat "$LOG")" "RESULT run=" "closing RESULT line"
assert_contains "$(cat "$LOG")" "--no-prompt" "unattended: the skipped prompts are said so"
has_event '{"type":"step","name":"region-injected","status":"PASS"}' && ok "region outage verified (0 nodes left) and reported" || bad "region-injected not PASS"
assert_contains "$(cat "$LOG")" "operator" "snapshots include the operator log"
assert_contains "$(cat "$LOG")" "crdb-cli" "snapshots include the Active-Active (crdb-cli) view"

STUB_NODES_REMAIN=1 CHAOS_INJECT_VERIFY_WAIT=2 run_chaos noeffect --no-prompt --scenario region
assert_rc $RC 1 "outage that did not take effect: the run FAILS (it used to pass silently)"
has_event '{"type":"step","name":"region-injected","status":"FAIL"}' && ok "region-injected FAIL reported" || bad "no region-injected FAIL"
STUB_REGION_NOEFFECT=1 run_chaos noeffect2 --no-prompt --scenario region
assert_rc $RC 1 "resize that removes nothing: the instance wait times out and the run FAILS"
has_event '{"type":"step","name":"region-inject","status":"FAIL"}' && ok "region-inject FAIL reported" || bad "no region-inject FAIL"
grep -q "enable-autoscaling" "$STUB_DIR/calls.log" && ok "failed injection: autoscaling is switched back on (no drift left behind)" || bad "pool left with autoscaling off after a failed injection"

# ------------------------------------------------------ console down: run unaffected
STUB_CURL_DOWN=1 run_chaos down --no-prompt --scenario pod
assert_rc $RC 0 "console unreachable: the run still succeeds"
assert_eq "$(printf '%s\n' "$OUT" | grep -c '\[chaos console\]')" 1 "console unreachable: exactly one warning line"

# ------------------------------------------------------ offer to start the console
STUB_CONSOLE_DOWN=1 run_chaos hint --no-prompt --check-only
assert_contains "$OUT" "chaos-webui-start.sh" "--no-prompt: hint to start the console"
assert_not_contains "$OUT" "Start the chaos console now?" "--no-prompt: no question asked"
STUB_DIR="$ROOT_TMP/ask"; mkdir -p "$STUB_DIR"
OUT=$(printf 'n\n' | env STUB_CONSOLE_DOWN=1 STUB_DIR="$STUB_DIR" PATH="$STUBS:$PATH" \
      RE_CONFIG_FILE="$ROOT/tests/shell/fixtures/chaos.config.sh" DEBUG_DIR="$STUB_DIR/debug" \
      CHAOS_DEGRADE_WAIT=0 CHAOS_WEBUI_PORT=5999 "$CHAOS" --check-only 2>&1)
assert_contains "$OUT" "Start the chaos console now?" "interactive: the console is offered"
assert_eq "$(printf '%s' "$OUT" | grep -c 'Press Enter')" 0 "answering n continues without starting it"

# ------------------------------------------------------ interrupted run is reported ABORTED
STUB_DIR="$ROOT_TMP/abort"; mkdir -p "$STUB_DIR"
( exec env STUB_SLOW=20 STUB_DIR="$STUB_DIR" PATH="$STUBS:$PATH" RE_CONFIG_FILE="$ROOT/tests/shell/fixtures/chaos.config.sh" \
  DEBUG_DIR="$STUB_DIR/debug" CHAOS_DEGRADE_WAIT=0 CHAOS_TIMEOUT=20 CHAOS_WEBUI_PORT=5999 \
  "$CHAOS" --no-prompt --scenario pod >"$STUB_DIR/out" 2>&1 </dev/null ) &
RUNNER=$!
for _ in $(seq 1 40); do grep -q '"type":"inject"' "$STUB_DIR/events.log" 2>/dev/null && break; sleep 0.25; done
kill -TERM "$RUNNER" 2>/dev/null
wait "$RUNNER" 2>/dev/null
has_event '{"type":"run_end","status":"ABORTED"}' && ok "killed run ends ABORTED" || bad "no ABORTED run_end after SIGTERM"

finish
