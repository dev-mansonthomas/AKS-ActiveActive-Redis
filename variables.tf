variable "region1" {
  type        = string
  default     = "francecentral"
  description = "Region 1 of the AA deployment"
}

variable "region2" {
  type        = string
  default     = "ukwest"
  description = "Region 2 of the AA deployment"
}

variable "instance_type" {
  type        = string
  default     = "Standard_D8s_v3"
  description = "Instance type for the AKS cluster"
}

variable "azure_rg" {
  type        = string
  default     = "ThomasManson-temp-AKS"
  description = "Resource group to provision the infrastructure"
}

variable "subscription_id" {
  type        = string
  #default     = "ef03f41d-d2bd-4691-b3a0-3aff1c6711f7"
  description = "Azure subscription ID"
}
