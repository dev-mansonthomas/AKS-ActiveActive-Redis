#!/usr/bin/env bash

# ============================================================================
# Azure Resource Tags Verification Script
# ============================================================================
# This script checks that all Azure resources have the required tags:
# - owner: firstname_lastname
# - skip_deletion: yes/no
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
echo -e "${BLUE}Azure Resource Tags Verification${NC}"
echo -e "${BLUE}============================================================================${NC}"
echo ""
echo -e "Expected tags:"
echo -e "  ${GREEN}owner${NC} = ${owner}"
echo -e "  ${GREEN}skip_deletion${NC} = ${skip_deletion}"
echo ""

# Function to check tags on a resource
check_tags() {
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

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}1. Checking Resource Groups${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check main resource group
if az group show --name "$CLUSTER_RESOURCE_GROUP" &>/dev/null; then
    tags=$(az group show --name "$CLUSTER_RESOURCE_GROUP" --query tags -o json)
    check_tags "$CLUSTER_RESOURCE_GROUP" "Resource Group" "" "$tags"
else
    echo -e "${RED}✗ Resource group '$CLUSTER_RESOURCE_GROUP' not found${NC}"
    echo ""
fi

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}2. Checking AKS Clusters${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check AKS clusters
for cluster in $CLUSTER1 $CLUSTER2; do
    if [ -n "$cluster" ]; then
        if az aks show --name "$cluster" --resource-group "$CLUSTER_RESOURCE_GROUP" &>/dev/null; then
            tags=$(az aks show --name "$cluster" --resource-group "$CLUSTER_RESOURCE_GROUP" --query tags -o json)
            check_tags "$cluster" "AKS Cluster" "$CLUSTER_RESOURCE_GROUP" "$tags"
        else
            echo -e "${YELLOW}⚠ AKS cluster '$cluster' not found (may not be created yet)${NC}"
            echo ""
        fi
    fi
done

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}3. Checking AKS-managed Resource Groups (MC_*)${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check MC resource groups (created by AKS)
for cluster in $CLUSTER1 $CLUSTER2; do
    if [ -n "$cluster" ]; then
        # Get the region from cluster name (e.g., redis-francecentral -> francecentral)
        region=${cluster#redis-}
        mc_rg="MC_${CLUSTER_RESOURCE_GROUP}_${cluster}_${region}"
        
        if az group show --name "$mc_rg" &>/dev/null; then
            tags=$(az group show --name "$mc_rg" --query tags -o json)
            echo -e "${BLUE}Info:${NC} Checking AKS-managed resource group for cluster '$cluster'"
            
            if [ -z "$tags" ] || [ "$tags" == "null" ] || [ "$tags" == "{}" ]; then
                echo -e "  ${YELLOW}⚠ No tags found (AKS-managed RGs may not inherit tags automatically)${NC}"
                echo -e "  ${YELLOW}  This is normal - tags are on the AKS cluster itself${NC}"
            else
                check_tags "$mc_rg" "Resource Group (AKS-managed)" "" "$tags"
            fi
            echo ""
        else
            echo -e "${YELLOW}⚠ AKS-managed resource group '$mc_rg' not found (cluster may not be created yet)${NC}"
            echo ""
        fi
    fi
done

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}4. Summary - Resources with your tags${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

echo -e "${BLUE}All resources tagged with owner=$owner:${NC}"
az resource list --tag owner="$owner" --query "[].{Name:name, Type:type, ResourceGroup:resourceGroup, Location:location}" -o table 2>/dev/null || echo "No resources found"
echo ""

echo -e "${BLUE}All resources tagged with skip_deletion=$skip_deletion:${NC}"
az resource list --tag skip_deletion="$skip_deletion" --query "[].{Name:name, Type:type, ResourceGroup:resourceGroup, Location:location}" -o table 2>/dev/null || echo "No resources found"
echo ""

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

