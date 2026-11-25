# ============================================================================
# Azure AKS Variables
# ============================================================================
# NO DEFAULTS BY DESIGN. Every value comes from config.sh, exported as TF_VAR_*
# by common/lib.sh (re_export_tf_vars). A missing value must fail the plan, not
# silently fall back to something that differs from config.sh.
# ============================================================================

variable "subscription_id" {
  description = "Azure subscription ID — read from the host's `az` session, not config.sh"
  type        = string
}

variable "azure_rg" {
  description = "Resource group for the AKS clusters (config.sh: AZURE_CLUSTER_RESOURCE_GROUP)"
  type        = string
}

variable "region1" {
  description = "Primary Azure region (config.sh: AZURE_REGION1)"
  type        = string
}

variable "region2" {
  description = "Secondary Azure region (config.sh: AZURE_REGION2)"
  type        = string
}

variable "cluster_prefix" {
  description = "Cluster name prefix; names are <prefix>-<region> (config.sh: CLUSTER_PREFIX)"
  type        = string
}

variable "instance_type" {
  description = "VM size for AKS nodes (config.sh: AZURE_INSTANCE_TYPE)"
  type        = string
}

variable "zones" {
  description = "AKS availability zones, e.g. [\"1\",\"2\",\"3\"] (config.sh: AZURE_ZONES)"
  type        = list(string)
}

variable "node_count" {
  description = <<-EOT
    TOTAL nodes in the default node pool (config.sh: AZURE_NODE_COUNT).
    Unlike GKE, AKS treats this as a total and spreads it across `zones`, so
    node_count=3 with 3 zones gives one node per zone.
  EOT
  type        = number
}

variable "dns_prefix" {
  description = "AKS DNS prefix (config.sh: AZURE_DNS_PREFIX)"
  type        = string
}

variable "network_plugin" {
  description = "AKS network plugin (config.sh: AZURE_NETWORK_PLUGIN)"
  type        = string
}

variable "load_balancer_sku" {
  description = "AKS load balancer SKU (config.sh: AZURE_LOAD_BALANCER_SKU)"
  type        = string
}

variable "owner" {
  description = "Owner tag, firstname_lastname (config.sh: owner)"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+_[a-z]+$", var.owner))
    error_message = "owner must be firstname_lastname (lowercase, underscore separated)."
  }
}

variable "skip_deletion" {
  description = "Skip-deletion tag, yes or no (config.sh: skip_deletion)"
  type        = string

  validation {
    condition     = contains(["yes", "no"], var.skip_deletion)
    error_message = "skip_deletion must be 'yes' or 'no'."
  }
}
