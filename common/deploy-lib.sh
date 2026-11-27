#!/usr/bin/env bash
# ============================================================================
# common/deploy-lib.sh — shared body of the per-cloud deploy scripts
# ============================================================================
# Not executable on its own. Sourced by ./{gcp,aws,azure}-deploy.sh (repo root)
# after they set DEPLOY_CLOUD.
#
# Provides:
#   deploy_parse_args "$@"   --destroy / --skip-preflight / --plan-only
#   deploy_main              preflight -> banner -> create or destroy -> report
#
# HOST ONLY. This is the credentialed entry point; the VM has no cloud CLIs.
# ============================================================================

# shellcheck disable=SC2034  # some flags are read by the per-cloud hooks

_DEPLOY_SELF="${BASH_SOURCE[0]}"
REPO_ROOT_GUESS="$(cd "$(dirname "$_DEPLOY_SELF")/.." && pwd)"
# shellcheck source=/dev/null
. "$REPO_ROOT_GUESS/common/lib.sh"

DESTROY=0
SKIP_PREFLIGHT=0
PLAN_ONLY=0

deploy_usage() {
  cat <<USAGE
Usage: ./${DEPLOY_CLOUD}-deploy.sh [options]

Deploys the Redis Enterprise Active/Active demo on $(re_upper "$DEPLOY_CLOUD"), or tears it down.
Reads ALL configuration from config.sh. Logs to debug/.

Options:
  --destroy          Tear everything down instead of deploying.
  --plan-only        Run preflight + 'tofu plan' and stop. Changes nothing.
  --skip-preflight   Skip the prerequisite checks (not recommended).
  -h, --help         This message.

Examples:
  ./${DEPLOY_CLOUD}-deploy.sh --plan-only    # safe first run
  ./${DEPLOY_CLOUD}-deploy.sh                # build the demo
  ./${DEPLOY_CLOUD}-deploy.sh --destroy      # remove everything
USAGE
}

deploy_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --destroy)        DESTROY=1 ;;
      --plan-only)      PLAN_ONLY=1 ;;
      --yes|-y)         ;;  # accepted for compatibility; runs are always unattended
      --skip-preflight) SKIP_PREFLIGHT=1 ;;
      -h|--help)        deploy_usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; deploy_usage >&2; exit 2 ;;
    esac
    shift
  done
}

# ============================================================================
# Graded-severity introspection helpers
# ============================================================================
# DESIGN RULE: the preflight must never be more privileged than the deploy.
# A principal that can create clusters often cannot read project metadata,
# list enabled services, or enumerate regions. So each check yields one of:
#
#   ✅ verified OK    — proven good
#   ⚠️  cannot verify  — permission denied / API disabled. NOT blocking.
#   ❌ verified bad    — the query succeeded and the answer is wrong. Blocking.
#   🔑 auth broken     — the CLI credential is expired. Blocking, but the fix is
#                        a single re-login, not a config change.
#
# The auth class matters: OpenTofu uses application-default credentials, so
# `tofu plan` can succeed while every `gcloud`/`aws`/`az` call fails. The deploy
# still needs the CLI later (get-credentials.sh, common/dns-*.sh), so we must
# stop early — with the right message.

# cloud_q <command...> — run a read-only query, keeping stdout/stderr apart.
# Sets _Q_OUT, _Q_ERR, _Q_RC.
cloud_q() {
  _Q_OUT=""; _Q_ERR=""; _Q_RC=0
  local errfile
  errfile=$(mktemp)
  _Q_OUT=$("$@" 2>"$errfile") || _Q_RC=$?
  _Q_ERR=$(tr '\n' ' ' < "$errfile" | cut -c1-200)
  rm -f "$errfile"
  return 0
}

# cloud_is_auth_error <stderr-text> — is the CLI credential expired/unusable?
# Distinct from a permission error: the CLI cannot authenticate AT ALL, so the
# query result tells us nothing. This DOES block, because the deploy needs the
# cloud CLI later (get-credentials.sh, common/dns-*.sh) even though OpenTofu
# uses separate application-default credentials and may work fine.
cloud_is_auth_error() {
  case "$1" in
    *"Reauthentication failed"*|*"problem refreshing your current auth tokens"* \
    |*"credentials were not found"*|*"was not found in the credentials store"* \
    |*"Please run"*"auth login"*|*"invalid_grant"*|*"Token has been expired"* \
    |*ExpiredToken*|*"security token included in the request is expired"* \
    |*"az login"*|*InteractiveAuthenticationRequired*)
      return 0 ;;
  esac
  return 1
}

# cloud_is_permission_error <stderr-text> — "you may not ask" vs "it is absent"?
cloud_is_permission_error() {
  case "$1" in
    *PERMISSION_DENIED*|*"does not have permission"*|*"Permission denied"* \
    |*403*|*"caller does not have"*|*AccessDenied*|*"not authorized"* \
    |*UnauthorizedOperation*|*AuthorizationError*|*AuthorizationFailed* \
    |*"has not been used in project"*|*"is disabled"*|*SERVICE_DISABLED* \
    |*"not enabled"*|*"does not have authorization"*)
      return 0 ;;
  esac
  return 1
}

