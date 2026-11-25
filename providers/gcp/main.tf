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
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.1"
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
    project_name  = "${var.cluster_prefix}-enterprise-aa"
  }
}

# ============================================================================
# VPC Network (Global in GCP)
# ============================================================================

resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_prefix}-vpc"
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  description = "VPC for Redis Enterprise Active/Active deployment"
}

# ============================================================================
# Subnets for Region 1
# ============================================================================

resource "google_compute_subnetwork" "region1" {
  name          = "${var.cluster_prefix}-subnet-${var.region1}"
  ip_cidr_range = var.subnet_cidr1
  region        = var.region1
  network       = google_compute_network.vpc.id

  # Secondary IP ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr1
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr1
  }

  description = "Subnet for GKE cluster in ${var.region1}"
}

# ============================================================================
# Subnets for Region 2
# ============================================================================

resource "google_compute_subnetwork" "region2" {
  name          = "${var.cluster_prefix}-subnet-${var.region2}"
  ip_cidr_range = var.subnet_cidr2
  region        = var.region2
  network       = google_compute_network.vpc.id

  # Secondary IP ranges for GKE pods and services
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr2
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr2
  }

  description = "Subnet for GKE cluster in ${var.region2}"
}

# ============================================================================
# Firewall Rules
# ============================================================================

resource "google_compute_firewall" "allow_internal" {
  name    = "${var.cluster_prefix}-allow-internal"
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
  name    = "${var.cluster_prefix}-allow-redis-ports"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = var.redis_ports
  }

  source_ranges = ["0.0.0.0/0"]
  description   = "Allow Redis Enterprise ports"
}

# ============================================================================
# GKE Cluster - Region 1
# ============================================================================

resource "google_container_cluster" "region1" {
  name     = "${var.cluster_prefix}-${var.region1}"
  location = var.region1

  # Regional cluster, with the zone spread stated explicitly rather than left
  # to GKE's default. One Redis Enterprise node lands per zone.
  node_locations = var.zones1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.region1.name

  # GKE always creates a default node pool; we throw it away and attach the
  # managed one below. initial_node_count MUST be > 0 or the API rejects the
  # cluster with 400 "initial_node_count must be greater than zero".
  remove_default_node_pool = true
  initial_node_count       = var.initial_node_count
  # Deliberately NOT configurable. The google provider defaults this to true
  # since v6.0, which makes `tofu destroy` fail with:
  #   "Cannot destroy cluster because deletion_protection is set to true"
  # This rig is a disposable demo whose premise is one command up, one command
  # down (docs/product/PRD.md P2/P4), so protection here would break the
  # product. Exposing it in config.sh would only invite someone to set it true
  # and lose the ability to tear down.
  deletion_protection = false


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
    channel = var.release_channel
  }

  resource_labels = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }

  timeouts {
    create = var.cluster_timeout
    update = var.cluster_timeout
    delete = var.cluster_timeout
  }
}

resource "google_container_node_pool" "region1" {
  name       = "${var.cluster_prefix}-${var.region1}-nodes"
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
      cluster       = "${var.cluster_prefix}-${var.region1}"
    }

    tags = ["${var.cluster_prefix}-gke-node", "${var.cluster_prefix}-${var.region1}"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  timeouts {
    create = var.node_pool_timeout
    update = var.node_pool_timeout
    delete = var.node_pool_timeout
  }
}

# ============================================================================
# GKE Cluster - Region 2
# ============================================================================

resource "google_container_cluster" "region2" {
  name     = "${var.cluster_prefix}-${var.region2}"
  location = var.region2

  # Regional cluster, with the zone spread stated explicitly.
  node_locations = var.zones2

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.region2.name

  # Start with minimal node pool (will be replaced by managed node pool)
  remove_default_node_pool = true
  initial_node_count       = var.initial_node_count
  # Deliberately NOT configurable. The google provider defaults this to true
  # since v6.0, which makes `tofu destroy` fail with:
  #   "Cannot destroy cluster because deletion_protection is set to true"
  # This rig is a disposable demo whose premise is one command up, one command
  # down (docs/product/PRD.md P2/P4), so protection here would break the
  # product. Exposing it in config.sh would only invite someone to set it true
  # and lose the ability to tear down.
  deletion_protection = false

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
    channel = var.release_channel
  }

  resource_labels = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }

  timeouts {
    create = var.cluster_timeout
    update = var.cluster_timeout
    delete = var.cluster_timeout
  }
}

resource "google_container_node_pool" "region2" {
  name       = "${var.cluster_prefix}-${var.region2}-nodes"
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
      cluster       = "${var.cluster_prefix}-${var.region2}"
    }

    tags = ["${var.cluster_prefix}-gke-node", "${var.cluster_prefix}-${var.region2}"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  timeouts {
    create = var.node_pool_timeout
    update = var.node_pool_timeout
    delete = var.node_pool_timeout
  }
}
