#!/usr/bin/env bash
# ============================================================================
# Azure AKS - Chaos Engineering Operations
# ============================================================================
# This script contains Azure-specific chaos operations for testing resilience
# Functions: restart_node, stop_cluster, start_cluster
# ============================================================================

set -e

# Load configuration
source ../../config.sh

# Function: Restart a VMSS instance (node restart simulation)
restart_node() {
    local cluster=$1
    local region=$2
    local instance_id=$3
    
    echo "🔄 Restarting VMSS instance $instance_id in cluster $cluster..."
    
    # Find VMSS name and resource group
    local vmss_info=$(az vmss list --query "[?tags.\"aks-managed-cluster-name\"=='$cluster'].{name:name, rg:resourceGroup}" -o tsv)
    local vmss_name=$(echo "$vmss_info" | awk '{print $1}')
    local rg=$(echo "$vmss_info" | awk '{print $2}')
    
    if [ -z "$vmss_name" ]; then
        echo "❌ Error: Could not find VMSS for cluster $cluster"
        return 1
    fi
    
    echo "Found VMSS: $vmss_name in resource group: $rg"
    
    # Restart the instance
    az vmss restart \
        --name "$vmss_name" \
        --resource-group "$rg" \
        --instance-ids "$instance_id"
    
    echo "✅ Instance $instance_id restart initiated"
}

# Function: Stop AKS cluster (region outage simulation)
stop_cluster() {
    local cluster=$1
    
    echo "⛔ Stopping AKS cluster: $cluster..."
    
    az aks stop \
        --name "$cluster" \
        --resource-group "$CLUSTER_RESOURCE_GROUP"
    
    echo "⏳ Waiting for cluster to fully stop..."
    while true; do
        state=$(az aks show \
            --name "$cluster" \
            --resource-group "$CLUSTER_RESOURCE_GROUP" \
            --query "powerState.code" \
            -o tsv 2>/dev/null || echo "Unavailable")
        
        echo "Current powerState: '$state'"
        
        if [[ "$state" == "Stopped" ]]; then
            echo "✅ Cluster $cluster is stopped"
            break
        fi
        
        echo -n "."
        sleep 5
    done
}

# Function: Start AKS cluster (recovery from outage)
start_cluster() {
    local cluster=$1
    
    echo "🚀 Starting AKS cluster: $cluster..."
    
    az aks start \
        --name "$cluster" \
        --resource-group "$CLUSTER_RESOURCE_GROUP"
    
    echo "⏳ Waiting for cluster to fully start..."
    while true; do
        state=$(az aks show \
            --name "$cluster" \
            --resource-group "$CLUSTER_RESOURCE_GROUP" \
            --query "powerState.code" \
            -o tsv 2>/dev/null || echo "Unavailable")
        
        echo "Current powerState: '$state'"
        
        if [[ "$state" == "Running" ]]; then
            echo "✅ Cluster $cluster is running"
            break
        fi
        
        sleep 5
    done
}

# Function: Get VMSS information for a cluster
get_vmss_info() {
    local cluster=$1
    
    echo "📊 VMSS information for cluster $cluster:"
    
    az vmss list \
        --query "[?tags.\"aks-managed-cluster-name\"=='$cluster'].{Name:name, ResourceGroup:resourceGroup, Location:location}" \
        -o table
}

# Export functions for use in chaos.sh
export -f restart_node
export -f stop_cluster
export -f start_cluster
export -f get_vmss_info
