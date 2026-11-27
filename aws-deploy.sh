#!/usr/bin/env bash
# ============================================================================
# aws-deploy.sh — deploy (or tear down) the demo on AWS / EKS
# ============================================================================
#   ./aws-deploy.sh --plan-only | (nothing) | --destroy
#
# HOST ONLY — needs aws credentials.
#
# ⚠️  AWS is not finished: common/dns-aws.sh only writes A records, while ELBs
#     publish a hostname (needs CNAME/alias). See docs/TODO.md A8.
# ============================================================================

set -uo pipefail

# shellcheck disable=SC2034  # consumed by common-deploy.sh
DEPLOY_CLOUD="aws"

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

  if ! command -v aws >/dev/null 2>&1; then
    re_warn "  ❌ aws CLI not found — https://docs.aws.amazon.com/cli/"
    return 1
  fi
  re_log "  ✅ aws $(aws --version 2>&1 | awk '{print $1}')"

  re_aws_select_profile

  # ---- Credentials block. ------------------------------------------------
  cloud_q aws sts get-caller-identity --query Arn --output text
  if [ "$_Q_RC" -eq 0 ]; then
    re_log "  ✅ authenticated as $_Q_OUT"
  elif cloud_is_auth_error "$_Q_ERR"; then
    _AUTH_BROKEN=1
    re_warn "  credential expired: $_Q_ERR"
  else
    re_warn "  ❌ not authenticated — run: aws configure  (or set AWS_PROFILE). $_Q_ERR"
    fail=$((fail + 1))
  fi

  # Probe the credential once: an expired token makes every later query fail
  # with a misleading reason. `sts get-caller-identity` above already did this,
  # so only classify it here.
  if [ "${_AUTH_BROKEN:-0}" -eq 1 ]; then
    re_warn "  🔑 THE aws CLI CREDENTIAL IS EXPIRED — fix this first:"
    re_warn "         aws configure     # or: aws sso login"
    return $((fail + 1))
  fi

  # ---- Best-effort introspection below. ----------------------------------
  local region
  for region in "$AWS_REGION1" "$AWS_REGION2"; do
    cloud_q aws ec2 describe-instance-type-offerings --region "$region" \
      --filters "Name=instance-type,Values=$AWS_INSTANCE_TYPE" \
      --query 'InstanceTypeOfferings[0].InstanceType' --output text
    if [ "$_Q_RC" -ne 0 ]; then
      if cloud_is_auth_error "$_Q_ERR"; then
        _AUTH_BROKEN=1
      elif cloud_is_permission_error "$_Q_ERR"; then
        re_warn "  cannot query instance types in $region (no ec2:DescribeInstanceTypeOfferings)."
        re_warn "     Not blocking. Detail: $_Q_ERR"
        unverified=$((unverified + 1))
      else
        re_warn "  ❌ region '$region' unreachable: $_Q_ERR"
        fail=$((fail + 1))
      fi
    elif [ "$_Q_OUT" = "$AWS_INSTANCE_TYPE" ]; then
      re_log "  ✅ $AWS_INSTANCE_TYPE offered in $region"
    else
      re_warn "  ❌ instance type '$AWS_INSTANCE_TYPE' not offered in '$region'"
      re_warn "     see docs/TODO.md I1 (quota/region finder)"
      fail=$((fail + 1))
    fi
  done

  # EKS version availability.
  cloud_q aws eks describe-cluster-versions \
    --query "clusterVersions[?clusterVersion=='$AWS_EKS_VERSION'].clusterVersion" --output text
  if [ "$_Q_RC" -ne 0 ]; then
    re_warn "  cannot check EKS versions. Detail: $_Q_ERR"
    unverified=$((unverified + 1))
  elif [ "$_Q_OUT" = "$AWS_EKS_VERSION" ]; then
    re_log "  ✅ EKS version $AWS_EKS_VERSION available"
  else
    re_warn "  ❌ EKS version '$AWS_EKS_VERSION' not available (check AWS_EKS_VERSION)"
    fail=$((fail + 1))
  fi

  # Route53 hosted zone — required by Active/Active.
  cloud_q aws route53 list-hosted-zones-by-name --dns-name "$DNS_ZONE" \
    --query "HostedZones[?Name=='${DNS_ZONE}.'].Id" --output text
  if [ "$_Q_RC" -ne 0 ]; then
    re_warn "  cannot list Route53 zones. Detail: $_Q_ERR"
    re_warn "     A hosted zone for '$DNS_ZONE' IS required — step 02 writes"
    re_warn "     '*.<cluster>.$DNS_ZONE' records and will fail without it."
    unverified=$((unverified + 1))
  elif [ -n "$_Q_OUT" ] && [ "$_Q_OUT" != "None" ]; then
    re_log "  ✅ Route53 hosted zone $_Q_OUT for $DNS_ZONE"
  else
    re_warn "  ❌ no Route53 hosted zone for '$DNS_ZONE'"
    re_warn "     Active/Active identifies clusters by FQDN. Create and delegate it first."
    fail=$((fail + 1))
  fi

  re_warn "  KNOWN GAP: common/dns-aws.sh writes A records only; ELBs publish a"
  re_warn "     hostname, so DNS creation stops with a clear error (docs/TODO.md A8)."

  re_log "  ℹ️  planned footprint: 2 clusters x $AWS_NODE_DESIRED_SIZE x $AWS_INSTANCE_TYPE"

  if [ "${_AUTH_BROKEN:-0}" -eq 1 ]; then
    re_warn "  🔑 THE CLOUD CLI CREDENTIAL IS EXPIRED — this is the real problem."
    re_warn "     The queries above failed while refreshing your auth token, before"
    re_warn "     any permission was evaluated. OpenTofu may still work (it uses"
    re_warn "     separate credentials), but the deploy needs the CLI for kubeconfig"
    re_warn "     and DNS, so it would fail later. Fix it now:"
    re_warn ""
    re_warn "         aws configure  # or: aws sso login"
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
