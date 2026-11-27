#!/usr/bin/env bash

# ============================================================================
# Multi-Cloud Resource Tags Verification Script
# ============================================================================
# This script checks that all cloud resources have the required tags:
# - owner: firstname_lastname
# - skip_deletion: yes/no
#
# Supports: Azure (AKS), AWS (EKS), GCP (GKE)
# ============================================================================

set -uo pipefail

_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common/lib.sh"
if [ ! -r "$_LIB" ]; then
  echo "FATAL: cannot read $_LIB" >&2
  exit 1
fi
# shellcheck source=common/lib.sh
. "$_LIB" || { echo "FATAL: failed to load $_LIB" >&2; exit 1; }

# --expect-empty : after a teardown, finding NOTHING is the success case.
EXPECT_EMPTY=0
case "${1:-}" in
  --expect-empty) EXPECT_EMPTY=1 ;;
  -h|--help)
    echo "Usage: ./check-tags.sh [--expect-empty]"
    echo "  (no flag)        audit mode: every resource must carry owner + skip_deletion"
    echo "  --expect-empty   post-teardown mode: success means no resource was found"
    exit 0 ;;
  "") ;;
  *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

re_load_config
re_log_init "check-tags"

# Use the account config.sh names, not whatever happens to be globally active.
re_cloud_select_account

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

echo -e "${BLUE}============================================================================${NC}"
echo -e "${BLUE}Multi-Cloud Resource Tags Verification${NC}"
echo -e "${BLUE}============================================================================${NC}"
echo ""
echo -e "Cloud Provider: ${GREEN}${CLOUD_PROVIDER}${NC}"
echo -e "Expected tags:"
echo -e "  ${GREEN}owner${NC} = ${owner}"
echo -e "  ${GREEN}skip_deletion${NC} = ${skip_deletion}"
echo ""

# Function to check tags on Azure resources
check_tags_azure() {
    local resource_name=$1
    local resource_type=$2
    local resource_group=$3
    local tags=$4

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    echo -e "${BLUE}Checking:${NC} $resource_type '$resource_name'"

    if [ -z "$tags" ] || [ "$tags" == "null" ]; then
        echo -e "  ${RED}✗ No tags found${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi

    # Check owner tag
    local owner_tag=$(echo "$tags" | jq -r '.owner // empty')
    if [ "$owner_tag" == "$owner" ]; then
        echo -e "  ${GREEN}✓ owner = $owner_tag${NC}"
    else
        echo -e "  ${RED}✗ owner tag missing or incorrect (expected: $owner, found: $owner_tag)${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi

    # Check skip_deletion tag
    local skip_deletion_tag=$(echo "$tags" | jq -r '.skip_deletion // empty')
    if [ "$skip_deletion_tag" == "$skip_deletion" ]; then
        echo -e "  ${GREEN}✓ skip_deletion = $skip_deletion_tag${NC}"
    else
        echo -e "  ${RED}✗ skip_deletion tag missing or incorrect (expected: $skip_deletion, found: $skip_deletion_tag)${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi

    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    echo -e "  ${GREEN}✓ All tags OK${NC}"
    echo ""
    return 0
}

