variable "aws_region" {
  description = "AWS region for the project"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project identifier"
  type        = string
  default     = "eks-kubernetes-cicd"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "eks-kubernetes-cicd-cluster"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.20.0.0/16"
}