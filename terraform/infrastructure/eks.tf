# --------------------------------------------------
# EKS Control Plane
# Private-subnet placement; API reachable privately always,
# and publicly only from admin_cidr. Access entries (API mode)
# replace the older aws-auth ConfigMap for IAM->Kubernetes auth.
# --------------------------------------------------

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = "1.35"

  access_config {
    # API authentication mode: grant access via EKS access entries/policies.
    # Do not auto-grant the creator cluster-admin; we assign that explicitly below.
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    # Workers and the control plane ENIs live in private subnets only.
    subnet_ids = [
      aws_subnet.private_a.id,
      aws_subnet.private_b.id
    ]

    endpoint_private_access = true
    endpoint_public_access  = true

    # Lock down the public API to the operator/admin CIDR (e.g. office/VPN).
    public_access_cidrs = [
      var.admin_cidr
    ]
  }

  # Ship control-plane logs to CloudWatch for audit/troubleshooting.
  enabled_cluster_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  # Ensure the cluster service-linked IAM policy is attached before create.
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster
  ]

  tags = {
    Name = var.cluster_name
  }
}

# --------------------------------------------------
# Cluster Admin Access (EKS Access Entries)
# Grants a stable IAM principal (CI/break-glass role) cluster-admin
# without relying on the cluster creator's identity.
# --------------------------------------------------

resource "aws_eks_access_entry" "terraform_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.terraform_admin_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "terraform_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.terraform_admin_principal_arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [
    aws_eks_access_entry.terraform_admin
  ]
}

# --------------------------------------------------
# IRSA (IAM Roles for Service Accounts)
# OIDC provider lets Kubernetes service accounts assume IAM roles
# (used here for the VPC CNI addon).
# --------------------------------------------------

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # Trust the cluster OIDC issuer's certificate thumbprint.
  thumbprint_list = [
    data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint
  ]

  tags = {
    Name = "${var.project_name}-oidc"
  }
}

# Trust policy: only the aws-node SA in kube-system may assume this role.
data "aws_iam_policy_document" "vpc_cni_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.eks.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")}:sub"

      values = [
        "system:serviceaccount:kube-system:aws-node"
      ]
    }
  }
}

# --------------------------------------------------
# VPC CNI Addon (IRSA)
# Manages pod networking (ENIs/IPs). Runs as aws-node with a
# dedicated IAM role instead of the broader node instance role.
# --------------------------------------------------

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.project_name}-vpc-cni-role"
  assume_role_policy = data.aws_iam_policy_document.vpc_cni_assume_role.json

  tags = {
    Name = "${var.project_name}-vpc-cni-role"
  }
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  service_account_role_arn = aws_iam_role.vpc_cni.arn

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni
  ]
}

# --------------------------------------------------
# Managed Node Group
# On-demand workers in private subnets. desired_size is ignored
# after create so cluster autoscaler (or manual scale) can own it.
# VPC CNI must be ready before nodes join.
# --------------------------------------------------

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.eks_node.arn

  subnet_ids = [
    aws_subnet.private_a.id,
    aws_subnet.private_b.id
  ]

  instance_types = [
    "t3.small"
  ]

  capacity_type = "ON_DEMAND"

  scaling_config {
    min_size     = 1
    desired_size = 1
    max_size     = 4
  }

  # Allow one node to be unavailable during rolling updates.
  update_config {
    max_unavailable = 1
  }

  labels = {
    workload = "challenge-app"
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_node_worker,
    aws_iam_role_policy_attachment.eks_node_ecr,
    aws_eks_addon.vpc_cni
  ]

  lifecycle {
    ignore_changes = [
      scaling_config[0].desired_size
    ]
  }

  tags = {
    Name = "${var.project_name}-nodes"
  }
}
