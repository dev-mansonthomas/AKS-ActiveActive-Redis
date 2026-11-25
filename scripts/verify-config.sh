#!/usr/bin/env bash
# ============================================================================
# verify-config.sh — prove config.sh fully satisfies Terraform, credential-free
# ============================================================================
# Runs entirely inside the VM: no cloud CLI, no cloud credentials, no state.
# For each provider it exports TF_VAR_* from config.sh and checks that every
# declared Terraform variable receives a value.
#
# Usage:  ./scripts/verify-config.sh [azure|aws|gcp|all]
# Log:    debug/verify-config-<timestamp>.log
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=../common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

re_log_init "verify-config"

TARGET="${1:-all}"
[ "$TARGET" = "all" ] && PROVIDERS="azure aws gcp" || PROVIDERS="$TARGET"

RE_OFFLINE=1
export RE_OFFLINE

overall=0

for prov in $PROVIDERS; do
  echo
  re_log "═══ $prov ═══"

  # Re-load config.sh with CLOUD_PROVIDER forced to this provider.
  # Run in a subshell so each provider starts clean.
  (
    unset RE_CONFIG_LOADED
    # shellcheck source=/dev/null
    . "$REPO_ROOT/config.sh" >/dev/null 2>&1
    CLOUD_PROVIDER="$prov"
    export CLOUD_PROVIDER
    export RE_CONFIG_LOADED=1

    if ! re_export_tf_vars >/dev/null 2>&1; then
      # Re-run visibly to surface which re_require failed.
      re_export_tf_vars >/dev/null || exit 1
    fi

    dir="$REPO_ROOT/providers/$prov"
    missing=0

    # Every variable declared in variables.tf must have a TF_VAR_ counterpart.
    while IFS= read -r v; do
      if [ -z "${!v:-}" ]; then
        # An unset-but-defaulted variable is acceptable; no defaults is the rule.
        if grep -A6 "variable \"${v#TF_VAR_}\"" "$dir/variables.tf" | grep -q "default"; then
          re_warn "$prov: ${v#TF_VAR_} not exported, but variables.tf has a default (should not)"
        else
          re_warn "$prov: MISSING ${v#TF_VAR_} — no TF_VAR and no default"
          missing=$((missing + 1))
        fi
      fi
    done < <(grep -oE '^variable "[a-z0-9_]+"' "$dir/variables.tf" | sed 's/variable "/TF_VAR_/;s/"//')

    declared=$(grep -c '^variable ' "$dir/variables.tf")
    defaults=$(grep -c '^  default' "$dir/variables.tf" || true)
    exported=$(env | grep -c '^TF_VAR_' || true)

    re_log "$prov: $declared variables declared, $defaults defaults (target 0), $exported TF_VAR_* exported"
    re_dump_tf_vars

    if [ "$missing" -gt 0 ]; then
      re_warn "$prov: $missing variable(s) unsatisfied"
      exit 1
    fi
    if [ "$defaults" -gt 0 ]; then
      re_warn "$prov: variables.tf still has $defaults default(s) — config.sh must be the only source"
      exit 1
    fi
    re_log "$prov: ✅ config.sh satisfies every Terraform variable"
  ) || overall=1
done

echo
if [ "$overall" -eq 0 ]; then
  re_log "✅ verify-config: all checked providers are fully driven by config.sh"
else
  re_warn "verify-config: at least one provider is incomplete"
fi
exit "$overall"
