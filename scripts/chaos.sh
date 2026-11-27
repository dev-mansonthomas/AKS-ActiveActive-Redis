#!/usr/bin/env bash

###############################################################################
# Redis Enterprise - Active-Active Chaos Testing Script (Azure AKS, GCP GKE)
#
# Simulates three failures on ONE cluster of the Active-Active pair, measures
# the recovery, and checks the data path after each of them. The scenario is the
# same on every cloud; only 3 primitives differ (see the provider_* functions):
#   provider_prepare, provider_restart_node, provider_region_down / _up.
#   Azure: VMSS instance restart + `az aks stop/start`.
#   GCP  : `gcloud compute instances reset` + node pool resized to 0 and back.
#   AWS  : not supported yet (docs/TODO.md A6).
#
# Scenario (the other cluster is never touched; it is the witness):
#   0. Health gate (BOTH clusters, before anything is injected; any failure stops
#      the run with exit 3 and prints what is wrong): Kubernetes API, node pool,
#      nodes Ready, REC pods Running/Ready, REC object, rladmin nodes+databases,
#      RERC Active, REAADB active/replication up, write/read on both regions
#   1. Pod       : force-delete <rec>-0                       -> wait, check
#   2. Node      : hard-reset one cloud VM                    -> wait, check
#   3. Region    : remove every node of the cluster; the survivor must keep
#                  serving; bring nodes back, REC clusterRecovery, rladmin
#                  recover all                                -> wait, check
#   Final: PASS/FAIL table, exit 1 if anything failed.
#
# Checks after each phase (all in the log, none of them needs a tool on the host
# besides kubectl and the cloud CLI):
#   - pods Running, all nodes Ready, expected pod/node counts
#   - `rladmin status nodes`   : every RE node OK (RE_NODES of them)
#   - `rladmin status databases`: every database active
#   - data path: SET on one region, GET on both (replication), through
#     redis-cli run inside a REC pod (no DNS / TLS / SNI dependency)
#
# Why the health check is not just "rladmin status" on <rec>-0: the pod we kill
# IS <rec>-0, so that probe fails by construction while it restarts. Probes go
# to the other pods first.
#
# Logs: EVERYTHING (this script, kubectl, rladmin, cloud CLI) goes to
#   debug/chaos-<timestamp>.log   (+ debug/chaos-latest.log)   [gitignored]
# The console shows the summary lines; kubectl/rladmin snapshots are written to
# the log file only.
#
# Prerequisites:
#  - The cloud CLI of CLOUD_PROVIDER authenticated (az / gcloud), HOST ONLY
#  - config.sh (CLUSTER1/2, REC_NAME1/2, NS, RE_NODES, AA_DB_NAME, ...)
#  - Optional: the Flask console (flask/app.py) running to watch the impact
#
# Usage:
#   ./scripts/chaos.sh                          # cluster 1, interactive (Enter between phases)
#   ./scripts/chaos.sh <cluster-name>           # $CLUSTER1 or $CLUSTER2
#   ./scripts/chaos.sh --no-prompt              # unattended (aliases: --yes, -y)
#   ./scripts/chaos.sh --check-only             # health gate only, injects nothing (use before a demo)
#   ./scripts/chaos.sh --skip-check             # DEV: skip the health gate (results may be unpredictable)
#   ./scripts/chaos.sh --list                   # the scenarios you can pick (needs no cloud access)
#   ./scripts/chaos.sh --scenario node          # play ONE scenario (resume after an interruption)
#   ./scripts/chaos.sh --scenario pod,node      # several, always played in the canonical order
#   ./scripts/chaos.sh --scenario pod --pod 0   # force the pod to kill (index or name); default = auto
#   ./scripts/chaos.sh --scenario region-recover  # bring a region left down / half-recovered back
#   ./scripts/chaos.sh --no-prompt <cluster-name>
#   CHAOS_TIMEOUT=1200 ./scripts/chaos.sh -y    # per-phase recovery timeout, seconds (default 900)
# The pod/node scenarios kill, by default, RE node 2 (pod index 1) unless it is the cluster primary or
# holds the database endpoint, in which case another replica holding a shard is taken (all read from
# `rladmin status`; the primary or replica role of the shard does not matter): losing the primary pod also takes the REST API
# and the endpoint of that region down for a while, which is a different (worst-case) demo.
# --pod <index|name> forces the victim, e.g. --pod 0 for the primary pod.
# Without --scenario: pod, node, region. region-recover skips the health gate (the cluster is
# degraded by definition); every other scenario keeps it.
# The chaos web console (./chaos-webui-start.sh) is told about every phase and step
# (common/chaos-notify.sh, best effort: chaos.sh never depends on it).
# Exit: 0 all checks passed, 1 a check failed or recovery timed out, 2 bad usage,
#       3 health gate failed (nothing was injected).
###############################################################################
set -euo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
[ -r "$_LIB" ] || { echo "FATAL: cannot read $_LIB" >&2; exit 1; }
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }
# ---- scenario catalogue (ids shared with flask/scenarios.py; a test keeps them in sync) --------
SCENARIO_IDS=(pod node region region-recover)
scenario_desc() {
  case "$1" in
    pod)            echo "Force-delete one Redis Enterprise pod (a replica by default, --pod to choose); it is recreated" ;;
    node)           echo "Hard-reset the cloud VM hosting that pod; the node comes back by itself" ;;
    region)         echo "Remove every node of the target region, check the other one serves, then recover" ;;
    region-recover) echo "Resume: bring back a region left down or half-recovered (skips the health gate)" ;;
  esac
}
list_scenarios() {
  echo "Scenarios for: $0 --scenario <id[,id...]>   (default: pod,node,region)"
  local id
  for id in "${SCENARIO_IDS[@]}"; do printf '  %-15s %s\n' "$id" "$(scenario_desc "$id")"; done
}
valid_ids() { local IFS=,; echo "${SCENARIO_IDS[*]}"; }

# ---- arguments (first pass: needs no config, no cloud) ------------------------------------------
INTERACTIVE=1
CHECK_ONLY=0
SKIP_CHECK=0
SCENARIO_ARG=""
CLUSTER_ARG=""
POD_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-prompt|--yes|-y) INTERACTIVE=0 ;;
    --check-only) CHECK_ONLY=1 ;;
    --skip-check) SKIP_CHECK=1 ;;
    --list) list_scenarios; exit 0 ;;
    --scenario|--pod) [ $# -ge 2 ] || { echo "Option $1 needs a value (see --help)." >&2; exit 2; }
                      if [ "$1" = "--scenario" ]; then SCENARIO_ARG="$2"; else POD_ARG="$2"; fi
                      shift ;;
    --scenario=*) SCENARIO_ARG="${1#--scenario=}" ;;
    --pod=*) POD_ARG="${1#--pod=}" ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Invalid option: $1" >&2
        echo "Usage: $0 [--no-prompt] [--check-only] [--skip-check] [--list] [--scenario <ids>] [--pod <n>] [<cluster-name>]" >&2; exit 2 ;;
    *) CLUSTER_ARG="$1" ;;
  esac
  shift
done

if [ "$SKIP_CHECK" -eq 1 ] && [ "$CHECK_ONLY" -eq 1 ]; then
  echo "--skip-check and --check-only contradict each other: the check is all --check-only does." >&2; exit 2
fi

# selected scenarios, in canonical order
SELECTED=()
if [ -z "$SCENARIO_ARG" ]; then
  SELECTED=(pod node region)
else
  IFS=',' read -r -a _asked <<< "$SCENARIO_ARG"
  for _a in "${_asked[@]}"; do
    case ",$(valid_ids)," in
      *",$_a,"*) ;;
      *) echo "Unknown scenario: '$_a'. Valid ids: $(valid_ids)  (see --list)" >&2; exit 2 ;;
    esac
  done
  for id in "${SCENARIO_IDS[@]}"; do
    for _a in "${_asked[@]}"; do [ "$_a" = "$id" ] && { SELECTED+=("$id"); break; }; done
  done
