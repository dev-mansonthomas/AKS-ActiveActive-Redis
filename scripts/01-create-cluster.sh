#!/usr/bin/env bash
# ============================================================================
# Create Kubernetes Clusters - Multi-Cloud Wrapper
# ============================================================================
# This script detects the cloud provider and creates K8s clusters accordingly
# Supports: Azure (AKS), AWS (EKS), GCP (GKE)
# ============================================================================

set -e

# Load configuration
source ../config.sh

echo "🚀 Creating Kubernetes clusters on $CLOUD_PROVIDER..."

# Navigate to provider-specific directory
cd ../providers/$CLOUD_PROVIDER

case $CLOUD_PROVIDER in
  azure)
    echo "📍 Creating Azure AKS clusters..."
    TF_VAR_subscription_id=$(az account show --query id -o tsv)
    TF_VAR_azure_rg=$CLUSTER_RESOURCE_GROUP
    TF_VAR_owner=$owner
    TF_VAR_skip_deletion=$skip_deletion
    export TF_VAR_subscription_id TF_VAR_azure_rg TF_VAR_owner TF_VAR_skip_deletion
    ;;
  aws)
    echo "📍 Creating AWS EKS clusters..."
    export AWS_DEFAULT_REGION=$AWS_REGION1
    TF_VAR_aws_account_id=$(aws sts get-caller-identity --query Account --output text)
    TF_VAR_owner=$owner
    TF_VAR_skip_deletion=$skip_deletion
    export TF_VAR_aws_account_id TF_VAR_owner TF_VAR_skip_deletion
    ;;
  gcp)
    echo "📍 Creating GCP GKE clusters..."
    gcloud config set project $GCP_PROJECT_ID
    TF_VAR_owner=$owner
    TF_VAR_skip_deletion=$skip_deletion
    export TF_VAR_owner TF_VAR_skip_deletion
    ;;
esac

echo "🔧 Initializing Terraform/OpenTofu..."
tofu init

echo "🏗️  Applying infrastructure..."
tofu apply -auto-approve

echo "✅ Kubernetes clusters created successfully!"

# Get kubectl credentials
echo "🔑 Configuring kubectl credentials..."
./get-credentials.sh

# Return to scripts directory
cd ../../scripts