#!/usr/bin/env bash
# ============================================================================
# AWS EKS - Get Kubernetes Credentials
# ============================================================================
# This script retrieves kubeconfig credentials for both EKS clusters
# ============================================================================

set -e

# Load configuration
source ../../config.sh

echo "🔑 Configuring kubectl credentials for AWS EKS clusters..."

# Get credentials for Region 1
echo "📍 Getting credentials for cluster: redis-${AWS_REGION1}"
aws eks update-kubeconfig \
  --region "${AWS_REGION1}" \
  --name "redis-${AWS_REGION1}" \
  --alias "redis-${AWS_REGION1}"

# Get credentials for Region 2
echo "📍 Getting credentials for cluster: redis-${AWS_REGION2}"
aws eks update-kubeconfig \
  --region "${AWS_REGION2}" \
  --name "redis-${AWS_REGION2}" \
  --alias "redis-${AWS_REGION2}"

echo "✅ Kubectl credentials configured successfully!"
echo ""
echo "Test with:"
echo "  kubectl get nodes --context=redis-${AWS_REGION1}"
echo "  kubectl get nodes --context=redis-${AWS_REGION2}"