fi
want() { local x; for x in "${SELECTED[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
# the health gate is skipped only when region-recover is the sole scenario
NEED_GATE=0
for _s in "${SELECTED[@]}"; do [ "$_s" != region-recover ] && NEED_GATE=1; done

re_load_config
re_cloud_select_account

region="$CLUSTER1"
if [ -n "$CLUSTER_ARG" ]; then
  if [[ "$CLUSTER_ARG" == "$CLUSTER1" || "$CLUSTER_ARG" == "$CLUSTER2" ]]; then
    region="$CLUSTER_ARG"
  else
    echo "Invalid cluster: $CLUSTER_ARG. Must be one of: $CLUSTER1, $CLUSTER2" >&2; exit 2
  fi
fi

re_log_init "chaos"

# The Redis Enterprise cluster (rec-a / rec-b) is NOT named after the cloud
# cluster (redis-<prefix>-<region>); its pods are <rec>-0..N.
if [[ "$region" == "$CLUSTER1" ]]; then
  REC="$REC_NAME1"; CLOUD_REGION="$REGION1"; OTHER="$CLUSTER2"; OTHER_REC="$REC_NAME2"
else
  REC="$REC_NAME2"; CLOUD_REGION="$REGION2"; OTHER="$CLUSTER1"; OTHER_REC="$REC_NAME1"
fi

# shellcheck source=../common/chaos-notify.sh
. "$REPO_ROOT/common/chaos-notify.sh"

# --pod accepts an index (0..RE_NODES-1) or the pod name of THIS target cluster.
if [ -n "$POD_ARG" ]; then
  case "$POD_ARG" in
    [0-9]|[0-9][0-9]) POD_ARG="$REC-$POD_ARG" ;;
  esac
  _idx="${POD_ARG#"$REC"-}"
  case "$POD_ARG" in
    "$REC"-[0-9]|"$REC"-[0-9][0-9]) [ "$_idx" -lt "$RE_NODES" ] || POD_ARG="!" ;;
    *) POD_ARG="!" ;;
  esac
  if [ "$POD_ARG" = "!" ]; then
    echo "Invalid --pod. Use an index 0..$((RE_NODES - 1)) or a pod name of the target cluster ($REC-0 .. $REC-$((RE_NODES - 1)))." >&2
    exit 2
  fi
fi

# Chaos plays one cluster against the other (witness): it cannot run on a single-cluster deployment.
if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx -- "$OTHER"; then
  echo "❌ no kubeconfig context '$OTHER': chaos needs BOTH clusters (Active-Active)." >&2
  echo "   A single-cluster deployment (gcp-deploy.sh --single) cannot run it." >&2
  echo "   If both are deployed, load the contexts:  providers/$CLOUD_PROVIDER/get-credentials.sh" >&2
  exit 2
fi

CHAOS_TIMEOUT="${CHAOS_TIMEOUT:-900}"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
export CHAOS_RUN_ID="$RUN_ID"   # read by chaos_notify
CUR_PHASE=""
PHASE_FAILED_BASE=0
RUN_STARTED=0
RUN_ENDED=0
FAILED=0
RES=()
RECOVERY_SECS=0

re_log "Target     : $region  (Redis Enterprise cluster: $REC, cloud region: $CLOUD_REGION)"
re_log "Witness    : $OTHER  ($OTHER_REC) — never touched"
re_log "Mode       : $([ "$INTERACTIVE" -eq 1 ] && echo interactive || echo 'unattended (--no-prompt)')   timeout/phase: ${CHAOS_TIMEOUT}s"
re_log "Scenarios  : ${SELECTED[*]}$([ "$NEED_GATE" -eq 0 ] && echo '   (health gate skipped: only region-recover)')$([ "$SKIP_CHECK" -eq 1 ] && echo '   (health gate skipped: --skip-check)')"

_git_rev=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null || _git_rev="$_git_rev+uncommitted"
re_log "Tooling    : git $_git_rev | $(kubectl version --client 2>/dev/null | head -1 || true) | $(gcloud --version 2>/dev/null | head -1 || true)"
re_log "Config     : NS=$NS DB=$AA_DB_NAME RE_NODES=$RE_NODES provider=$CLOUD_PROVIDER pool(count/min/max)=${GCP_NODE_COUNT:-n/a}/${GCP_NODE_MIN_COUNT:-n/a}/${GCP_NODE_MAX_COUNT:-n/a} CHAOS_*: $(env | grep '^CHAOS_' | grep -v RUN_ID | tr '\n' ' ')"
re_log "Events     : ${RE_LOG_FILE%.log}.events.jsonl   (machine-readable timeline of this run)"

# An interrupted run (Ctrl+C, kill, terminal closed) must still tell the console.
on_exit() {
  local rc="$1"
  if [ "$RUN_STARTED" -eq 1 ] && [ "$RUN_ENDED" -eq 0 ]; then
    chaos_notify run_end status=ABORTED note="chaos.sh stopped (exit $rc)"
  fi
  _re_log_footer "$rc"
}
trap 'on_exit $?' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# kubectl pinned to a cluster WITHOUT touching the global current-context.
kc()  { kubectl --context "$region" "$@"; }
koc() { kubectl --context "$OTHER" "$@"; }

say() { re_log "$@"; }

# ---- audit trail ------------------------------------------------------------------------------------
# Besides the human log, every event goes to <log>.events.jsonl: one JSON object per line with the
# wall clock (ts) and the seconds since the start of the run (t). chaos_notify (below) feeds it too,
# so the console and the file can never disagree.
RUN_T0=$SECONDS
EVENTS_FILE="${RE_LOG_FILE%.log}.events.jsonl"
ev() {
  local line kv key val
  line="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"t\":$((SECONDS - RUN_T0)),\"type\":\"$(_cn_json_escape "$1")\""
  shift
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$val" in
      ''|*[!0-9]*) line+=",\"$key\":\"$(_cn_json_escape "$val")\"" ;;
      *)           line+=",\"$key\":$val" ;;
    esac
  done
  printf '%s}\n' "$line" >> "$EVENTS_FILE" 2>/dev/null || true
}
chaos_notify_hook() { ev "$@"; }

# timed <label> <cmd...> — a cloud/cluster command with a timestamped start, end, exit code and duration.
timed() {
  local label="$1"; shift
  local t0=$SECONDS rc=0
  say "▶ $label"
  ev cmd_start name="$label"
  "$@" || rc=$?
  say "◀ $label rc=$rc in $((SECONDS - t0))s"
  ev cmd_end name="$label" rc="$rc" seconds="$((SECONDS - t0))"
  return "$rc"
}

# GCE instances of THIS cluster (GKE labels every node VM with its cluster; the VM NAME holds a
# truncated cluster name, so matching on the name finds nothing). "?" = gcloud could not answer.
gce_instance_count() {
  local out
  out=$(gcloud compute instances list --project "$GCP_PROJECT_ID" \
          --filter="labels.goog-k8s-cluster-name=$region" --format='value(name)' 2>/dev/null) || { echo '?'; return 0; }
  printf '%s\n' "$out" | grep -c . || true
}

# sample <label> — one line: what the target cluster looks like right now (log + events file).
sample() {
  local label="$1" nodes pods extra=""
  nodes=$(run_to 15 kubectl --context "$region" get nodes --no-headers 2>/dev/null | awk '{t++} $2 ~ /^Ready/ {r++} END {printf "%d/%d", r+0, t+0}' || true)
  pods=$(run_to 15 kubectl --context "$region" -n "$NS" get pods --no-headers 2>/dev/null | awk '{t++} $3=="Running" {r++} END {printf "%d/%d", r+0, t+0}' || true)
  if [ "$CLOUD_PROVIDER" = gcp ]; then extra="  gce_instances=$(gce_instance_count)"; fi
  say "   [sample:$label] t=+$((SECONDS - RUN_T0))s  k8s nodes Ready/total=$nodes  pods Running/total=$pods$extra"
  ev sample name="$label" nodes="$nodes" pods="$pods" note="$extra"
}

# ============================================================================
# Plumbing: bounded commands, log-only details, probes
# ============================================================================