# Function to check tags on AWS resources
check_tags_aws() {
    local resource_arn=$1
    local resource_type=$2
    local region=$3

    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    local resource_name=$(echo "$resource_arn" | rev | cut -d'/' -f1 | rev)
    echo -e "${BLUE}Checking:${NC} $resource_type '$resource_name' (region: $region)"

    # Get tags for the resource
    local tags=$(aws resourcegroupstaggingapi get-resources \
        --region "$region" \
        --resource-arn-list "$resource_arn" \
        --query 'ResourceTagMappingList[0].Tags' \
        --output json 2>/dev/null)

    if [ -z "$tags" ] || [ "$tags" == "null" ] || [ "$tags" == "[]" ]; then
        echo -e "  ${RED}✗ No tags found${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi

    # Check owner tag (AWS tags are in format [{"Key": "owner", "Value": "thomas_manson"}])
    local owner_tag=$(echo "$tags" | jq -r '.[] | select(.Key=="owner") | .Value // empty')
    if [ "$owner_tag" == "$owner" ]; then
        echo -e "  ${GREEN}✓ owner = $owner_tag${NC}"
    else
        echo -e "  ${RED}✗ owner tag missing or incorrect (expected: $owner, found: $owner_tag)${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi

    # Check skip_deletion tag
    local skip_deletion_tag=$(echo "$tags" | jq -r '.[] | select(.Key=="skip_deletion") | .Value // empty')
    if [ "$skip_deletion_tag" == "$skip_deletion" ]; then
        echo -e "  ${GREEN}✓ skip_deletion = $skip_deletion_tag${NC}"
    else
        echo -e "  ${RED}✗ skip_deletion tag missing or incorrect (expected: $skip_deletion, found: $skip_deletion_tag)${NC}"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi

    PASSED_CHECKS=$((PASSED_CHECKS + 1))
    echo -e "  ${GREEN}✓ All tags OK${NC}"
    echo ""
    return 0
}

# Run cloud-specific checks
case $CLOUD_PROVIDER in
  azure)
    source ./scripts/check-tags-azure.sh
    ;;
  aws)
    source ./scripts/check-tags-aws.sh
    ;;
  gcp)
    source ./scripts/check-tags-gcp.sh
    ;;
  *)
    echo -e "${RED}✗ Unknown cloud provider: $CLOUD_PROVIDER${NC}"
    exit 1
    ;;
esac

# Final summary
echo -e "${BLUE}============================================================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}============================================================================${NC}"
echo -e "Total checks: $TOTAL_CHECKS"
echo -e "${GREEN}Passed: $PASSED_CHECKS${NC}"
echo -e "${RED}Failed: $FAILED_CHECKS${NC}"
echo ""

# Exit semantics depend on why you are running this.
#
# Audit mode (default): resources are expected to exist and be tagged, so
#   finding none is suspicious — it usually means the wrong project, region or
#   CLUSTER_PREFIX, not a clean account.
# --expect-empty (after teardown): finding none is exactly what we want, and
#   finding anything means the teardown leaked billable resources.
if [ "$EXPECT_EMPTY" -eq 1 ]; then
  if [ "$TOTAL_CHECKS" -eq 0 ]; then
    re_log "✅ nothing found — teardown left no billable resource behind"
    exit 0
  fi
  re_warn "$TOTAL_CHECKS resource(s) still exist after teardown:"
  re_warn "   they are billable. Re-run: ./${CLOUD_PROVIDER}-deploy.sh --destroy"
  exit 1
fi

if [ "$TOTAL_CHECKS" -eq 0 ]; then
  re_warn "no resource found at all."
  re_warn "   Either nothing is deployed, or config.sh points elsewhere:"
  re_warn "     project/subscription : $CLUSTER_RESOURCE_GROUP"
  re_warn "     regions              : $REGION1, $REGION2"
  re_warn "     CLUSTER_PREFIX       : $CLUSTER_PREFIX"
  re_warn "   After a teardown this is expected — use --expect-empty then."
  exit 1
fi

if [ "$FAILED_CHECKS" -eq 0 ]; then
  re_log "✅ $TOTAL_CHECKS resource(s) attributable to you"
  if [ "$CLOUD_PROVIDER" = "gcp" ]; then
    re_log "   (clusters verified by LABEL; network resources and node pools by"
    re_log "    NAME prefix only — GCP does not support labels on those. ADR 0006)"
  fi
  exit 0
fi
re_warn "$FAILED_CHECKS of $TOTAL_CHECKS resource(s) are not attributable:"
re_warn "   missing/wrong labels, or a name outside the '$CLUSTER_PREFIX' prefix"
exit 1

