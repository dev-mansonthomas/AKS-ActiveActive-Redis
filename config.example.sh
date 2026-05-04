# ============================================================================
# Multi-Cloud Redis Enterprise Active/Active Configuration Example
# ============================================================================
# Copy this file to config.sh and customize for your environment
# Usage: cp config.example.sh config.sh
# ============================================================================

# ============================================================================
# Cloud Provider Selection
# ============================================================================

# Select your cloud provider: azure, aws, or gcp
# This determines which infrastructure templates and scripts will be used
CLOUD_PROVIDER=azure

# ============================================================================
# Common Configuration (applies to all cloud providers)
# ============================================================================

# Active/Active Database name
# Pattern: ^[a-z]($|[a-z0-9-]*[a-z0-9])$ (lowercase, alphanumeric, hyphens allowed)
# Example: active-active-db, my-redis-db
AA_DB_NAME=active-active-db

# Cluster name prefix (will be combined with region names)
# Format: {CLUSTER_PREFIX}-{region}
# Examples: redis-francecentral, redis-us-east-1, redis-us-central1
CLUSTER_PREFIX=redis

# DNS Zone for cluster FQDNs
# Redis Enterprise Active/Active requires FQDNs (not public IPs)
# You must own this domain and have it configured in your cloud provider's DNS
# Example: demo.yourdomain.com, redis.example.com
DNS_ZONE=demo.paquerette.com

# Kubernetes namespace for Redis Enterprise resources
# Default: rec (Redis Enterprise Cluster)
NS=rec

# ============================================================================
# Azure Resource Tags / AWS Tags / GCP Labels
# (Required for compliance and cost tracking across all clouds)
# ============================================================================

# Owner tag/label - identifies resource owner
# Format: firstname_lastname (lowercase, no spaces)
# Example: john_doe, alice_smith
owner=thomas_manson

# Skip deletion tag/label - prevents accidental resource deletion
# Values: yes or no
# Use "yes" for production resources, "no" for temporary test resources
skip_deletion=yes

# ============================================================================
# Azure-Specific Configuration
# ============================================================================

# Resource Group for AKS clusters (temporary, can be deleted after demos)
# This resource group contains all AKS infrastructure (clusters, nodes, disks, IPs, load balancers)
# Example: MyName-temp-AKS, redis-demo-aks
AZURE_CLUSTER_RESOURCE_GROUP=ThomasManson-temp-AKS

# Resource Group for DNS Zone (permanent, low cost)
# This resource group contains only the Azure DNS Zone
# Keep this separate from CLUSTER_RESOURCE_GROUP to preserve DNS configuration
# Example: MyName-DNS, shared-dns-resources
AZURE_DNS_RESOURCE_GROUP=ThomasManson

# Azure regions for the two clusters
# List of Azure regions: https://azure.microsoft.com/en-us/global-infrastructure/locations/
# Examples: francecentral, ukwest, eastus, westeurope
AZURE_REGION1=francecentral
AZURE_REGION2=ukwest

# Azure VM instance type for AKS nodes
# Format: Standard_{Series}{Version}_{Size}
# Examples: Standard_D8s_v3, Standard_D4s_v3, Standard_E8s_v3
# Recommendation: D8s_v3 or higher (8 vCPU, 32 GB RAM)
AZURE_INSTANCE_TYPE=Standard_D8s_v3

# Azure subscription ID (optional - auto-detected if not set)
# Get with: az account show --query id -o tsv
# AZURE_SUBSCRIPTION_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Cluster names (auto-generated from prefix + region)
CLUSTER1=${CLUSTER_PREFIX}-${AZURE_REGION1}
CLUSTER2=${CLUSTER_PREFIX}-${AZURE_REGION2}

# Backward compatibility aliases
CLUSTER_RESOURCE_GROUP=$AZURE_CLUSTER_RESOURCE_GROUP
DNS_RESOURCE_GROUP=$AZURE_DNS_RESOURCE_GROUP

# ============================================================================
# AWS-Specific Configuration
# ============================================================================

# AWS doesn't use resource groups, but we use this value as a tag
# All AWS resources will be tagged with: ResourceGroup={AWS_CLUSTER_RESOURCE_GROUP}
# Example: MyName-temp-EKS, redis-demo-eks
AWS_CLUSTER_RESOURCE_GROUP=ThomasManson-temp-EKS

# AWS regions for the two EKS clusters
# List of AWS regions: https://aws.amazon.com/about-aws/global-infrastructure/regions_az/
# Examples: us-east-1, us-west-2, eu-west-1, ap-southeast-1
AWS_REGION1=us-east-1
AWS_REGION2=us-west-2

