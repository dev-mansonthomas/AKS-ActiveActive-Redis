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
  name                = "redis-${var.region1}"
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "redis"

  identity {
    type = "SystemAssigned"
  }

  # Required from azurerm 5.x. "Manual" preserves the explicit default_node_pool
  # below (as opposed to "Auto" = AKS Node Auto Provisioning / Karpenter).
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name       = "agentpool"
    vm_size    = var.instance_type
    node_count = 3
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

resource "azurerm_kubernetes_cluster" "k8s2" {
  location            = var.region2
  name                = "redis-${var.region2}"
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "redis"

  identity {
    type = "SystemAssigned"
  }

  # Required from azurerm 5.x. "Manual" preserves the explicit default_node_pool
  # below (as opposed to "Auto" = AKS Node Auto Provisioning / Karpenter).
  node_provisioning_profile {
    mode = "Manual"
  }

  default_node_pool {
    name       = "agentpool"
    vm_size    = var.instance_type
    node_count = 3
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}
