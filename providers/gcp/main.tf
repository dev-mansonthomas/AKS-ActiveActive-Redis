# ============================================================================
# GCP GKE Infrastructure for Redis Enterprise Active/Active
# ============================================================================
# This Terraform configuration creates:
# - VPC with subnets in 2 regions
# - 2 GKE clusters in different regions
# - Node pools with auto-scaling
# - All resources labeled with owner and skip_deletion
# ============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# ============================================================================
# Provider Configuration
# ============================================================================

provider "google" {
  project = var.project_id

  # Default labels applied to all resources
  default_labels = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
    managed_by    = "terraform"
    project_name  = "redis-enterprise-aa"
  }
}

# ============================================================================
# VPC Network (Global in GCP)
# ============================================================================

resource "google_compute_network" "vpc" {
  name                    = "redis-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  description = "VPC for Redis Enterprise Active/Active deployment"
}

# ============================================================================
# Subnets for Region 1
# ============================================================================

resource "google_compute_subnetwork" "region1" {
  name          = "redis-subnet-${var.region1}"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region1
  network       = google_compute_network.vpc.id

  # Secondary IP ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.0.16.0/20"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.0.32.0/20"
  }

  description = "Subnet for GKE cluster in ${var.region1}"
}

# ============================================================================
# Subnets for Region 2
# ============================================================================

resource "google_compute_subnetwork" "region2" {
  name          = "redis-subnet-${var.region2}"
  ip_cidr_range = "10.1.0.0/20"
  region        = var.region2
  network       = google_compute_network.vpc.id

  # Secondary IP ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.16.0/20"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.1.32.0/20"
  }

  description = "Subnet for GKE cluster in ${var.region2}"
}

# ============================================================================
# Firewall Rules
# ============================================================================

resource "google_compute_firewall" "allow_internal" {
  name    = "redis-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8"]
  description   = "Allow internal communication between GKE clusters"
}

resource "google_compute_firewall" "allow_redis" {
  name    = "redis-allow-redis-ports"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8001", "8443", "9443", "10000-19999"]
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Allow Redis Enterprise ports"
}

# ============================================================================
# GKE Cluster - Region 1
# ============================================================================

resource "google_container_cluster" "region1" {
  name     = "redis-${var.region1}"
  location = var.region1

  # Use regional cluster for high availability
  node_locations = []

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.region1.name

  # Start with minimal node pool (will be replaced by managed node pool)


  # IP allocation for pods and services
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Maintenance window
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }

  # Enable addons
  addons_config {
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  # Release channel
  release_channel {
    channel = "REGULAR"
  }

  resource_labels = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

resource "google_container_node_pool" "region1" {
  name       = "redis-${var.region1}-nodes"
  location   = var.region1
  cluster    = google_container_cluster.region1.name
  node_count = var.node_count

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 100
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      owner         = var.owner
      skip_deletion = var.skip_deletion
      cluster       = "redis-${var.region1}"
    }

    tags = ["redis-gke-node", "redis-${var.region1}"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ============================================================================
# GKE Cluster - Region 2
# ============================================================================

resource "google_container_cluster" "region2" {
  name     = "redis-${var.region2}"
  location = var.region2

  # Use regional cluster for high availability
  node_locations = []

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.region2.name

  # Start with minimal node pool (will be replaced by managed node pool)
  remove_default_node_pool = true
  initial_node_count       = 1

  # IP allocation for pods and services
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Maintenance window
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"
    }
  }

  # Enable addons
  addons_config {
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  # Release channel
  release_channel {
    channel = "REGULAR"
  }

  resource_labels = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

resource "google_container_node_pool" "region2" {
  name       = "redis-${var.region2}-nodes"
  location   = var.region2
  cluster    = google_container_cluster.region2.name
  node_count = var.node_count

  autoscaling {
    min_node_count = var.node_min_count
    max_node_count = var.node_max_count
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 100
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      owner         = var.owner
      skip_deletion = var.skip_deletion
      cluster       = "redis-${var.region2}"
    }

    tags = ["redis-gke-node", "redis-${var.region2}"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
