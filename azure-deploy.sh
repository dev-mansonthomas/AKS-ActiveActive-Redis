#!/usr/bin/env bash
# ============================================================================
# azure-deploy.sh — deploy (or tear down) the demo on Azure / AKS
# ============================================================================
#   ./azure-deploy.sh --plan-only | (nothing) | --destroy
#
# HOST ONLY — needs az credentials.
# ============================================================================

set -uo pipefail

# shellcheck disable=SC2034  # consumed by common-deploy.sh
DEPLOY_CLOUD="azure"

# shellcheck source=common/deploy-lib.sh
_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common/deploy-lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=common/deploy-lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

cloud_preflight() {
  local fail=0 unverified=0
  _AUTH_BROKEN=0

  if ! command -v az >/dev/null 2>&1; then
    re_warn "  ❌ az CLI not found — https://learn.microsoft.com/cli/azure/install-azure-cli"
    return 1
  fi
  re_log "  ✅ az $(az version --output tsv --query '"azure-cli"' 2>/dev/null)"

  re_azure_select_subscription

  # ---- Credentials block. ------------------------------------------------
  cloud_q az account show --query name -o tsv
  if [ "$_Q_RC" -eq 0 ]; then
    re_log "  ✅ subscription: $_Q_OUT"
  elif cloud_is_auth_error "$_Q_ERR"; then
    _AUTH_BROKEN=1
    re_warn "  credential expired: $_Q_ERR"
  else
    re_warn "  ❌ not logged in — run: az login. $_Q_ERR"
    return $((fail + 1))
  fi

  if [ "${_AUTH_BROKEN:-0}" -eq 1 ]; then
    re_warn "  🔑 THE az CLI CREDENTIAL IS EXPIRED — fix this first:"
    re_warn "         az login"
    return $((fail + 1))
  fi

  # ---- Best-effort introspection below. ----------------------------------
  local region
  for region in "$AZURE_REGION1" "$AZURE_REGION2"; do
    cloud_q az vm list-skus --location "$region" --size "$AZURE_INSTANCE_TYPE" \
      --query "[?name=='$AZURE_INSTANCE_TYPE'].name" -o tsv
    if [ "$_Q_RC" -ne 0 ]; then
      if cloud_is_auth_error "$_Q_ERR"; then
        _AUTH_BROKEN=1
      elif cloud_is_permission_error "$_Q_ERR"; then
        re_warn "  cannot query VM SKUs in $region. Not blocking. Detail: $_Q_ERR"
        unverified=$((unverified + 1))
      else
        re_warn "  ❌ region '$region' unreachable: $_Q_ERR"
        fail=$((fail + 1))
      fi
    elif [ -n "$_Q_OUT" ]; then
      re_log "  ✅ $AZURE_INSTANCE_TYPE available in $region"
    else
      re_warn "  ❌ VM size '$AZURE_INSTANCE_TYPE' not available in '$region'"
      re_warn "     see docs/TODO.md I1 (quota/region finder)"
      fail=$((fail + 1))
    fi
  done

  # DNS zone — required by Active/Active.
  cloud_q az network dns zone show -g "$AZURE_DNS_RESOURCE_GROUP" -n "$DNS_ZONE" --query name -o tsv
  if [ "$_Q_RC" -ne 0 ]; then
    if cloud_is_auth_error "$_Q_ERR"; then
      _AUTH_BROKEN=1
    elif cloud_is_permission_error "$_Q_ERR"; then
      re_warn "  cannot read DNS zone '$DNS_ZONE'. Not blocking. Detail: $_Q_ERR"
      unverified=$((unverified + 1))
    else
      re_warn "  ❌ DNS zone '$DNS_ZONE' not found in RG '$AZURE_DNS_RESOURCE_GROUP'"
      re_warn "     Active/Active identifies clusters by FQDN. Create and delegate it first."
      fail=$((fail + 1))
    fi
  else
    re_log "  ✅ DNS zone $DNS_ZONE in resource group $AZURE_DNS_RESOURCE_GROUP"
  fi

  # This one is pure config, always checkable, and destructive if wrong.
  if [ "$AZURE_DNS_RESOURCE_GROUP" = "$AZURE_CLUSTER_RESOURCE_GROUP" ]; then
    re_warn "  ❌ AZURE_DNS_RESOURCE_GROUP equals AZURE_CLUSTER_RESOURCE_GROUP —"
    re_warn "     teardown would delete your DNS zone. Keep them separate."
    fail=$((fail + 1))
  fi

  re_log "  ℹ️  planned footprint: 2 clusters x $AZURE_NODE_COUNT x $AZURE_INSTANCE_TYPE"

  if [ "${_AUTH_BROKEN:-0}" -eq 1 ]; then
    re_warn "  🔑 THE CLOUD CLI CREDENTIAL IS EXPIRED — this is the real problem."
    re_warn "     The queries above failed while refreshing your auth token, before"
    re_warn "     any permission was evaluated. OpenTofu may still work (it uses"
    re_warn "     separate credentials), but the deploy needs the CLI for kubeconfig"
    re_warn "     and DNS, so it would fail later. Fix it now:"
    re_warn ""
    re_warn "         az login"
    re_warn ""
    fail=$((fail + 1))
  elif [ "$unverified" -gt 0 ]; then
    re_warn "  $unverified check(s) could not be verified (insufficient read"
    re_warn "     permissions). This does NOT block: 'tofu plan' is the real test."
  fi
  return "$fail"
}

deploy_parse_args "$@"
deploy_main
