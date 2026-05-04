#!/usr/bin/env bash
# ============================================================================
# GCP GKE - Get Kubernetes Credentials
# ============================================================================
# This script retrieves kubeconfig credentials for both GKE clusters
# ============================================================================

set -e

# Load configuration
source ../../config.sh

echo "🔑 Configuring kubectl credentials for GCP GKE clusters..."

# Get credentials for Region 1
echo "📍 Getting credentials for cluster: redis-${GCP_REGION1}"
gcloud container clusters get-credentials "redis-${GCP_REGION1}" \
  --region "${GCP_REGION1}" \
  --project "${GCP_PROJECT_ID}"

# Rename context for consistency
kubectl config rename-context "gke_${GCP_PROJECT_ID}_${GCP_REGION1}_redis-${GCP_REGION1}" "redis-${GCP_REGION1}" 2>/dev/null || true

# Get credentials for Region 2
echo "📍 Getting credentials for cluster: redis-${GCP_REGION2}"
gcloud container clusters get-credentials "redis-${GCP_REGION2}" \
  --region "${GCP_REGION2}" \
  --project "${GCP_PROJECT_ID}"

# Rename context for consistency
kubectl config rename-context "gke_${GCP_PROJECT_ID}_${GCP_REGION2}_redis-${GCP_REGION2}" "redis-${GCP_REGION2}" 2>/dev/null || true

echo "✅ Kubectl credentials configured successfully!"
echo ""
echo "Test with:"
echo "  kubectl get nodes --context=redis-${GCP_REGION1}"
echo "  kubectl get nodes --context=redis-${GCP_REGION2}"
