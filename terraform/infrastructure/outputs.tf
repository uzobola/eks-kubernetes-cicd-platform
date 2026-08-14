output "vpc_id" {
  description = "Project VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value = [
    aws_subnet.public_a.id,
    aws_subnet.public_b.id
  ]
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]
}

output "ecr_repository_url" {
  description = "Application ECR repository URL"
  value       = aws_ecr_repository.application.repository_url
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS Kubernetes API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_node_role_arn" {
  description = "IAM role used by EKS worker nodes"
  value       = aws_iam_role.eks_node.arn
}

output "vpc_cni_role_arn" {
  description = "Dedicated IAM role used by the VPC CNI"
  value       = aws_iam_role.vpc_cni.arn
}