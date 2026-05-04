# ============================================================================
# AWS EKS Variables
# ============================================================================
# Variables for creating EKS clusters across two AWS regions
# ============================================================================

variable "region1" {
  description = "Primary AWS region for first EKS cluster"
  type        = string
  default     = "us-east-1"
}

variable "region2" {
  description = "Secondary AWS region for second EKS cluster"
  type        = string
  default     = "us-west-2"
}

variable "owner" {
  description = "Owner tag (format: firstname_lastname, lowercase)"
  type        = string
  
  validation {
    condition     = can(regex("^[a-z]+_[a-z]+$", var.owner))
    error_message = "Owner must be in format: firstname_lastname (lowercase, underscore separated)"
  }
}

variable "skip_deletion" {
  description = "Skip deletion tag (yes/no)"
  type        = string
  default     = "yes"
  
  validation {
    condition     = contains(["yes", "no"], var.skip_deletion)
    error_message = "skip_deletion must be 'yes' or 'no'"
  }
}

variable "eks_version" {
  description = "Kubernetes version for EKS clusters"
  type        = string
  default     = "1.29"
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes"
  type        = string
  default     = "t3.xlarge"
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 5
}