# AWS EC2 instance type for EKS nodes
# Examples: m5.2xlarge, m5.xlarge, r5.2xlarge
# Recommendation: m5.2xlarge or higher (8 vCPU, 32 GB RAM)
AWS_INSTANCE_TYPE=m5.2xlarge

# AWS Account ID (optional - auto-detected if not set)
# Get with: aws sts get-caller-identity --query Account --output text
# AWS_ACCOUNT_ID=123456789012

# Route53 Hosted Zone ID (optional - will be created if not provided)
# Get with: aws route53 list-hosted-zones --query "HostedZones[?Name=='$DNS_ZONE.'].Id" --output text
# AWS_HOSTED_ZONE_ID=Z1234567890ABC

# Cluster names (auto-generated from prefix + region)
# AWS_CLUSTER1=${CLUSTER_PREFIX}-${AWS_REGION1}
# AWS_CLUSTER2=${CLUSTER_PREFIX}-${AWS_REGION2}

# ============================================================================
# GCP-Specific Configuration
# ============================================================================

# GCP Project ID (required for GCP)
# Get with: gcloud config get-value project
# Example: my-redis-project, redis-enterprise-demo
GCP_PROJECT_ID=my-redis-project

# GCP doesn't use resource groups, but we use project for organization
# All GCP resources will be in project: {GCP_PROJECT_ID}
GCP_CLUSTER_RESOURCE_GROUP=${GCP_PROJECT_ID}

# GCP regions for the two GKE clusters
# List of GCP regions: https://cloud.google.com/compute/docs/regions-zones
# Examples: us-central1, europe-west1, asia-east1
GCP_REGION1=us-central1
GCP_REGION2=europe-west1

# GCP machine type for GKE nodes
# Examples: n1-standard-8, n2-standard-8, e2-standard-8
# Recommendation: n1-standard-8 or higher (8 vCPU, 30 GB RAM)
GCP_INSTANCE_TYPE=n1-standard-8

# Cloud DNS managed zone name (optional - will be created if not provided)
# Get with: gcloud dns managed-zones list --filter="dnsName:$DNS_ZONE" --format="value(name)"
# GCP_DNS_ZONE_NAME=redis-demo-zone

# Cluster names (auto-generated from prefix + region)
# GCP_CLUSTER1=${CLUSTER_PREFIX}-${GCP_REGION1}
# GCP_CLUSTER2=${CLUSTER_PREFIX}-${GCP_REGION2}

# ============================================================================
# Advanced Configuration (optional)
# ============================================================================

# Number of nodes per cluster (default: 3)
# Minimum: 3 (required for Redis Enterprise HA)
NODE_COUNT=3

# Optional third cluster for multi-region Active/Active (leave empty if not used)
CLUSTER3=

# Redis Enterprise version (optional - uses latest if not specified)
# REDIS_ENTERPRISE_VERSION=7.4.2-54

# Enable rack awareness for zone distribution (yes/no)
# RACK_AWARENESS=no

# Enable Redis on Flash (yes/no)
# REDIS_ON_FLASH=no

# ============================================================================
# Validation
# ============================================================================

# Validate required variables
if [ -z "$CLOUD_PROVIDER" ]; then
  echo "❌ ERROR: CLOUD_PROVIDER is not set"
  exit 1
fi

if [ -z "$owner" ]; then
  echo "❌ ERROR: owner tag is not set"
  exit 1
fi

if [ -z "$DNS_ZONE" ]; then
  echo "❌ ERROR: DNS_ZONE is not set"
  exit 1
fi

# Cloud-specific validation
case $CLOUD_PROVIDER in
  azure)
    if [ -z "$AZURE_CLUSTER_RESOURCE_GROUP" ]; then
      echo "❌ ERROR: AZURE_CLUSTER_RESOURCE_GROUP is not set"
      exit 1
    fi
    ;;
  aws)
    if [ -z "$AWS_REGION1" ] || [ -z "$AWS_REGION2" ]; then
      echo "❌ ERROR: AWS_REGION1 and AWS_REGION2 must be set"
      exit 1
    fi
    ;;
  gcp)
    if [ -z "$GCP_PROJECT_ID" ]; then
      echo "❌ ERROR: GCP_PROJECT_ID is not set"
      exit 1
    fi
    ;;
  *)
    echo "❌ ERROR: Invalid CLOUD_PROVIDER: $CLOUD_PROVIDER (must be azure, aws, or gcp)"
    exit 1
    ;;
esac

echo "✅ Configuration validated successfully for $CLOUD_PROVIDER"