# run_to <seconds> <cmd...> — run a command, kill it after <seconds> (macOS has
# no `timeout`). A kubectl exec to a pod on a rebooting node can hang for minutes.
run_to() {
  local secs="$1"; shift
  "$@" &
  local pid=$! rc=0
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid" 2>/dev/null || rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

# detail <title> <cmd...> — run a command and write its output to the LOG FILE
# ONLY (the console keeps the one-line summaries).
detail() {
  local title="$1"; shift
  {
    echo "[$(_re_ts)]   ┌── $title"
    run_to 40 "$@" 2>&1 | sed 's/^/                │ /' || true
    echo "[$(_re_ts)]   └──"
  } >> "$RE_LOG_FILE" 2>&1 || true
}

# rec_exec <context> <rec> <cmd...> — run a command in the first REC pod that
# answers. Order: -1, -2, -0, because -0 is the pod the pod test deletes.
rec_exec() {
  local ctx="$1" rec="$2"; shift 2
  local p out
  for p in "$rec-1" "$rec-2" "$rec-0"; do
    if out=$(run_to 40 kubectl --context "$ctx" -n "$NS" exec "$p" -c redis-enterprise-node -- "$@" 2>&1); then
      printf '%s\n' "$out"
      return 0
    fi
  done
  return 1
}

# rec_health_line <context> <rec> <need_db 0|1> — prints one line, returns 0
# when every one of RE_NODES nodes is OK (and, if need_db=1, every DB is active).
rec_health_line() {
  local ctx="$1" rec="$2" need_db="$3" nodes dbs n_ok n_tot d_ok d_tot
  nodes=$(rec_exec "$ctx" "$rec" rladmin status nodes) || { echo "rladmin unreachable"; return 1; }
  n_tot=$(printf '%s\n' "$nodes" | grep -cE '^\*?node:[0-9]+' || true)
  n_ok=$(printf '%s\n' "$nodes" | awk '/^\*?node:[0-9]+/ && $NF=="OK"' | wc -l | tr -d ' ')
  dbs=$(rec_exec "$ctx" "$rec" rladmin status databases) || dbs=""
  d_tot=$(printf '%s\n' "$dbs" | grep -cE '^db:[0-9]+' || true)
  d_ok=$(printf '%s\n' "$dbs" | awk '/^db:[0-9]+/ && $4=="active"' | wc -l | tr -d ' ')
  echo "RE nodes OK $n_ok/$n_tot (expected $RE_NODES), databases active $d_ok/$d_tot"
  [ "$n_ok" -ge "$RE_NODES" ] || return 1
  if [ "$need_db" -eq 1 ]; then
    [ "$d_tot" -ge 1 ] && [ "$d_ok" -eq "$d_tot" ] || return 1
  fi
  return 0
}

# Kubernetes-level view of the target cluster: "<pods> <pods-not-Running> <nodes> <nodes-not-Ready>"
k8s_counts() {
  local pods bad nodes notready
  pods=$(kc get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  bad=$(kc get pods -n "$NS" --no-headers 2>/dev/null | awk '$3!="Running"' | wc -l | tr -d ' ')
  nodes=$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  notready=$(kc get nodes --no-headers 2>/dev/null | awk '$2!~/^Ready/' | wc -l | tr -d ' ')
  echo "$pods $bad $nodes $notready"
}

# snapshot <label> — kubectl + rladmin state of both clusters, into the log.
snapshot() {
  local label="$1"
  say "📸 snapshot [$label] -> log"
  detail "[$label] $region nodes"            kc get nodes -o wide
  detail "[$label] $region pods"             kc get pods -n "$NS" -o wide
  detail "[$label] $region rec/rerc/reaadb"  kc get rec,rerc,reaadb -n "$NS"
  detail "[$label] $region events"           kc get events -n "$NS" --sort-by=.lastTimestamp
  detail "[$label] $region reaadb status"    kc get reaadb "$AA_DB_NAME" -n "$NS" -o jsonpath='{.status}'
  detail "[$label] $region operator log (last 60 lines)" kc logs -n "$NS" deploy/redis-enterprise-operator --all-containers --tail=60
  detail "[$label] $REC rladmin status"      rec_exec "$region" "$REC" rladmin status
  detail "[$label] $REC crdb-cli crdb list"  rec_exec "$region" "$REC" crdb-cli crdb list
  detail "[$label] $OTHER pods"              koc get pods -n "$NS" -o wide
  detail "[$label] $OTHER reaadb status"     koc get reaadb "$AA_DB_NAME" -n "$NS" -o jsonpath='{.status}'
  detail "[$label] $OTHER operator log (last 60 lines)" koc logs -n "$NS" deploy/redis-enterprise-operator --all-containers --tail=60
  detail "[$label] $OTHER_REC rladmin status" rec_exec "$OTHER" "$OTHER_REC" rladmin status
  detail "[$label] $OTHER_REC crdb-cli crdb list" rec_exec "$OTHER" "$OTHER_REC" crdb-cli crdb list
  provider_snapshot "$label"
  ev snapshot name="$label"
}

# wait_degraded <label> [max-seconds] — the injection must be OBSERVED before we
# start waiting for recovery. After a node reset the node still looks Ready for
# ~40 s; without this step the recovery wait would pass instantly and lie.
wait_degraded() {
  local label="$1" max="${CHAOS_DEGRADE_WAIT:-${2:-150}}" start=$SECONDS c
  while [ $((SECONDS - start)) -lt "$max" ]; do
    c=$(k8s_counts)
    # shellcheck disable=SC2086
    set -- $c
    if [ "$1" -ne "$expected_pod_count" ] || [ "$2" -ne 0 ] || [ "$4" -ne 0 ] \
       || ! rec_health_line "$region" "$REC" 1 >/dev/null; then
      say "   [$label] degradation observed after $((SECONDS - start))s"
      return 0
    fi
    sleep 3
  done
  say "⚠️  [$label] no degradation observed within ${max}s (the failure may not have taken effect)"
  return 1
}

# wait_recovered <label> <need_db 0|1> [timeout] [base] — pods Running, nodes Ready,
# RE nodes OK (and databases active if need_db=1). Sets RECOVERY_SECS: seconds since `base`
# (a $SECONDS value; pod/node pass the injection time so it matches the console's timer),
# default = since this function started.
wait_recovered() {
  local label="$1" need_db="$2" tmo="${3:-$CHAOS_TIMEOUT}" base="${4:-}"
  local start=$SECONDS last=-30 c line="" ok
  [ -n "$base" ] || base=$start
  say "⏳ [$label] waiting for $expected_pod_count pods Running, >=$expected_node_count nodes Ready, Redis healthy (timeout ${tmo}s)"
  while :; do
    c=$(k8s_counts)
    # shellcheck disable=SC2086
    set -- $c
    ok=0
    if [ "$1" -eq "$expected_pod_count" ] && [ "$2" -eq 0 ] && [ "$3" -ge "$expected_node_count" ] && [ "$4" -eq 0 ]; then
      if line=$(rec_health_line "$region" "$REC" "$need_db"); then ok=1; fi
    else
      line="pods $1/$expected_pod_count (not Running: $2), nodes $3/$expected_node_count (not Ready: $4)"
    fi
    if [ "$ok" -eq 1 ]; then
      RECOVERY_SECS=$((SECONDS - base))
      say "✅ [$label] recovered in ${RECOVERY_SECS}s — $line"
      return 0
    fi
    if [ $((SECONDS - last)) -ge 30 ]; then
      say "   … [$label] $((SECONDS - start))s: $line"
      say "     witness $OTHER_REC: $(rec_health_line "$OTHER" "$OTHER_REC" 1 2>&1 | tail -1 || true)"
      ev progress name="$label" note="$line"
      last=$SECONDS
    fi
    if [ $((SECONDS - start)) -ge "$tmo" ]; then
      RECOVERY_SECS=$((SECONDS - base))
      say "❌ [$label] NOT recovered after ${tmo}s — last state: $line"
      snapshot "$label-timeout"
      return 1
    fi
    sleep 5
  done
}

# ---- data path ----------------------------------------------------------------
db_svc_port() { kubectl --context "$1" -n "$NS" get svc "$AA_DB_NAME" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null; }

# db_cli <context> <rec> <redis-cli args...> — redis-cli INSIDE a REC pod, against
# the database service (TLS, no client cert). The password is never logged.
db_cli() {
  local ctx="$1" rec="$2"; shift 2
  local pw port
  pw=$(re_aa_db_password "$ctx" 2>/dev/null) || pw=""
  port=$(db_svc_port "$ctx")
  [ -n "$port" ] || return 1
  rec_exec "$ctx" "$rec" redis-cli --tls --insecure -h "$AA_DB_NAME" -p "$port" \
    ${pw:+-a "$pw"} --no-auth-warning "$@"
}

# data_check <label> <context:rec>... — SET on the first reachable one, then GET
# on every one (up to 60 s, replication is asynchronous). 0 = all reads match.
data_check() {
  local label="$1"; shift
  local key="chaos:$RUN_ID:$label" val pair ctx rec out written=0 all_ok=1 t0 got
  val="$label@$(date +%s)"

  for pair in "$@"; do
    ctx="${pair%%:*}"; rec="${pair##*:}"
    if out=$(db_cli "$ctx" "$rec" SET "$key" "$val") && [ "$out" = "OK" ]; then
      say "   [$label] SET $key on $ctx -> OK"
      written=1
      break
    fi
    say "   [$label] SET on $ctx failed (${out:-no answer}); trying the next one"
  done
  [ "$written" -eq 1 ] || { say "❌ [$label] could not write anywhere"; return 1; }

  for pair in "$@"; do
    ctx="${pair%%:*}"; rec="${pair##*:}"
    t0=$SECONDS; got=""
    while [ $((SECONDS - t0)) -lt 60 ]; do
      got=$(db_cli "$ctx" "$rec" GET "$key" 2>/dev/null || true)
      [ "$got" = "$val" ] && break
      sleep 3
    done
    if [ "$got" = "$val" ]; then
      say "   [$label] GET on $ctx -> match (after $((SECONDS - t0))s)"
    else
      say "   [$label] GET on $ctx -> '${got:-<no answer>}' (expected '$val')"
      all_ok=0
    fi
  done
  [ "$all_ok" -eq 1 ]
}

# ---- bookkeeping ----------------------------------------------------------------
# record <name> <PASS|FAIL> <seconds> <note>
record() {
  RES+=("$1|$2|$3|$4")
  if [ "$2" = "FAIL" ]; then FAILED=$((FAILED + 1)); fi
  chaos_notify step phase="$CUR_PHASE" name="$1" status="$2" seconds="$3" note="$4"
  return 0
}

# begin_phase <id> — console shows the scenario as "ready" BEFORE any prompt;
# end_phase closes it. announce_action <text> is a step shown in the timeline.
begin_phase() {
  CUR_PHASE="$1"
  PHASE_FAILED_BASE="$FAILED"
  chaos_notify phase_start phase="$1"
}
end_phase() {
  chaos_notify phase_end phase="$CUR_PHASE" status="$([ "$FAILED" -gt "$PHASE_FAILED_BASE" ] && echo FAIL || echo PASS)"
}
inject_action() {
  INJECT_T0=$SECONDS      # recovery of pod/node is measured from here, like the console's timer
  chaos_notify inject phase="$CUR_PHASE" note="$1"
}
announce_action() { chaos_notify step phase="$CUR_PHASE" name=action status=INFO note="$1"; }

print_summary() {
  local r name status secs note
  say ""
  say "═══════════════════════════ CHAOS SUMMARY ($region) ═══════════════════════════"
  for r in ${RES[@]+"${RES[@]}"}; do
    IFS='|' read -r name status secs note <<< "$r"
    say "$(printf '   %-4s %-26s %5ss  %s' "$status" "$name" "$secs" "$note")"
  done
  say "════════════════════════════════════════════════════════════════════════════"
  if [ "$FAILED" -eq 0 ]; then say "✅ all checks passed"; else say "❌ $FAILED check(s) failed — see $RE_LOG_FILE"; fi
}

# Pause (interactive) or just announce (unattended).
wait_for_user() {
  local nextAction="$1"
  say ""
  say "→ $nextAction"
  if [ "$INTERACTIVE" -eq 1 ]; then
    local t0=$SECONDS
    echo "   Press Enter to continue..."
    read -rp ""
    say "   (presenter continued after $((SECONDS - t0))s)"
    ev prompt name="$nextAction" waited="$((SECONDS - t0))"
  else
    say "   (--no-prompt: continuing without waiting)"
    ev prompt name="$nextAction" waited=0
  fi
}

# ----------------------------------------------------------------------------
# Which pod do we break? One line per Redis Enterprise node: "<pod> <role> <shards> <endpoint 0|1>"
# ----------------------------------------------------------------------------
topology() {
  local out
  out=$(rec_exec "$region" "$REC" rladmin status) || return 1
  printf '%s\n' "$out" | awk '
    /^[*]?node:[0-9]+/ { id=$1; sub(/^[*]/,"",id); sub(/^node:/,"",id); host[id]=$5; role[id]=$2; split($6,a,"/"); sh[id]=a[1] }
    /^ENDPOINTS:/ { ep=1; next }
    /^SHARDS:/ { ep=0 }
    ep && $4 ~ /^node:/ { n=$4; sub(/^node:/,"",n); endp[n]=1 }
    END { for (i in host) printf "%s %s %s %d\n", host[i], role[i], sh[i], (i in endp) }'
}

# Sets VICTIM (pod name) and VICTIM_INFO (human description).
pick_victim_pod() {
  local topo line
  topo=$(topology 2>/dev/null) || topo=""
  if [ -n "$POD_ARG" ]; then
    VICTIM="$POD_ARG"
    VICTIM_WHY="forced with --pod"
  else
    # Eligible = not the cluster primary (we would lose the cluster API) and not the endpoint holder
    # (we would lose the region's endpoint). Whether the pod holds the primary or the replica shard
    # does not matter: both show resilience. Preferred: RE node 2 (pod index 1), the demo's usual
    # target; else an eligible pod holding a shard (most shards first, lowest index).
    local preferred="$REC-1"
    if printf '%s\n' "$topo" | awk -v p="$preferred" '$1==p && $2=="slave" && $4==0 {f=1} END {exit !f}'; then
      VICTIM="$preferred"
      VICTIM_WHY="chosen automatically: RE node 2 (never the cluster primary, never the endpoint holder)"
    else
      VICTIM=$(printf '%s\n' "$topo" | awk '$2=="slave" && $4==0 && $3>0 {print $3, $1}' | sort -k1,1nr -k2,2 | head -1 | awk '{print $2}')
      VICTIM_WHY="chosen automatically: RE node 2 is the primary or holds the endpoint, so another replica with a shard"
    fi
    if [ -z "$VICTIM" ]; then
      VICTIM=$(printf '%s\n' "$topo" | awk '$2=="slave" {print $3, $1}' | sort -k1,1nr -k2,2 | head -1 | awk '{print $2}')
      VICTIM_WHY="no replica free of the endpoint: any replica"
    fi
    if [ -z "$VICTIM" ]; then
      VICTIM="$REC-$((RE_NODES - 1))"
      VICTIM_WHY="rladmin topology unavailable: last pod by default"
    fi
  fi
  line=$(printf '%s\n' "$topo" | awk -v p="$VICTIM" '$1==p {printf "%s, %s shard(s)%s", $2, $3, ($4==1 ? ", holds the database endpoint" : "")}')
  case "$line" in master*) line="cluster primary${line#master}" ;; slave*) line="replica${line#slave}" ;; esac
  VICTIM_INFO="$VICTIM${line:+ ($line)}"
  say "🎯 victim: $VICTIM_INFO — $VICTIM_WHY"
}

