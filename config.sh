# ============================================================================
# Azure Resource Groups Configuration
# ============================================================================

# Resource Group for AKS clusters (temporary, can be deleted after demos)
# This resource group contains all AKS infrastructure (clusters, nodes, disks, IPs, load balancers)
# Example: ThomasManson-temp-AKS
CLUSTER_RESOURCE_GROUP=ThomasManson-temp-AKS

# Resource Group for DNS Zone (permanent, low cost)
# This resource group contains only the Azure DNS Zone
# Keep this separate from CLUSTER_RESOURCE_GROUP to preserve DNS configuration
# Example: ThomasManson
DNS_RESOURCE_GROUP=ThomasManson

# ============================================================================
# Redis Enterprise Active/Active Database Configuration
# ============================================================================

# Active/Active Database name
# Pattern: ^[a-z]($|[a-z0-9-]*[a-z0-9])$ (lowercase, alphanumeric, hyphens allowed)
# Example: active-active-db
AA_DB_NAME=active-active-db

# ============================================================================
# AKS Cluster Names (based on Azure regions)
# ============================================================================

# Primary cluster name (region 1)
# Format: redis-{region_name}
# Example: redis-francecentral
CLUSTER1=redis-francecentral

# Secondary cluster name (region 2)
# Format: redis-{region_name}
# Example: redis-ukwest
CLUSTER2=redis-ukwest

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
# Azure Resource Tags (for compliance and cost tracking)
# ============================================================================

# Owner tag - identifies resource owner
# Format: firstname_lastname (lowercase)
# Example: thomas_manson
owner=thomas_manson

# Skip deletion tag - prevents accidental resource deletion
# Values: yes or no
# Default: yes
skip_deletion=yes
