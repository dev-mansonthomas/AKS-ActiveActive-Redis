# ============================================================================
# Multi-Cloud Redis Enterprise Active/Active Configuration
# ============================================================================

# ============================================================================
# Cloud Provider Selection
# ============================================================================

# Select your cloud provider: azure, aws, or gcp
# This determines which infrastructure templates and scripts will be used
CLOUD_PROVIDER=azure

# ============================================================================
# Azure Resource Groups Configuration
# ============================================================================

# Resource Group for AKS clusters (temporary, can be deleted after demos)
# This resource group contains all AKS infrastructure (clusters, nodes, disks, IPs, load balancers)
# Example: ThomasManson-temp-AKS
AZURE_CLUSTER_RESOURCE_GROUP=ThomasManson-temp-AKS

# Resource Group for DNS Zone (permanent, low cost)
# This resource group contains only the Azure DNS Zone
# Keep this separate from CLUSTER_RESOURCE_GROUP to preserve DNS configuration
# Example: ThomasManson
AZURE_DNS_RESOURCE_GROUP=ThomasManson

# Azure regions
AZURE_REGION1=francecentral
AZURE_REGION2=ukwest

# Azure VM instance type for AKS nodes
AZURE_INSTANCE_TYPE=Standard_D8s_v3

# ============================================================================
# AWS Configuration (for future use)
# ============================================================================

# AWS doesn't use resource groups, but we use this value as a tag
AWS_CLUSTER_RESOURCE_GROUP=ThomasManson-temp-EKS

# AWS regions
AWS_REGION1=us-east-1
AWS_REGION2=us-west-2

# AWS EC2 instance type for EKS nodes
AWS_INSTANCE_TYPE=m5.2xlarge

# ============================================================================
# GCP Configuration (for future use)
# ============================================================================

# GCP Project ID
GCP_PROJECT_ID=my-redis-project

# GCP regions
GCP_REGION1=us-central1
GCP_REGION2=europe-west1

# GCP machine type for GKE nodes
GCP_INSTANCE_TYPE=n1-standard-8

# ============================================================================
# Cloud Provider Aliases (for backward compatibility)
# ============================================================================

# Set variables based on selected cloud provider
case $CLOUD_PROVIDER in
  azure)
    CLUSTER_RESOURCE_GROUP=$AZURE_CLUSTER_RESOURCE_GROUP
    DNS_RESOURCE_GROUP=$AZURE_DNS_RESOURCE_GROUP
    REGION1=$AZURE_REGION1
    REGION2=$AZURE_REGION2
    INSTANCE_TYPE=$AZURE_INSTANCE_TYPE
    ;;
  aws)
    CLUSTER_RESOURCE_GROUP=$AWS_CLUSTER_RESOURCE_GROUP
    REGION1=$AWS_REGION1
    REGION2=$AWS_REGION2
    INSTANCE_TYPE=$AWS_INSTANCE_TYPE
    ;;
  gcp)
    CLUSTER_RESOURCE_GROUP=$GCP_PROJECT_ID
    REGION1=$GCP_REGION1
    REGION2=$GCP_REGION2
    INSTANCE_TYPE=$GCP_INSTANCE_TYPE
    ;;
  *)
    echo "❌ ERROR: Invalid CLOUD_PROVIDER: $CLOUD_PROVIDER (must be azure, aws, or gcp)"
    exit 1
    ;;
esac

# ============================================================================
# Redis Enterprise Active/Active Database Configuration
# ============================================================================

# Active/Active Database name
# Pattern: ^[a-z]($|[a-z0-9-]*[a-z0-9])$ (lowercase, alphanumeric, hyphens allowed)
# Example: active-active-db
AA_DB_NAME=active-active-db

# ============================================================================
# Cluster Names (auto-generated based on cloud provider and regions)
# ============================================================================

# Cluster name prefix
CLUSTER_PREFIX=redis

# Generate cluster names based on cloud provider
CLUSTER1=${CLUSTER_PREFIX}-${REGION1}
CLUSTER2=${CLUSTER_PREFIX}-${REGION2}

# Optional third cluster (leave empty if not used)
CLUSTER3=

# ============================================================================
# DNS Configuration
# ============================================================================

# Azure DNS Zone for cluster FQDNs
# Redis Enterprise Active/Active requires FQDNs (not public IPs)
# Example: demo.paquerette.com
DNS_ZONE=demo.paquerette.com

# ============================================================================
# Kubernetes Configuration
# ============================================================================

# Kubernetes namespace for Redis Enterprise resources
# Default: rec
NS=rec

# ============================================================================
# Resource Tags/Labels (for compliance and cost tracking - all clouds)
# ============================================================================

# Owner tag/label - identifies resource owner
# Format: firstname_lastname (lowercase)
# Example: thomas_manson
owner=thomas_manson

# Skip deletion tag/label - prevents accidental resource deletion
# Values: yes or no
# Default: yes
skip_deletion=yes

# ============================================================================
# Validation
# ============================================================================

# Display configuration summary
echo "✅ Configuration loaded successfully"
echo "   Cloud Provider: $CLOUD_PROVIDER"
echo "   Cluster 1: $CLUSTER1 (region: $REGION1)"
echo "   Cluster 2: $CLUSTER2 (region: $REGION2)"
echo "   Owner: $owner"
echo "   Skip Deletion: $skip_deletion"
