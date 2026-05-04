# ============================================================================
# AWS EKS Infrastructure for Redis Enterprise Active/Active
# ============================================================================
# This Terraform configuration creates:
# - VPC with subnets across 2 availability zones
# - 2 EKS clusters in different regions
# - Node groups with auto-scaling
# - All resources tagged with owner and skip_deletion
# ============================================================================

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ============================================================================
# Provider Configuration for Region 1
# ============================================================================

provider "aws" {
  alias  = "region1"
  region = var.region1

  default_tags {
    tags = {
      owner         = var.owner
      skip_deletion = var.skip_deletion
      ManagedBy     = "Terraform"
      Project       = "RedisEnterpriseAA"
    }
  }
}

# ============================================================================
# Provider Configuration for Region 2
# ============================================================================

provider "aws" {
  alias  = "region2"
  region = var.region2

  default_tags {
    tags = {
      owner         = var.owner
      skip_deletion = var.skip_deletion
      ManagedBy     = "Terraform"
      Project       = "RedisEnterpriseAA"
    }
  }
}

# ============================================================================
# Data Sources
# ============================================================================

data "aws_availability_zones" "region1_azs" {
  provider = aws.region1
  state    = "available"
}

data "aws_availability_zones" "region2_azs" {
  provider = aws.region2
  state    = "available"
}

# ============================================================================
# VPC for Region 1
# ============================================================================

resource "aws_vpc" "region1" {
  provider             = aws.region1
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "redis-vpc-${var.region1}"
  }
}

resource "aws_subnet" "region1_public" {
  provider                = aws.region1
  count                   = 2
  vpc_id                  = aws_vpc.region1.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.region1_azs.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "redis-public-${var.region1}-${count.index + 1}"
    "kubernetes.io/role/elb"                   = "1"
    "kubernetes.io/cluster/redis-${var.region1}" = "shared"
  }
}

resource "aws_subnet" "region1_private" {
  provider          = aws.region1
  count             = 2
  vpc_id            = aws_vpc.region1.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.region1_azs.names[count.index]

  tags = {
    Name                                        = "redis-private-${var.region1}-${count.index + 1}"
    "kubernetes.io/role/internal-elb"          = "1"
    "kubernetes.io/cluster/redis-${var.region1}" = "shared"
  }
}

resource "aws_internet_gateway" "region1" {
  provider = aws.region1
  vpc_id   = aws_vpc.region1.id

  tags = {
    Name = "redis-igw-${var.region1}"
  }
}

resource "aws_route_table" "region1_public" {
  provider = aws.region1
  vpc_id   = aws_vpc.region1.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.region1.id
  }

  tags = {
    Name = "redis-public-rt-${var.region1}"
  }
}

resource "aws_route_table_association" "region1_public" {
  provider       = aws.region1
  count          = 2
  subnet_id      = aws_subnet.region1_public[count.index].id
  route_table_id = aws_route_table.region1_public.id
}

# ============================================================================
# VPC for Region 2
# ============================================================================

resource "aws_vpc" "region2" {
  provider             = aws.region2
  cidr_block           = "10.1.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "redis-vpc-${var.region2}"
  }
}

resource "aws_subnet" "region2_public" {
  provider                = aws.region2
  count                   = 2
  vpc_id                  = aws_vpc.region2.id
  cidr_block              = "10.1.${count.index}.0/24"
  availability_zone       = data.aws_availability_zones.region2_azs.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "redis-public-${var.region2}-${count.index + 1}"
    "kubernetes.io/role/elb"                   = "1"
    "kubernetes.io/cluster/redis-${var.region2}" = "shared"
  }
}

resource "aws_subnet" "region2_private" {
  provider          = aws.region2
  count             = 2
  vpc_id            = aws_vpc.region2.id
  cidr_block        = "10.1.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.region2_azs.names[count.index]

  tags = {
    Name                                        = "redis-private-${var.region2}-${count.index + 1}"
    "kubernetes.io/role/internal-elb"          = "1"
    "kubernetes.io/cluster/redis-${var.region2}" = "shared"
  }
}

resource "aws_internet_gateway" "region2" {
  provider = aws.region2
  vpc_id   = aws_vpc.region2.id

  tags = {
    Name = "redis-igw-${var.region2}"
  }
}

resource "aws_route_table" "region2_public" {
  provider = aws.region2
  vpc_id   = aws_vpc.region2.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.region2.id
  }

  tags = {
    Name = "redis-public-rt-${var.region2}"
  }
}

resource "aws_route_table_association" "region2_public" {
  provider       = aws.region2
  count          = 2
  subnet_id      = aws_subnet.region2_public[count.index].id
  route_table_id = aws_route_table.region2_public.id
}

# ============================================================================
# IAM Role for EKS Clusters
# ============================================================================

resource "aws_iam_role" "eks_cluster" {
  name = "redis-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })

  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

# ============================================================================
# IAM Role for EKS Node Groups
# ============================================================================

resource "aws_iam_role" "eks_nodes" {
  name = "redis-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    owner         = var.owner
    skip_deletion = var.skip_deletion
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}


# ============================================================================
# EKS Cluster - Region 1
# ============================================================================

resource "aws_eks_cluster" "region1" {
  provider = aws.region1
  name     = "redis-${var.region1}"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.29"

  vpc_config {
    subnet_ids              = concat(aws_subnet.region1_public[*].id, aws_subnet.region1_private[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]

  tags = {
    Name = "redis-${var.region1}"
  }
}

resource "aws_eks_node_group" "region1" {
  provider        = aws.region1
  cluster_name    = aws_eks_cluster.region1.name
  node_group_name = "redis-${var.region1}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.region1_private[*].id

  scaling_config {
    desired_size = 3
    max_size     = 5
    min_size     = 2
  }

  instance_types = ["t3.xlarge"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]

  tags = {
    Name = "redis-${var.region1}-nodes"
  }
}

# ============================================================================
# EKS Cluster - Region 2
# ============================================================================

resource "aws_eks_cluster" "region2" {
  provider = aws.region2
  name     = "redis-${var.region2}"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.29"

  vpc_config {
    subnet_ids              = concat(aws_subnet.region2_public[*].id, aws_subnet.region2_private[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
  ]

  tags = {
    Name = "redis-${var.region2}"
  }
}

resource "aws_eks_node_group" "region2" {
  provider        = aws.region2
  cluster_name    = aws_eks_cluster.region2.name
  node_group_name = "redis-${var.region2}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.region2_private[*].id

  scaling_config {
    desired_size = 3
    max_size     = 5
    min_size     = 2
  }

  instance_types = ["t3.xlarge"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
  ]

  tags = {
    Name = "redis-${var.region2}-nodes"
  }
}
