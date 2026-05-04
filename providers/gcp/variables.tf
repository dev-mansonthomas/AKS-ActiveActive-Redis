# ============================================================================
# GCP GKE Variables
# ============================================================================
# Variables for creating GKE clusters across two GCP regions
# ============================================================================

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region1" {
  description = "Primary GCP region for first GKE cluster"
  type        = string
  default     = "us-central1"
}

variable "region2" {
  description = "Secondary GCP region for second GKE cluster"
  type        = string
  default     = "us-west1"
}

variable "owner" {
  description = "Owner label (format: firstname_lastname, lowercase)"
  type        = string
  
  validation {
    condition     = can(regex("^[a-z]+_[a-z]+$", var.owner))
    error_message = "Owner must be in format: firstname_lastname (lowercase, underscore separated)"
  }
}

variable "skip_deletion" {
  description = "Skip deletion label (yes/no)"
  type        = string
  default     = "yes"
  
  validation {
    condition     = contains(["yes", "no"], var.skip_deletion)
    error_message = "skip_deletion must be 'yes' or 'no'"
  }
}

variable "node_machine_type" {
  description = "Machine type for GKE worker nodes"
  type        = string
  default     = "e2-standard-4"
}

variable "node_count" {
  description = "Initial number of worker nodes per zone"
  type        = number
  default     = 3
}

variable "node_min_count" {
  description = "Minimum number of worker nodes in the node pool"
  type        = number
  default     = 2
}

variable "node_max_count" {
  description = "Maximum number of worker nodes in the node pool"
  type        = number
  default     = 5
}