# ============================================================================
# Provider primitives
# ============================================================================
provider_prepare() {
  case "$CLOUD_PROVIDER" in
    azure)
      echo "Fetching VMSS info..."
      local cluster
      cluster=$(az vmss list -o table | grep -i "$region" || true)
      if [[ -z "$cluster" ]]; then
        echo "No VMSS found for region '$region'. Check if the name matches."
        exit 1
      fi
      rg=$(echo "$cluster" | awk '{print $2}')
      vmss=$(echo "$cluster" | awk '{print $1}')
      ;;
    gcp)
      command -v gcloud >/dev/null 2>&1 || { echo "gcloud not found"; exit 1; }
      GKE_POOL="${region}-nodes"
      ;;
    *)
      echo "chaos.sh does not support CLOUD_PROVIDER=$CLOUD_PROVIDER yet (docs/TODO.md A6)."
      exit 1
      ;;
  esac
}

# Cloud-side state worth keeping next to the Kubernetes snapshots (log only).
provider_snapshot() {
  case "$CLOUD_PROVIDER" in
    gcp)
      detail "[$1] GKE operations on $region (last 5)" gcloud container operations list --project "$GCP_PROJECT_ID" \
        --region "$CLOUD_REGION" --filter="targetLink~$region AND startTime>\"$(date -u -v-3H +%Y-%m-%dT%H:%M 2>/dev/null || date -u -d '3 hours ago' +%Y-%m-%dT%H:%M)\"" --sort-by=startTime \
        --format='table(name,operationType,status,startTime,endTime)'
      detail "[$1] node pool $GKE_POOL (autoscaling, status, locations)" gcloud container node-pools describe "$GKE_POOL" \
        --cluster "$region" --region "$CLOUD_REGION" --project "$GCP_PROJECT_ID" \
        --format='yaml(autoscaling,initialNodeCount,locations,status,statusMessage,conditions,management,upgradeSettings)'
      detail "[$1] cluster-autoscaler status ($region)" kc get cm cluster-autoscaler-status -n kube-system -o jsonpath='{.data.status}'
      detail "[$1] GCE instances of $region" gcloud compute instances list --project "$GCP_PROJECT_ID" \
        --filter="labels.goog-k8s-cluster-name=$region" --format='table(name,zone.basename(),status,creationTimestamp)'
      ;;
  esac
}

