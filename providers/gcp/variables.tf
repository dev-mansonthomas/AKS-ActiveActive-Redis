# ============================================================================
# GCP GKE Variables
# ============================================================================
# NO DEFAULTS BY DESIGN. Every value comes from config.sh, exported as TF_VAR_*
# by common/lib.sh (re_export_tf_vars). A missing value must fail the plan, not
# silently fall back to something that differs from config.sh.
# ============================================================================

variable "project_id" {
  description = "GCP Project ID (config.sh: GCP_PROJECT_ID)"
  type        = string
}

variable "region1" {
  description = "Primary GCP region (config.sh: GCP_REGION1)"
  type        = string
}

variable "region2" {
  description = "Secondary GCP region (config.sh: GCP_REGION2)"
  type        = string
}

variable "cluster_prefix" {
  description = "Cluster name prefix; names are <prefix>-<region> (config.sh: CLUSTER_PREFIX)"
  type        = string
}

variable "owner" {
  description = "Owner label, firstname_lastname (config.sh: owner)"
  type        = string

  validation {
    condition     = can(regex("^[a-z]+_[a-z]+$", var.owner))
    error_message = "owner must be firstname_lastname (lowercase, underscore separated)."
  }
}

variable "skip_deletion" {
  description = "Skip-deletion label, yes or no (config.sh: skip_deletion)"
  type        = string

  validation {
    condition     = contains(["yes", "no"], var.skip_deletion)
    error_message = "skip_deletion must be 'yes' or 'no'."
  }
}

variable "node_machine_type" {
  description = "Machine type for GKE nodes (config.sh: GCP_INSTANCE_TYPE)"
  type        = string
}

variable "zones1" {
  description = "Zones for region 1; becomes node_locations (config.sh: GCP_ZONES1)"
  type        = list(string)
}

variable "zones2" {
  description = "Zones for region 2; becomes node_locations (config.sh: GCP_ZONES2)"
  type        = list(string)
}

variable "node_count" {
  description = <<-EOT
    Nodes PER ZONE in the managed node pool (config.sh: GCP_NODE_COUNT).
    On a REGIONAL cluster this is multiplied by the number of zones, so
    node_count=1 with 3 zones gives 3 nodes per region — which is what the
    REC's `nodes: 3` needs. Setting 3 here would create 9.
  EOT
  type        = number
}

variable "node_min_count" {
  description = "Autoscaling minimum (config.sh: GCP_NODE_MIN_COUNT)"
  type        = number
}

variable "node_max_count" {
  description = "Autoscaling maximum (config.sh: GCP_NODE_MAX_COUNT)"
  type        = number
}

variable "initial_node_count" {
  description = "Nodes created with the cluster itself (config.sh: GCP_INITIAL_NODE_COUNT)"
  type        = number
}

variable "release_channel" {
  description = "GKE release channel (config.sh: GCP_RELEASE_CHANNEL)"
  type        = string

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], var.release_channel)
    error_message = "release_channel must be RAPID, REGULAR or STABLE."
  }
}

variable "subnet_cidr1" {
  description = "Primary subnet CIDR, region 1 (config.sh: GCP_SUBNET_CIDR1)"
  type        = string
}

variable "subnet_cidr2" {
  description = "Primary subnet CIDR, region 2 (config.sh: GCP_SUBNET_CIDR2)"
  type        = string
}

variable "pods_cidr1" {
  description = "Secondary range for pods, region 1 (config.sh: GCP_PODS_CIDR1)"
  type        = string
}

variable "pods_cidr2" {
  description = "Secondary range for pods, region 2 (config.sh: GCP_PODS_CIDR2)"
  type        = string
}

variable "services_cidr1" {
  description = "Secondary range for services, region 1 (config.sh: GCP_SERVICES_CIDR1)"
  type        = string
}

variable "services_cidr2" {
  description = "Secondary range for services, region 2 (config.sh: GCP_SERVICES_CIDR2)"
  type        = string
}

variable "cluster_timeout" {
  description = "Timeout for GKE cluster create/update/delete (config.sh: GCP_CLUSTER_TIMEOUT)"
  type        = string
}

variable "node_pool_timeout" {
  description = <<-EOT
    Timeout for GKE node-pool create/update/delete (config.sh:
    GCP_NODE_POOL_TIMEOUT). The provider default is 40m, which this project
    exceeds regularly (measured: 35m-1h14 for node-pool operations), causing
    Terraform to abort work that GCP later completes.
  EOT
  type        = string
}

variable "redis_ports" {
  description = <<-EOT
    TCP ports opened for Redis Enterprise (config.sh: GCP_REDIS_PORTS).
    Internet-facing by design — the demo must be reachable from anywhere
    (docs/adr/0010). Security is enforced by TLS, a strong DB password and
    Redis ACLs, not by source-IP filtering.
  EOT
  type        = list(string)
}
