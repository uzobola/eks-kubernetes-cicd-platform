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

output "load_balancer_controller_role_arn" {
  description = "IAM role used by AWS Load Balancer Controller"
  value       = aws_iam_role.load_balancer_controller.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role used by Kubernetes Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "jenkins_role_arn" {
  description = "IAM role used by Jenkins"
  value       = aws_iam_role.jenkins.arn
}

output "jenkins_instance_id" {
  description = "Jenkins EC2 instance ID"
  value       = aws_instance.jenkins.id
}

output "jenkins_public_ip" {
  description = "Jenkins public IPv4 address"
  value       = aws_instance.jenkins.public_ip
}

output "jenkins_private_ip" {
  description = "Jenkins private IPv4 address"
  value       = aws_instance.jenkins.private_ip
}

output "jenkins_url" {
  description = "Jenkins administration URL"
  value       = "http://${aws_instance.jenkins.public_ip}:8080"
}

output "ansible_transport_bucket_name" {
  description = "S3 bucket used for temporary Ansible SSM file transport"
  value       = aws_s3_bucket.ansible_transport.bucket
}

output "ansible_execution_role_arn" {
  description = "IAM role assumed by the Ansible controller"
  value       = aws_iam_role.ansible_execution.arn
}