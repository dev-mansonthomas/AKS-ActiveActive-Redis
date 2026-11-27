# ============================================================================
# GCP GKE Outputs
# ============================================================================
# Output values for GKE clusters and networking
# ============================================================================

# Region 1 Outputs
# ============================================================================

output "region1_cluster_name" {
  description = "GKE cluster name for region 1"
  value       = google_container_cluster.region1.name
}

output "region1_cluster_endpoint" {
  description = "GKE cluster endpoint for region 1"
  value       = google_container_cluster.region1.endpoint
  sensitive   = true
}

output "region1_cluster_location" {
  description = "GKE cluster location for region 1"
  value       = google_container_cluster.region1.location
}

output "region1_cluster_ca_certificate" {
  description = "GKE cluster CA certificate for region 1"
  value       = google_container_cluster.region1.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

# Region 2 Outputs
# ============================================================================

output "region2_cluster_name" {
  description = "GKE cluster name for region 2"
  value       = google_container_cluster.region2.name
}

output "region2_cluster_endpoint" {
  description = "GKE cluster endpoint for region 2"
  value       = google_container_cluster.region2.endpoint
  sensitive   = true
}

output "region2_cluster_location" {
  description = "GKE cluster location for region 2"
  value       = google_container_cluster.region2.location
}

output "region2_cluster_ca_certificate" {
  description = "GKE cluster CA certificate for region 2"
  value       = google_container_cluster.region2.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

# Network Outputs
# ============================================================================

output "vpc_name" {
  description = "VPC network name"
  value       = google_compute_network.vpc.name
}

output "vpc_self_link" {
  description = "VPC network self link"
  value       = google_compute_network.vpc.self_link
}

output "region1_subnet_name" {
  description = "Subnet name for region 1"
  value       = google_compute_subnetwork.region1.name
}

output "region2_subnet_name" {
  description = "Subnet name for region 2"
  value       = google_compute_subnetwork.region2.name
}

# Summary Output
# ============================================================================

output "deployment_summary" {
  description = "Summary of the GCP deployment"
  value = {
    project_id = var.project_id
    region1 = {
      name     = google_container_cluster.region1.name
      location = google_container_cluster.region1.location
      version  = google_container_cluster.region1.master_version
    }
    region2 = {
      name     = google_container_cluster.region2.name
      location = google_container_cluster.region2.location
      version  = google_container_cluster.region2.master_version
    }
    labels = {
      owner         = var.owner
      skip_deletion = var.skip_deletion
    }
  }
}
