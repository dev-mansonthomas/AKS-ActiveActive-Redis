terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.4"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "rg" {
  location = var.region1
  name     = var.azure_rg

  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

resource "azurerm_kubernetes_cluster" "k8s1" {
  location            = var.region1
  name                = "${var.cluster_prefix}-${var.region1}"
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.dns_prefix

  identity {
    type = "SystemAssigned"
  }

  # Required from azurerm 5.x. "Manual" preserves the explicit default_node_pool
  # below (as opposed to "Auto" = AKS Node Auto Provisioning / Karpenter).
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name    = "agentpool"
    vm_size = var.instance_type
    # node_count is the TOTAL; `zones` spreads it one-per-zone.
    node_count = var.node_count
    zones      = var.zones
  }

  network_profile {
    network_plugin    = var.network_plugin
    load_balancer_sku = var.load_balancer_sku
  }

  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

resource "azurerm_kubernetes_cluster" "k8s2" {
  location            = var.region2
  name                = "${var.cluster_prefix}-${var.region2}"
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = var.dns_prefix

  identity {
    type = "SystemAssigned"
  }

  # Required from azurerm 5.x. "Manual" preserves the explicit default_node_pool
  # below (as opposed to "Auto" = AKS Node Auto Provisioning / Karpenter).
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name    = "agentpool"
    vm_size = var.instance_type
    # node_count is the TOTAL; `zones` spreads it one-per-zone.
    node_count = var.node_count
    zones      = var.zones
  }

  network_profile {
    network_plugin    = var.network_plugin
    load_balancer_sku = var.load_balancer_sku
  }

  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}
