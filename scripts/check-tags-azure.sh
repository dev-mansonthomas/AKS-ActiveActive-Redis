#!/usr/bin/env bash
# ============================================================================
# Azure Resource Tags Verification
# ============================================================================

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}1. Checking Resource Groups${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check main resource group
if az group show --name "$CLUSTER_RESOURCE_GROUP" &>/dev/null; then
    tags=$(az group show --name "$CLUSTER_RESOURCE_GROUP" --query tags -o json)
    check_tags_azure "$CLUSTER_RESOURCE_GROUP" "Resource Group" "" "$tags"
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
            check_tags_azure "$cluster" "AKS Cluster" "$CLUSTER_RESOURCE_GROUP" "$tags"
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
                check_tags_azure "$mc_rg" "Resource Group (AKS-managed)" "" "$tags"
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
