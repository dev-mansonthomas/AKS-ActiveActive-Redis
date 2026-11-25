# ============================================================================
# AWS EKS Variables
# ============================================================================
# NO DEFAULTS BY DESIGN. Every value comes from config.sh, exported as TF_VAR_*
# by common/lib.sh (re_export_tf_vars). A missing value must fail the plan, not
# silently fall back to something that differs from config.sh.
# ============================================================================

variable "region1" {
  description = "Primary AWS region (config.sh: AWS_REGION1)"
  type        = string
}

variable "region2" {
  description = "Secondary AWS region (config.sh: AWS_REGION2)"
  type        = string
}

variable "cluster_prefix" {
  description = "Cluster name prefix; names are <prefix>-<region> (config.sh: CLUSTER_PREFIX)"
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

variable "eks_version" {
  description = "Kubernetes version for the EKS clusters (config.sh: AWS_EKS_VERSION)"
  type        = string
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS nodes (config.sh: AWS_INSTANCE_TYPE)"
  type        = string
}

variable "az_count" {
  description = <<-EOT
    Number of availability zones to spread across (config.sh: AWS_AZ_COUNT).
    One public + one private subnet is created per AZ, and the EKS node group
    balances across them.
  EOT
  type        = number

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6 (EKS requires at least 2)."
  }
}

variable "node_desired_size" {
  description = <<-EOT
    TOTAL desired node count (config.sh: AWS_NODE_DESIRED_SIZE).
    Unlike GKE, this is a total across all AZs, so 3 with az_count=3 gives one
    node per zone.
  EOT
  type        = number
}

variable "node_min_size" {
  description = "Autoscaling minimum (config.sh: AWS_NODE_MIN_SIZE)"
  type        = number
}

variable "node_max_size" {
  description = "Autoscaling maximum (config.sh: AWS_NODE_MAX_SIZE)"
  type        = number
}

variable "vpc_cidr1" {
  description = "VPC CIDR for region 1; must not overlap vpc_cidr2 (config.sh: AWS_VPC_CIDR1)"
  type        = string
}

variable "vpc_cidr2" {
  description = "VPC CIDR for region 2; must not overlap vpc_cidr1 (config.sh: AWS_VPC_CIDR2)"
  type        = string
}
