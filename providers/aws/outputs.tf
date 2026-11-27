# ============================================================================
# AWS EKS Outputs
# ============================================================================
# Output values for EKS clusters and networking
# ============================================================================

# Region 1 Outputs
# ============================================================================

output "region1_cluster_id" {
  description = "EKS cluster ID for region 1"
  value       = aws_eks_cluster.region1.id
}

output "region1_cluster_endpoint" {
  description = "EKS cluster endpoint for region 1"
  value       = aws_eks_cluster.region1.endpoint
}

output "region1_cluster_name" {
  description = "EKS cluster name for region 1"
  value       = aws_eks_cluster.region1.name
}

output "region1_cluster_arn" {
  description = "EKS cluster ARN for region 1"
  value       = aws_eks_cluster.region1.arn
}

output "region1_vpc_id" {
  description = "VPC ID for region 1"
  value       = aws_vpc.region1.id
}

# Region 2 Outputs
# ============================================================================

output "region2_cluster_id" {
  description = "EKS cluster ID for region 2"
  value       = aws_eks_cluster.region2.id
}

output "region2_cluster_endpoint" {
  description = "EKS cluster endpoint for region 2"
  value       = aws_eks_cluster.region2.endpoint
}

output "region2_cluster_name" {
  description = "EKS cluster name for region 2"
  value       = aws_eks_cluster.region2.name
}

output "region2_cluster_arn" {
  description = "EKS cluster ARN for region 2"
  value       = aws_eks_cluster.region2.arn
}

output "region2_vpc_id" {
  description = "VPC ID for region 2"
  value       = aws_vpc.region2.id
}

# IAM Outputs
# ============================================================================

output "eks_cluster_role_arn" {
  description = "IAM role ARN for EKS clusters"
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_role_arn" {
  description = "IAM role ARN for EKS node groups"
  value       = aws_iam_role.eks_nodes.arn
}

# Summary Output
# ============================================================================

output "deployment_summary" {
  description = "Summary of the AWS deployment"
  value = {
    region1 = {
      name     = aws_eks_cluster.region1.name
      region   = var.region1
      endpoint = aws_eks_cluster.region1.endpoint
      version  = aws_eks_cluster.region1.version
    }
    region2 = {
      name     = aws_eks_cluster.region2.name
      region   = var.region2
      endpoint = aws_eks_cluster.region2.endpoint
      version  = aws_eks_cluster.region2.version
    }
    tags = {
      owner         = var.owner
      skip_deletion = var.skip_deletion
    }
  }
}
