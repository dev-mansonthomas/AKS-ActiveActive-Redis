#!/usr/bin/env bash
# ============================================================================
# Delete All Resources - Multi-Cloud Wrapper
# ============================================================================
# This script detects the cloud provider and deletes all resources
# Supports: Azure (AKS), AWS (EKS), GCP (GKE)
# ============================================================================

set -e

# Start total timer
total_start=$(date +%s)

# Load configuration
source ../config.sh

echo "🗑️  Deleting all resources on $CLOUD_PROVIDER..."
echo "🧹 Cleaning up Kubernetes resources..."
for CLUSTER in $CLUSTER1 $CLUSTER2; do
  echo "⛔ Deleting namespace $NS in cluster $CLUSTER..."
  kubectl delete ns $NS --context=$CLUSTER 2>/dev/null || true

  echo "⛔ Deleting ingress-controller namespace in cluster $CLUSTER..."
  kubectl delete ns ingress-controller --context=$CLUSTER 2>/dev/null || true

  echo "⛔ Forcing Helm uninstall of haproxy-ingress (if still tracked) in $CLUSTER..."
  helm uninstall haproxy-ingress -n ingress-controller --kube-context=$CLUSTER 2>/dev/null || true
done

echo "🌐 Cleaning up DNS entries..."
case $CLOUD_PROVIDER in
  azure)
    az network dns record-set a delete -g $DNS_RESOURCE_GROUP -z $DNS_ZONE -n "*.$CLUSTER1" -y 2>/dev/null || true
    az network dns record-set a delete -g $DNS_RESOURCE_GROUP -z $DNS_ZONE -n "*.$CLUSTER2" -y 2>/dev/null || true
    ;;
  aws)
    # AWS Route53 cleanup would go here
    echo "⚠️  AWS DNS cleanup not yet implemented"
    ;;
  gcp)
    # GCP Cloud DNS cleanup would go here
    echo "⚠️  GCP DNS cleanup not yet implemented"
    ;;
esac

echo "🔥 Destroying infrastructure with Terraform..."
cd ../providers/$CLOUD_PROVIDER

case $CLOUD_PROVIDER in
  azure)
    TF_VAR_subscription_id=$(az account show --query id -o tsv)
    TF_VAR_azure_rg=$CLUSTER_RESOURCE_GROUP
    TF_VAR_owner=$owner
    TF_VAR_skip_deletion=$skip_deletion
    export TF_VAR_subscription_id TF_VAR_azure_rg TF_VAR_owner TF_VAR_skip_deletion
    ;;
  aws)
    export AWS_DEFAULT_REGION=$AWS_REGION1
    TF_VAR_aws_account_id=$(aws sts get-caller-identity --query Account --output text)
    TF_VAR_owner=$owner
    TF_VAR_skip_deletion=$skip_deletion
    export TF_VAR_aws_account_id TF_VAR_owner TF_VAR_skip_deletion
    ;;
  gcp)
    gcloud config set project $GCP_PROJECT_ID
    TF_VAR_owner=$owner
    TF_VAR_skip_deletion=$skip_deletion
    export TF_VAR_owner TF_VAR_skip_deletion
    ;;
esac

tofu destroy -auto-approve

cd ../../scripts

echo "Cleanup complete."

# End total timer
total_end=$(date +%s)
total_duration=$(( (total_end - total_start) / 60 ))

echo "========================================="
echo "⏱️ Total execution time: ${total_duration} minutes"
echo "========================================="