# Describe what provider_restart_node will do (shown before the phase).
provider_restart_description() {
  case "$CLOUD_PROVIDER" in
    azure) echo "Restart a virtual machine scale set (underlying infrastructure for a Redis Enterprise Node) VMSS='$vmss', RG='$rg', instance-ids='$first_instance_id'" ;;
    gcp)   echo "Hard-reset one GCE instance (underlying infrastructure for a Redis Enterprise node): $gce_instance in zone $gce_zone" ;;
  esac
}

provider_pick_node() {
  case "$CLOUD_PROVIDER" in
    azure)
      first_instance_id=$(az vmss list-instances --name "$vmss" --resource-group "$rg" --query "[0].instanceId" -o tsv)
      #Instance ID is not always 1, if you execute this script twice, it will be 3,4,5 instead of 0,1,2
      ;;
    gcp)
      # the VM hosting the pod chosen for this run (so the node scenario hits the same replica)
      gce_instance=""
      [ -z "${VICTIM:-}" ] || gce_instance=$(kc get pod "$VICTIM" -n "$NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
      [ -n "$gce_instance" ] || gce_instance=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
      gce_zone=$(kc get node "$gce_instance" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
      [[ -n "$gce_instance" && -n "$gce_zone" ]] || { echo "could not pick a node/zone in $region"; exit 1; }
      ;;
  esac
}

# What provider_region_down is about to do, for the console and the prompt.
provider_region_down_description() {
  case "$CLOUD_PROVIDER" in
    azure) echo "az aks stop: the whole AKS cluster $region is stopped" ;;
    gcp)   echo "Node pool of $region: autoscaling off, resized to 0, Redis Enterprise pods force-deleted" ;;
  esac
}

provider_restart_node() {
  echo "Restarting a single cluster node in region='$region'"
  case "$CLOUD_PROVIDER" in
    azure)
      echo "az vmss restart --name \"$vmss\" --resource-group \"$rg\" --instance-ids \"$first_instance_id\""
      az vmss restart --name "$vmss" --resource-group "$rg" --instance-ids "$first_instance_id"
      ;;
    gcp)
      echo "gcloud compute instances reset $gce_instance --zone $gce_zone --project $GCP_PROJECT_ID"
      timed "gcloud: reset VM $gce_instance" gcloud compute instances reset "$gce_instance" --zone "$gce_zone" --project "$GCP_PROJECT_ID" --quiet
      ;;
  esac
}

provider_region_down() {
  case "$CLOUD_PROVIDER" in
    azure)
      echo "Stopping AKS cluster in $region"
      az aks stop --name "$region" --resource-group "$CLUSTER_RESOURCE_GROUP"

      echo "Waiting for AKS cluster '$region' to fully stop..."
      while true; do
        state=$(az aks show --name "$region" --resource-group "$CLUSTER_RESOURCE_GROUP" --query "powerState.code" -o tsv 2>/dev/null || echo "Unavailable")
        echo "Current powerState: '$state'"
        if [[ "$state" == "Stopped" ]]; then
          echo "Cluster $region is stopped."
          break
        fi
        echo -n "."
        sleep 5
      done
      ;;
    gcp)
      # GKE has no "stop". Emulate a region outage by removing every node:
      # autoscaling must go first or it would bring nodes straight back.
      echo "If this script is interrupted while the pool is at 0, restore it with:"
      echo "  gcloud container clusters resize $region --node-pool $GKE_POOL --num-nodes $GCP_NODE_COUNT --region $CLOUD_REGION --project $GCP_PROJECT_ID --quiet"
      echo "Disabling autoscaling on pool $GKE_POOL, then resizing it to 0 nodes"
      local pre
      pre=$(gce_instance_count)
      echo "GCE instances of $region before the outage: $pre"
      sample "region-before-outage"
      timed "gcloud: node pool autoscaling off" gcloud container node-pools update "$GKE_POOL" --cluster "$region" \
        --region "$CLOUD_REGION" --project "$GCP_PROJECT_ID" --no-enable-autoscaling --quiet
      # 2026-11-27: with autoscaling reported OFF, pods left Pending by the drain still triggered
      # TriggeredScaleUp and the pool grew back (nodes REPLACED, never absent). Hypothesis: the
      # cluster autoscaler keeps its old node-group config for a while. So: check what the API says
      # now, and give the autoscaler time to notice before the resize (CHAOS_AUTOSCALER_SETTLE, s).
      local asv
      asv=$(run_to 30 gcloud container node-pools describe "$GKE_POOL" --cluster "$region" \
        --region "$CLOUD_REGION" --project "$GCP_PROJECT_ID" --format='value(autoscaling.enabled)' 2>&1 | tr '\n' ' ') || true
      echo "autoscaling.enabled according to the API: ${asv:-<empty = off>}"
      echo "Letting the cluster autoscaler notice for ${CHAOS_AUTOSCALER_SETTLE:-60}s before the resize"
      sleep "${CHAOS_AUTOSCALER_SETTLE:-60}"
      # --async: the resize waits for every node to drain, and a REC pod can sit in
      # Terminating for its whole terminationGracePeriodSeconds (observed 2026-11-26:
      # the operation stayed RUNNING for over an hour). A region outage is abrupt
      # anyway, so the REC pods are force-deleted instead of waiting for them.
      timed "gcloud: resize pool to 0 (async)" gcloud container clusters resize "$region" --node-pool "$GKE_POOL" --num-nodes 0 \
        --region "$CLOUD_REGION" --project "$GCP_PROJECT_ID" --quiet --async
      local i
      for i in $(seq 0 $((RE_NODES - 1))); do
        timed "kubectl: force-delete pod $REC-$i" kc -n "$NS" delete pod "$REC-$i" --force --grace-period=0 --ignore-not-found >/dev/null 2>&1 || true
      done

      echo "Waiting for every GCE instance of '$region' to disappear (timeout ${CHAOS_TIMEOUT}s)..."
      local t0=$SECONDS n
      if ! [[ "$pre" =~ ^[1-9][0-9]*$ ]]; then
        echo "⚠️  could not count the GCE instances before the outage ('$pre'): not waiting on them; the Kubernetes node count decides (verified next)"
      else
        while :; do
          n=$(gce_instance_count)
          [ "$n" = 0 ] && break
          if [ $((SECONDS - t0)) -ge "$CHAOS_TIMEOUT" ]; then
            echo "Timeout: $n GCE instance(s) of $region are still there after ${CHAOS_TIMEOUT}s"
            return 1
          fi
          sample "region-down-wait"
          sleep 10
        done
      fi
      # The async resize must be DONE before provider_region_up starts another
      # operation on the pool (GKE refuses concurrent operations).
      while [[ -n "$(gcloud container operations list --project "$GCP_PROJECT_ID" --region "$CLOUD_REGION" \
                       --filter="status=RUNNING AND targetLink~${region}" --format='value(name)' 2>/dev/null)" ]]; do
        if [ $((SECONDS - t0)) -ge "$CHAOS_TIMEOUT" ]; then
          echo "Timeout: a GKE operation on $region is still RUNNING"
          return 1
        fi
        sleep 5
      done
      sample "region-down-done"
      echo "GCE instances of $region are gone and the pool operation is finished (verified against Kubernetes next)."
      ;;
  esac
}