# ============================================================================
# Preflight
# ============================================================================
_preflight_fail=0

_need_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    # `kubectl version` without --client CONTACTS the current cluster: with a stale
    # context that is a ~30 s timeout inside the preflight (measured 2026-11-25).
    local _v
    case "$1" in
      kubectl) _v=$(kubectl version --client 2>/dev/null | head -1 | cut -c1-48) ;;
      *)       _v=$( { "$1" --version 2>/dev/null || "$1" version 2>/dev/null; } | head -1 | cut -c1-48) ;;
    esac
    re_log "  ✅ $1 $_v"
  else
    re_warn "  ❌ $1 not found${2:+ — $2}"
    _preflight_fail=$((_preflight_fail + 1))
  fi
}

# deploy_preflight_destroy — the MINIMUM needed to tear down safely.
# Teardown must never be blocked by checks that only matter for creating things
# (machine-type availability, IAM for new resources, name collisions, DNS zone
# presence...): a demo that cannot be destroyed keeps billing and stays exposed
# (ADR 0010). So: tools + a working credential, nothing else.
deploy_preflight_destroy() {
  re_log "🔎 Minimal preflight for DESTROY ($DEPLOY_CLOUD) — creation checks skipped on purpose"
  _need_cmd tofu    "https://opentofu.org/docs/intro/install/"
  _need_cmd kubectl
  _need_cmd helm
  _need_cmd jq
  if declare -F cloud_auth_check >/dev/null 2>&1; then
    cloud_auth_check || _preflight_fail=$((_preflight_fail + 1))
  else
    re_warn "  no cloud credential check defined for $DEPLOY_CLOUD — relying on the tools themselves"
  fi
  if [ "$_preflight_fail" -gt 0 ]; then
    re_die "cannot destroy: $_preflight_fail prerequisite(s) missing — nothing was changed"
  fi
  re_log "✅ Minimal preflight passed"
}

deploy_preflight() {
  re_log "🔎 Preflight for $DEPLOY_CLOUD"

  re_log "Tools:"
  _need_cmd tofu    "https://opentofu.org/docs/intro/install/"
  _need_cmd kubectl
  _need_cmd helm
  _need_cmd jq
  _need_cmd curl
  _need_cmd base64
  command -v dig >/dev/null 2>&1 \
    && re_log "  ✅ dig" \
    || re_warn "  dig not found — DNS checks will be skipped (non-fatal)"

  # Per-cloud tool + auth checks, defined by the caller.
  re_log "Cloud ($DEPLOY_CLOUD):"
  cloud_preflight || _preflight_fail=$((_preflight_fail + 1))

  # config.sh must fully satisfy Terraform.
  re_log "Configuration:"
  if bash "$REPO_ROOT/scripts/verify-config.sh" "$DEPLOY_CLOUD" >/dev/null 2>&1; then
    re_log "  ✅ config.sh satisfies every Terraform variable for $DEPLOY_CLOUD"
  else
    re_warn "  ❌ config.sh is incomplete for $DEPLOY_CLOUD"
    re_warn "     run: ./scripts/verify-config.sh $DEPLOY_CLOUD"
    _preflight_fail=$((_preflight_fail + 1))
  fi

  if [ "$CLOUD_PROVIDER" != "$DEPLOY_CLOUD" ]; then
    re_warn "  ❌ config.sh has CLOUD_PROVIDER=$CLOUD_PROVIDER but you ran the"
    re_warn "     $DEPLOY_CLOUD script. Set CLOUD_PROVIDER=$DEPLOY_CLOUD in config.sh."
    _preflight_fail=$((_preflight_fail + 1))
  else
    re_log "  ✅ CLOUD_PROVIDER=$DEPLOY_CLOUD"
  fi

  # DNS zone is a hard requirement for Active/Active (FQDN-based).
  if [ -z "${DNS_ZONE:-}" ]; then
    re_warn "  ❌ DNS_ZONE is empty — Active/Active needs resolvable FQDNs"
    _preflight_fail=$((_preflight_fail + 1))
  else
    re_log "  ✅ DNS_ZONE=$DNS_ZONE"
  fi

  # Terraform config must validate before we touch the cloud.
  re_log "Terraform:"
  if ( cd "$REPO_ROOT/providers/$DEPLOY_CLOUD" \
        && tofu init -backend=false -input=false >/dev/null 2>&1 \
        && tofu validate >/dev/null 2>&1 ); then
    re_log "  ✅ providers/$DEPLOY_CLOUD validates"
  else
    re_warn "  ❌ providers/$DEPLOY_CLOUD does not validate"
    _preflight_fail=$((_preflight_fail + 1))
  fi

  if [ "$_preflight_fail" -gt 0 ]; then
    re_die "preflight failed with $_preflight_fail problem(s) — nothing was changed"
  fi
  re_log "✅ Preflight passed"
}

