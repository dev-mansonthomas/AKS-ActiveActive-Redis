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

set -e

# Load configuration
source ./config.sh

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

if [ $FAILED_CHECKS -eq 0 ] && [ $TOTAL_CHECKS -gt 0 ]; then
    echo -e "${GREEN}✓ All critical resources are properly tagged!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some resources are missing tags or have incorrect values${NC}"
    exit 1
fi