provider_region_up() {
  case "$CLOUD_PROVIDER" in
    azure)
      echo "Restarting AKS cluster in region:'$region', resource-groupe:'$CLUSTER_RESOURCE_GROUP' "
      az aks start --name "$region" --resource-group "$CLUSTER_RESOURCE_GROUP"

      echo "Waiting for AKS cluster '$region' to fully Running..."
      while true; do
        state=$(az aks show --name "$region" --resource-group "$CLUSTER_RESOURCE_GROUP" --query "powerState.code" -o tsv 2>/dev/null || echo "Unavailable")
        echo "Current powerState: '$state'"
        if [[ "$state" == "Running" ]]; then
          echo "Cluster $region is running."
          break
        fi
        sleep 5
      done
      ;;
    gcp)
      # Same values Terraform applied (config.sh), so there is no drift to undo.
      echo "Resizing pool $GKE_POOL back to $GCP_NODE_COUNT node(s) per zone, then re-enabling autoscaling"
      timed "gcloud: resize pool back to $GCP_NODE_COUNT per zone" gcloud container clusters resize "$region" --node-pool "$GKE_POOL" --num-nodes "$GCP_NODE_COUNT" \
        --region "$CLOUD_REGION" --project "$GCP_PROJECT_ID" --quiet
      timed "gcloud: autoscaling back on" gcloud container node-pools update "$GKE_POOL" --cluster "$region" \
        --region "$CLOUD_REGION" --project "$GCP_PROJECT_ID" --enable-autoscaling \
        --min-nodes "$GCP_NODE_MIN_COUNT" --max-nodes "$GCP_NODE_MAX_COUNT" --quiet

      local tn="${CHAOS_NODES_TIMEOUT:-$CHAOS_TIMEOUT}" tn0=$SECONDS
      echo "Waiting for the nodes to be Ready again (timeout ${tn}s)..."
      until [[ "$(kc get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)" -ge "$expected_node_count" ]]; do
        if [ $((SECONDS - tn0)) -ge "$tn" ]; then
          sample "region-up-timeout"
          echo "Timeout: fewer than $expected_node_count nodes Ready in $region after ${tn}s (zone stock-out, quota, or a GKE operation still running?)"
          return 1
        fi
        sample "region-up-wait"
        sleep 10
      done
      sample "region-up-done"
      ;;
  esac
}

# ============================================================================
# Phases
# ============================================================================
# ----------------------------------------------------------------------------
# Health gate — runs BEFORE any failure is injected, on BOTH clusters.
# Injecting chaos into a half-broken setup makes the outcome unpredictable, which
# is exactly what a demo cannot afford. Any failed check stops the run (exit 3)
# and says what is wrong and where to look. --check-only runs just this gate.
# ----------------------------------------------------------------------------
HC_FAILS=()
hc_ok()   { say "   ✅ $1 — $2"; }
hc_fail() {
  say "   ❌ $1 — $2"
  [ -z "${3:-}" ] || say "      ↳ $3"
  chaos_notify step phase=health name="health-check" status=FAIL note="$1 — $2"
  HC_FAILS+=("$1 — $2")
  return 0
}

# Can the cloud CLI get a token right now? A lapsed login ("Reauthentication required") makes every
# gcloud/az call fail with an error that does not say so, so it is checked first and by name.
cloud_auth_ok() {
  case "$CLOUD_PROVIDER" in
    gcp)   run_to 30 gcloud auth print-access-token >/dev/null 2>&1 ;;
    azure) run_to 30 az account get-access-token >/dev/null 2>&1 ;;
    *)     return 0 ;;
  esac
}
cloud_auth_hint() {
  case "$CLOUD_PROVIDER" in
    gcp)   echo "gcloud auth login${GCP_ACCOUNT:+ $GCP_ACCOUNT}" ;;
    azure) echo "az login" ;;
  esac
}
# require_cloud_auth — before any step that calls the cloud: refuse to start it half-way.
require_cloud_auth() {
  cloud_auth_ok && return 0
  say "❌ cloud authentication — not logged in (or the login expired). Nothing was injected."
  say "   ↳ $(cloud_auth_hint)"
  record "cloud-auth" FAIL 0 "not authenticated: run $(cloud_auth_hint)"
  return 1
}

# provider_health_cluster <context> <rec> <cloud-region> — the cloud's own view.
provider_health_cluster() {
  local ctx="$1" rec="$2" cregion="$3" out
  case "$CLOUD_PROVIDER" in
    gcp)
      out=$(run_to 40 gcloud container node-pools describe "$ctx-nodes" --cluster "$ctx" \
              --region "$cregion" --project "$GCP_PROJECT_ID" \
              --format='value(status,autoscaling.enabled)' 2>&1) || {
        hc_fail "[$rec] node pool" "cannot describe pool $ctx-nodes (${out:0:100})" \
          "gcloud container node-pools list --cluster $ctx --region $cregion --project $GCP_PROJECT_ID"
        return 0
      }
      case "$out" in
        RUNNING*True*|RUNNING*true*) hc_ok "[$rec] node pool" "$ctx-nodes RUNNING, autoscaling on" ;;
        RUNNING*) hc_fail "[$rec] node pool" "RUNNING but autoscaling is OFF (a previous chaos run left it so?)" \
                    "gcloud container node-pools update $ctx-nodes --cluster $ctx --region $cregion --project $GCP_PROJECT_ID --enable-autoscaling --min-nodes $GCP_NODE_MIN_COUNT --max-nodes $GCP_NODE_MAX_COUNT" ;;
        *) hc_fail "[$rec] node pool" "status is '${out%%[[:space:]]*}' (expected RUNNING): a GKE operation is probably still in progress" \
             "gcloud container operations list --region $cregion --project $GCP_PROJECT_ID --filter='status=RUNNING'" ;;
      esac
      ;;
    azure)
      out=$(run_to 40 az aks show --name "$ctx" --resource-group "$CLUSTER_RESOURCE_GROUP" \
              --query powerState.code -o tsv 2>&1) || out="unknown"
      if [ "$out" = "Running" ]; then hc_ok "[$rec] AKS power state" "Running"
      else hc_fail "[$rec] AKS power state" "'$out' (expected Running)" "az aks start --name $ctx --resource-group $CLUSTER_RESOURCE_GROUP"; fi
      ;;
  esac
}