# ============================================================================
# Confirmation
# ============================================================================
# ============================================================================
# Summary banner
# ============================================================================
# No interactive confirmation: this is a disposable demo rig. Both create and
# destroy run unattended. The guardrails that matter are the preflight (which
# refuses to touch the cloud when anything is wrong) and `--plan-only`.
# shellcheck disable=SC2154  # owner comes from config.sh
deploy_banner() {
  local action="$1"
  echo
  echo "  ╭──────────────────────────────────────────────────────────────╮"
  printf '  │  %-60s│\n' "$action"
  echo "  ├──────────────────────────────────────────────────────────────┤"
  printf '  │  cloud    : %-49s│\n' "$DEPLOY_CLOUD"
  printf '  │  clusters : %-49s│\n' "$CLUSTER1, $CLUSTER2"
  printf '  │  regions  : %-49s│\n' "$REGION1, $REGION2"
  printf '  │  machine  : %-49s│\n' "$INSTANCE_TYPE"
  printf '  │  DNS zone : %-49s│\n' "$DNS_ZONE"
  printf '  │  owner    : %-49s│\n' "$owner"
  echo "  ╰──────────────────────────────────────────────────────────────╯"
  echo
}

# ============================================================================
# Main
# ============================================================================
deploy_main() {
  re_load_config

  if [ "$DESTROY" -eq 1 ]; then
    re_log_init "${DEPLOY_CLOUD}-destroy"
  else
    re_log_init "${DEPLOY_CLOUD}-deploy"
  fi

  re_log "═══════════════════════════════════════════════════════════"
  re_log " Redis Enterprise Active/Active — $(re_upper "$DEPLOY_CLOUD")"
  re_log "═══════════════════════════════════════════════════════════"

  # ALWAYS enforced, even with --skip-preflight: running the wrong cloud's script
  # against a config.sh for another cloud would act on the wrong cloud's resources.
  if [ "$CLOUD_PROVIDER" != "$DEPLOY_CLOUD" ]; then
    re_die "config.sh has CLOUD_PROVIDER=$CLOUD_PROVIDER but you ran ./${DEPLOY_CLOUD}-deploy.sh — set CLOUD_PROVIDER=$DEPLOY_CLOUD in config.sh"
  fi

  if [ "$SKIP_PREFLIGHT" -eq 1 ]; then
    re_warn "preflight skipped (--skip-preflight)"
  elif [ "$DESTROY" -eq 1 ]; then
    deploy_preflight_destroy
  else
    deploy_preflight
  fi

  # ---------------------------------------------------------------- plan only
  if [ "$PLAN_ONLY" -eq 1 ]; then
    re_log "📋 tofu plan (no changes will be made)"
    re_export_tf_vars
    ( cd "$REPO_ROOT/providers/$DEPLOY_CLOUD" \
        && re_tofu_init \
        && re_run tofu plan -input=false ) \
      || re_die "tofu plan failed"
    re_log "✅ plan complete — nothing was changed"
    return 0
  fi

  # ----------------------------------------------------------------- destroy
  if [ "$DESTROY" -eq 1 ]; then
    deploy_banner "DESTROYING the $(re_upper "$DEPLOY_CLOUD") demo"
    local start=$SECONDS
    if bash "$REPO_ROOT/scripts/delete-all-resources.sh"; then
      re_log "✅ Teardown finished in $(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
      re_log "Verify nothing is left:  ./check-tags.sh"
    else
      re_warn "Teardown reported failures — resources may remain."
      re_warn "Check:  ./check-tags.sh   and   ./scripts/logs.sh errors"
      return 1
    fi
    return 0
  fi

  # ------------------------------------------------------------------ deploy
  deploy_banner "DEPLOYING the $(re_upper "$DEPLOY_CLOUD") demo (2 clusters, billable)"
  local start=$SECONDS
  if bash "$REPO_ROOT/scripts/create-all.sh"; then
    re_log ""
    re_log "✅ Demo ready in $(( (SECONDS - start) / 60 ))m $(( (SECONDS - start) % 60 ))s"
    re_log "   Connection details : ./scripts/05-get-cluster-info.sh"
    re_log "   Diagnostics        : ./scripts/get-logs.sh"
    re_log "   Tag compliance     : ./check-tags.sh"
    re_log "   TEAR DOWN          : ./${DEPLOY_CLOUD}-deploy.sh --destroy"
  else
    re_warn "Deployment failed. The demo is likely half-built."
    re_warn "  Diagnostics : ./scripts/get-logs.sh"
    re_warn "  Errors      : ./scripts/logs.sh errors"
    re_warn "  Clean up    : ./${DEPLOY_CLOUD}-deploy.sh --destroy"
    return 1
  fi
}
