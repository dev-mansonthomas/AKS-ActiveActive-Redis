#!/usr/bin/env bash
# ============================================================================
# Azure AKS - Get Kubernetes Credentials
# ============================================================================
# This script retrieves kubectl credentials for Azure AKS clusters
# Usage: ./get-credentials.sh
# ============================================================================

set -e

# Load configuration from root config.sh
source ../../config.sh

echo "🔑 Getting AKS credentials for Azure clusters..."

# Get credentials for cluster 1
if [ -n "$CLUSTER1" ]; then
    echo "📍 Cluster 1: $CLUSTER1 in region $AZURE_REGION1"
    az aks get-credentials \
        -g "$CLUSTER_RESOURCE_GROUP" \
        --name "$CLUSTER1" \
        --context "$CLUSTER1" \
        --overwrite-existing
    echo "✅ Credentials for $CLUSTER1 configured"
fi

# Get credentials for cluster 2
if [ -n "$CLUSTER2" ]; then
    echo "📍 Cluster 2: $CLUSTER2 in region $AZURE_REGION2"
    az aks get-credentials \
        -g "$CLUSTER_RESOURCE_GROUP" \
        --name "$CLUSTER2" \
        --context "$CLUSTER2" \
        --overwrite-existing
    echo "✅ Credentials for $CLUSTER2 configured"
fi

echo ""
echo "🎉 Azure AKS credentials configured successfully!"
echo "Available contexts:"
kubectl config get-contexts | grep redis