# health_cluster <context> <rec> <cloud-region> — Kubernetes + Redis Enterprise state.
health_cluster() {
  local ctx="$1" rec="$2" cregion="$3" out tot bad n state line
  say "🩺 $rec  (context $ctx)"

  if ! out=$(run_to 30 kubectl --context "$ctx" get ns "$NS" -o name 2>&1); then
    hc_fail "[$rec] Kubernetes API" "unreachable or namespace '$NS' missing (${out:0:100})" \
      "is the cluster deployed? ./${DEPLOY_CLOUD:-$CLOUD_PROVIDER}-deploy.sh ; kubeconfig: providers/$CLOUD_PROVIDER/get-credentials.sh"
    return 0   # nothing else can be checked on this cluster
  fi
  hc_ok "[$rec] Kubernetes API" "reachable, namespace $NS present"

  provider_health_cluster "$ctx" "$rec" "$cregion"

  # --- nodes
  out=$(run_to 30 kubectl --context "$ctx" get nodes --no-headers 2>/dev/null) || out=""
  tot=$(printf '%s\n' "$out" | grep -c . || true)
  bad=$(printf '%s\n' "$out" | awk 'NF && $2!="Ready"{printf "%s(%s) ",$1,$2}')
  if [ "$tot" -lt "$RE_NODES" ]; then
    hc_fail "[$rec] nodes" "$tot node(s), $RE_NODES needed (one per Redis Enterprise pod)" \
      "nodes are being replaced or the pool was resized: kubectl --context $ctx get nodes"
  elif [ -n "$bad" ]; then
    hc_fail "[$rec] nodes" "not Ready/cordoned: $bad" \
      "wait for GKE/AKS to finish, or: kubectl --context $ctx uncordon <node>"
  else
    hc_ok "[$rec] nodes" "$tot Ready"
  fi

  # --- pods
  out=$(run_to 30 kubectl --context "$ctx" -n "$NS" get pods --no-headers 2>/dev/null) || out=""
  n=$(printf '%s\n' "$out" | grep -c "^$rec-[0-9]" || true)
  bad=$(printf '%s\n' "$out" | awk 'NF{split($2,r,"/"); if ($3!="Running" || r[1]!=r[2]) printf "%s(%s %s) ",$1,$2,$3}')
  if [ "$n" -ne "$RE_NODES" ]; then
    hc_fail "[$rec] REC pods" "$n pod(s) named $rec-N, expected $RE_NODES" \
      "kubectl --context $ctx -n $NS get pods -o wide"
  elif [ -n "$bad" ]; then
    hc_fail "[$rec] pods" "not Running/Ready: $bad" \
      "kubectl --context $ctx -n $NS describe pod <pod> ; a Pending pod usually means a node is missing"
  else
    hc_ok "[$rec] pods" "all $(printf '%s\n' "$out" | grep -c . || true) Running and Ready (REC $n/$RE_NODES + operator)"
  fi

  # --- REC object
  state=$(run_to 30 kubectl --context "$ctx" -n "$NS" get rec "$rec" -o jsonpath='{.status.state}' 2>/dev/null || true)
  if [ "$state" = "Running" ]; then hc_ok "[$rec] REC object" "state Running"
  else hc_fail "[$rec] REC object" "state '${state:-<absent>}' (expected Running)" "kubectl --context $ctx -n $NS describe rec $rec"; fi

  # --- Redis Enterprise itself
  if line=$(rec_health_line "$ctx" "$rec" 1); then
    hc_ok "[$rec] rladmin" "$line"
  else
    hc_fail "[$rec] rladmin" "$line" "./scripts/rladmin.sh <1|2> status   ;   in a pod: supervisorctl status"
  fi

  # --- Active-Active objects
  out=$(run_to 30 kubectl --context "$ctx" -n "$NS" get rerc --no-headers 2>/dev/null) || out=""
  n=$(printf '%s\n' "$out" | grep -c . || true)
  bad=$(printf '%s\n' "$out" | awk 'NF && $2!="Active"{printf "%s(%s) ",$1,$2}')
  if [ "$n" -lt 2 ]; then
    hc_fail "[$rec] RERC" "$n remote-cluster object(s), 2 expected (local + remote)" "kubectl --context $ctx -n $NS get rerc ; step 03 may not have run"
  elif [ -n "$bad" ]; then
    hc_fail "[$rec] RERC" "not Active: $bad" "kubectl --context $ctx -n $NS describe rerc <name>"
  else
    hc_ok "[$rec] RERC" "$n Active"
  fi

  line=$(run_to 30 kubectl --context "$ctx" -n "$NS" get reaadb "$AA_DB_NAME" \
           -o jsonpath='{.status.status}/{.status.replicationStatus}' 2>/dev/null || true)
  # The database must be `active`. The operator's own `replicationStatus` is advisory: it was seen
  # stuck at `down` after pod kills while every node was OK and writes replicated (2026-11-26), so a
  # `down` there is a warning; the real write/read through both regions (data path) stays the hard check.
  case "$line" in
    active/up) hc_ok "[$rec] REAADB $AA_DB_NAME" "active, replication up" ;;
    active/*)  say "   ⚠️  [$rec] REAADB $AA_DB_NAME — active, but the operator reports replication '${line#active/}' (advisory: the data path below decides)"
               say "      ↳ kubectl --context $ctx -n $NS describe reaadb $AA_DB_NAME" ;;
    *)         hc_fail "[$rec] REAADB $AA_DB_NAME" "status/replication = '${line:-<absent>}' (expected active)" \
                 "kubectl --context $ctx -n $NS describe reaadb $AA_DB_NAME ; step 04 may not have run" ;;
  esac
}

preflight_health() {
  say ""
  say "━━━ 0. HEALTH CHECK — both clusters must be healthy before any failure is injected ━━━"
  begin_phase health
  HC_FAILS=()
  if cloud_auth_ok; then
    hc_ok "cloud authentication" "$CLOUD_PROVIDER CLI can get a token${GCP_ACCOUNT:+ ($GCP_ACCOUNT)}"
    health_cluster "$CLUSTER1" "$REC_NAME1" "$REGION1"
    health_cluster "$CLUSTER2" "$REC_NAME2" "$REGION2"
  else
    hc_fail "cloud authentication" "not logged in, or the login expired ($CLOUD_PROVIDER CLI cannot get a token)" \
      "run: $(cloud_auth_hint)   — then re-run this script"
  fi

  if [ "${#HC_FAILS[@]}" -eq 0 ]; then
    say "🩺 data path (write on one region, read on both)"
    if data_check "health" "$CLUSTER1:$REC_NAME1" "$CLUSTER2:$REC_NAME2"; then
      hc_ok "data path" "write/read through both regions"
    else
      hc_fail "data path" "write or replication failed between $REC_NAME1 and $REC_NAME2" \
        "details above; check ./scripts/rladmin.sh 1 status ; crdb-cli crdb list ; redis-cli inside a pod"
    fi
  fi

  if [ "${#HC_FAILS[@]}" -gt 0 ]; then
    say ""
    say "❌ HEALTH CHECK FAILED — ${#HC_FAILS[@]} problem(s). Chaos NOT started: the result would be unpredictable."
    local f
    for f in "${HC_FAILS[@]}"; do say "   • $f"; done
    say "   Fix the above (hints are printed under each ❌), then re-run. Full log: ${RE_LOG_FILE#"$REPO_ROOT"/}"
    snapshot "health-failed"
    end_phase
    return 1
  fi
  say "✅ HEALTH CHECK PASSED — both clusters and the Active-Active database are healthy"
  record "health-check" PASS 0 "2 clusters, REC, RERC, REAADB, data path"
  end_phase
  return 0
}

# The outage must be OBSERVED, not assumed: the cloud CLI succeeding proves nothing (on 2026-11-26 the
# instance wait matched no VM name and passed at once). Kubernetes must answer with zero nodes.
verify_region_down() {
  local max="${CHAOS_INJECT_VERIFY_WAIT:-120}" t0=$SECONDS out n
  if [ "$CLOUD_PROVIDER" = azure ]; then
    record "region-injected" PASS 0 "AKS powerState Stopped (checked by the provider wait)"; return 0
  fi
  while :; do
    if out=$(run_to 20 kubectl --context "$region" get nodes --no-headers 2>/dev/null); then
      n=$(printf '%s\n' "$out" | grep -c . || true)
    else
      n="?"
    fi
    [ "$n" = 0 ] && break
    [ $((SECONDS - t0)) -ge "$max" ] && break
    sleep 3
  done
  sample "region-down-verify"
  if [ "$n" = 0 ]; then
    record "region-injected" PASS "$((SECONDS - t0))" "0 nodes left in $region (API up, no node)"
  else
    say "❌ the region outage did NOT take effect: $n node(s) still registered in $region"
    record "region-injected" FAIL "$((SECONDS - t0))" "$n node(s) still registered in $region — the outage did not take effect"
    return 1
  fi
}

phase_baseline() {
  snapshot "baseline"
  return 0
}

phase_pod() {
  say ""
  say "━━━ POD — force delete one Redis Enterprise pod ━━━"
  begin_phase pod
  pick_victim_pod
  wait_for_user "Simulating k8s level failure - force delete $VICTIM_INFO in $region and wait for recovery"
  say "💥 deleting pod $VICTIM"
  inject_action "kubectl delete pod $VICTIM -n $NS --force   [$VICTIM_INFO]"
  timed "kubectl: delete pod $VICTIM --force" kc delete pod "$VICTIM" -n "$NS" --force 2>&1 | grep -v '^Warning' || true
  wait_degraded "pod" 60 || true
  if wait_recovered "pod" 1 "" "$INJECT_T0"; then
    record "pod-recovery" PASS "$RECOVERY_SECS" "$VICTIM recreated, all RE nodes OK"   # tell the console BEFORE the slow snapshot
    snapshot "after-pod"
  else
    record "pod-recovery" FAIL "$RECOVERY_SECS" "timeout"
    end_phase; return 1
  fi
  if data_check "after-pod" "$region:$REC" "$OTHER:$OTHER_REC"; then
    record "pod-data" PASS 0 "write/read on both regions"
  else
    record "pod-data" FAIL 0 "write/read on both regions"
  fi
  end_phase
}

phase_node() {
  say ""
  say "━━━ NODE — hard reset of one cloud VM ━━━"
  begin_phase node
  require_cloud_auth || { end_phase; return 1; }
  pick_victim_pod
  provider_pick_node
  wait_for_user "$(provider_restart_description)"
  say "💥 $(provider_restart_description)"
  inject_action "$(provider_restart_description)"
  if ! provider_restart_node; then
    record "node-inject" FAIL 0 "cloud CLI failed"; end_phase; return 1
  fi
  wait_degraded "node" 150 || true
  if wait_recovered "node" 1 "" "$INJECT_T0"; then
    record "node-recovery" PASS "$RECOVERY_SECS" "node back, all RE nodes OK"   # BEFORE the slow snapshot
    snapshot "after-node"
  else
    record "node-recovery" FAIL "$RECOVERY_SECS" "timeout"
    end_phase; return 1
  fi
  if data_check "after-node" "$region:$REC" "$OTHER:$OTHER_REC"; then
    record "node-data" PASS 0 "write/read on both regions"
  else
    record "node-data" FAIL 0 "write/read on both regions"
  fi
  end_phase
}

# The recovery half of a region outage: nodes back, REC cluster recovery, database
# recovery, final checks. Shared by `region` and `region-recover`.
region_recovery() {
  local t0=$SECONDS
  announce_action "Bring the nodes of $region back"
  if ! provider_region_up; then
    record "region-restore" FAIL 0 "cloud CLI failed — restore the node pool by hand"; return 1
  fi
  wait_for_user "Region is back up, now restore the Redis Enterprise Cluster"
  say "🛠  recovering the REC object in $region after quorum loss"
  announce_action "Cluster recovery: spec.clusterRecovery=true on $REC"
  if ! timed "kubectl: patch rec $REC clusterRecovery" kc -n "$NS" patch rec "$REC" --type merge --patch '{"spec":{"clusterRecovery":true}}'; then
    record "region-recovery-patch" FAIL 0 "could not patch the REC"; return 1
  fi

  if wait_recovered "region-nodes" 0 1500; then
    record "region-nodes" PASS "$RECOVERY_SECS" "pods Running, all RE nodes OK"
  else
    record "region-nodes" FAIL "$RECOVERY_SECS" "timeout"
    return 1
  fi
  snapshot "region-nodes-back"
  wait_for_user "Once all indicators are green, recover the databases (rladmin recover all)"

  say "🛠  rladmin recover all"
  announce_action "Database recovery: rladmin recover all"
  timed "rladmin recover all" rec_exec "$region" "$REC" rladmin recover all | tr '\r' '\n' | grep -E 'recover|Completed|failed' || true
  if wait_recovered "region-db" 1; then
    record "region-db" PASS "$RECOVERY_SECS" "databases active again"
  else
    record "region-db" FAIL "$RECOVERY_SECS" "timeout"
    return 1
  fi
  record "region-recovery" PASS "$((SECONDS - t0))" "nodes back to databases active"   # BEFORE the slow snapshot
  snapshot "after-region"
  if data_check "after-region" "$region:$REC" "$OTHER:$OTHER_REC"; then
    record "region-data" PASS 0 "write/read on both regions"
  else
    record "region-data" FAIL 0 "write/read on both regions"
  fi
  return 0
}

phase_region() {
  say ""
  say "━━━ REGION — every node of $region removed ━━━"
  begin_phase region
  require_cloud_auth || { end_phase; return 1; }
  wait_for_user "Simulating a region outage by taking down the Kubernetes cluster in region '$region'"
  inject_action "$(provider_region_down_description)"
  if ! provider_region_down; then
    record "region-inject" FAIL 0 "outage not confirmed by the cloud (see the [sample] lines); node pool being restored"
    snapshot "region-inject-failed"
    # never leave the pool half-changed (autoscaling off, size 0): put it back exactly as Terraform has it
    say "🛠  restoring the node pool of $region (autoscaling back on, original size)"
    provider_region_up || say "⚠️  restoring the pool failed: run the gcloud commands printed above by hand"
    end_phase; return 1
  fi
  verify_region_down || true
  snapshot "region-down"

  say "🔎 the surviving region ($OTHER) must keep serving reads and writes"
  announce_action "Check that $OTHER still serves reads and writes"
  if data_check "region-down" "$OTHER:$OTHER_REC"; then
    record "survivor-data" PASS 0 "$OTHER served while $region was down"
  else
    record "survivor-data" FAIL 0 "$OTHER did NOT serve while $region was down"
  fi
  wait_for_user "DO : test that you can access data from the other region (Redis Insight), before restarting the region"

  region_recovery || { end_phase; return 1; }
  end_phase
}

# Resume after an interruption: the cluster is degraded on purpose here, so no health gate.
phase_region_recover() {
  say ""
  say "━━━ REGION RECOVERY (resume) — $region ━━━"
  begin_phase region-recover
  require_cloud_auth || { end_phase; return 1; }
  if rec_health_line "$region" "$REC" 1 >/dev/null 2>&1; then
    say "✅ $region is already healthy: nothing to recover"
    record "region-recovery" PASS 0 "already healthy, nothing to recover"
    end_phase; return 0
  fi
  wait_for_user "Bringing $region back: restore the node pool, run the cluster and database recovery"
  inject_action "Restore node pool of $region, then cluster recovery and rladmin recover all"
  region_recovery || { end_phase; return 1; }
  end_phase
}

# ---- the chaos console: offered, never required --------------------------------------------------
console_up() { curl -fsS -m 1 "http://127.0.0.1:${CHAOS_WEBUI_PORT:-5050}/api/health" >/dev/null 2>&1; }
offer_console() {
  console_up && return 0
  if [ "$INTERACTIVE" -eq 1 ]; then
    local ans=""
    printf 'Start the chaos console now? [y/N] '
    read -r ans || true
    case "$ans" in
      y|Y|yes|YES) "$REPO_ROOT/chaos-webui-start.sh" || say "⚠️  the console did not start; chaos continues without it" ;;
    esac
  else
    say "ℹ️  chaos console not running — start it with ./chaos-webui-start.sh (events are skipped otherwise)"
  fi
}

# ============================================================================
# Main
# ============================================================================
say ""
provider_prepare
offer_console

RUN_STARTED=1
chaos_notify run_start target="$REC" witness="$OTHER_REC"

if [ "$NEED_GATE" -eq 1 ] && [ "$SKIP_CHECK" -eq 0 ]; then
  if ! preflight_health; then
    chaos_notify run_end status=FAIL note="health check failed, nothing was injected"
    RUN_ENDED=1
    exit 3
  fi
  if [ "$CHECK_ONLY" -eq 1 ]; then
    say "--check-only: nothing was injected."
    chaos_notify run_end status=PASS note="check only"
    RUN_ENDED=1
    exit 0
  fi
  expected_node_count=$(kc get nodes --no-headers | wc -l | tr -d ' ')
  expected_pod_count=$(kc get pods -n "$NS" --no-headers | wc -l | tr -d ' ')
  say "Expecting $expected_node_count nodes and $expected_pod_count pods in namespace $NS ($region)"
  phase_baseline
elif [ "$SKIP_CHECK" -eq 1 ] && [ "$NEED_GATE" -eq 1 ]; then
  say "⚠️  health check SKIPPED (--skip-check): the outcome is unpredictable if the setup is not healthy."
  chaos_notify step phase=health name=health-check status=INFO note="skipped (--skip-check)"
  # counts from the live cluster when it answers, else from the configuration
  expected_node_count=$(kc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  expected_pod_count=$(kc get pods -n "$NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [ "${expected_node_count:-0}" -ge 1 ] || expected_node_count="$RE_NODES"
  [ "${expected_pod_count:-0}" -ge 1 ] || expected_pod_count=$((RE_NODES + 2))
  say "Expecting $expected_node_count nodes and $expected_pod_count pods in namespace $NS ($region)"
else
  say "⚠️  health gate skipped: region-recover works on a degraded cluster."
  if [ "$CHECK_ONLY" -eq 1 ]; then
    say "--check-only with only region-recover: nothing to check."
    chaos_notify run_end status=PASS note="check only"
    RUN_ENDED=1
    exit 0
  fi
  expected_node_count="$RE_NODES"
  expected_pod_count=$((RE_NODES + 2))      # REC pods + operator + services rigger
  say "Expecting $expected_node_count nodes and $expected_pod_count pods in namespace $NS ($region) after recovery"
fi

STOPPED_EARLY=0
for scenario in "${SELECTED[@]}"; do
  case "$scenario" in
    pod)            phase_pod || STOPPED_EARLY=1 ;;
    node)           phase_node || STOPPED_EARLY=1 ;;
    region)         phase_region || STOPPED_EARLY=1 ;;
    region-recover) phase_region_recover || STOPPED_EARLY=1 ;;
  esac
  [ "$STOPPED_EARLY" -eq 0 ] || { say "⚠️  scenario stopped early (see the summary)"; break; }
done

print_summary
say "RESULT run=$RUN_ID target=$REC scenarios=${SELECTED[*]} failed=$FAILED duration=$((SECONDS - RUN_T0))s events=${EVENTS_FILE#"$REPO_ROOT"/}"
say "   Full log: ${RE_LOG_FILE#"$REPO_ROOT"/}   (kubectl + rladmin snapshots included)"
chaos_notify run_end status="$([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)" note="$FAILED check(s) failed"
RUN_ENDED=1
[ "$FAILED" -eq 0 ]
