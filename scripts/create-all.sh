#!/usr/bin/env bash
# ============================================================================
# create-all.sh — the ONE command that builds the whole demo
# ============================================================================
# Runs steps 01→04, times each, then prints the connection details (05).
# Works from any directory. Everything is logged to debug/.
#
# Usage:  ./create-all.sh            (root wrapper)  or  ./scripts/create-all.sh
# Log:    debug/create-all-<timestamp>.log
#
# HOST ONLY — needs cloud credentials. Never run inside the VM.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../common/lib.sh"

re_load_config
re_log_init "create-all"

SELECTED=$(re_selected_indexes) || exit 2
if re_is_single; then
  re_log "🚀 Redis Enterprise (single cluster, no Active/Active) on $CLOUD_PROVIDER"
  re_log "   $(re_cluster_name "$SELECTED") ($(re_region_of "$SELECTED"))"
  re_log "   DNS zone: $DNS_ZONE   (no RERC, no database)"
else
  re_log "🚀 Redis Enterprise Active/Active on $CLOUD_PROVIDER"
  re_log "   $CLUSTER1 ($REGION1)  ⇄  $CLUSTER2 ($REGION2)"
  re_log "   DNS zone: $DNS_ZONE   DB: $AA_DB_NAME"
fi
re_log "═══════════════════════════════════════════════════════════"

# Single cluster: nothing to link (03: RERC) and no Active-Active database (04).
if re_is_single; then
  STEPS="01-create-cluster.sh 02-setup-haproxy.sh"
else
  STEPS="01-create-cluster.sh 02-setup-haproxy.sh 03-setup-rerc.sh 04-create-active-active-db.sh"
fi
# Parallel indexed arrays. Associative arrays need bash 4, and macOS still
# ships bash 3.2 as /bin/bash, where that syntax is a parse error.
step_names=()
step_secs=()
overall_start=$SECONDS

for step in $STEPS; do
  re_log ""
  re_log "▶▶ $step"
  start=$SECONDS
  if ! bash "$SCRIPT_DIR/$step"; then
    step_names+=("$step")
    step_secs+=("$((SECONDS - start))")
    re_warn "$step FAILED after $((SECONDS - start))s — aborting."
    re_warn "Diagnostics: ./scripts/get-logs.sh"
    exit 1
  fi
  step_names+=("$step")
  step_secs+=("$((SECONDS - start))")
done

re_log ""
re_log "═══════════════════════════════════════════════════════════"
re_log "⏱️  Execution summary"
i=0
while [ "$i" -lt "${#step_names[@]}" ]; do
  d=${step_secs[$i]}
  re_log "$(printf '   • %-32s %2dm %02ds' "${step_names[$i]}" $((d / 60)) $((d % 60)))"
  i=$((i + 1))
done
total=$((SECONDS - overall_start))
re_log "$(printf '   🔴 %-32s %2dm %02ds' "TOTAL" $((total / 60)) $((total % 60)))"
re_log "═══════════════════════════════════════════════════════════"

# The operator publishes the database ingress (<db>-db.<rec>.<zone>) shortly after
# the database turns active; step 05 reads it. Poll for it instead of sleeping a
# fixed 10 s (up to 60 s, usually a couple of seconds).
if ! re_is_single; then
  re_log "Waiting for the database ingress on both clusters..."
  for _ctx in "$CLUSTER1" "$CLUSTER2"; do
    for _ in $(seq 1 30); do
      kubectl --context="$_ctx" get ingress -n "$NS" \
        -o jsonpath='{range .items[*].spec.rules[*]}{.host}{"\n"}{end}' 2>/dev/null \
        | grep -q -- '-db\.' && break
      sleep 2
    done
  done
fi

bash "$SCRIPT_DIR/05-get-cluster-info.sh"

re_log ""
re_log "✅ Demo ready. Tear down with: ./${CLOUD_PROVIDER}-deploy.sh --destroy"
re_log "   Diagnostics:  ./scripts/get-logs.sh"
re_log "   This log:     ${RE_LOG_FILE#"$REPO_ROOT"/}"
