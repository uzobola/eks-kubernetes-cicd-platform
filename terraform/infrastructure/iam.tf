# --------------------------------------------------
# EKS Control Plane Role
# --------------------------------------------------

data "aws_iam_policy_document" "eks_cluster_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "${var.project_name}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_assume_role.json

  tags = {
    Name = "${var.project_name}-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}


# --------------------------------------------------
# EKS Worker Node Role
# --------------------------------------------------

data "aws_iam_policy_document" "eks_node_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "eks_node" {
  name               = "${var.project_name}-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_assume_role.json

  tags = {
    Name = "${var.project_name}-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_node_worker" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_ecr" {
  role       = aws_iam_role.eks_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}


# --------------------------------------------------
# AWS Load Balancer Controller IAM Policy
# --------------------------------------------------

resource "aws_iam_policy" "load_balancer_controller" {
  name = "${var.project_name}-load-balancer-controller-policy"

  policy = file(
    "${path.module}/../../platform/aws-load-balancer-controller/iam_policy.json"
  )

  tags = {
    Name = "${var.project_name}-load-balancer-controller-policy"
  }
}


# --------------------------------------------------
# AWS Load Balancer Controller IRSA Trust
# --------------------------------------------------

data "aws_iam_policy_document" "load_balancer_controller_assume_role" {
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
        "system:serviceaccount:kube-system:aws-load-balancer-controller"
      ]
    }
  }
}


resource "aws_iam_role" "load_balancer_controller" {
  name = "${var.project_name}-load-balancer-controller-role"

  assume_role_policy = data.aws_iam_policy_document.load_balancer_controller_assume_role.json

  tags = {
    Name = "${var.project_name}-load-balancer-controller-role"
  }
}


resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

# --------------------------------------------------
# Cluster Autoscaler IAM Policy
# --------------------------------------------------

data "aws_iam_policy_document" "cluster_autoscaler_permissions" {
  #checkov:skip=CKV_AWS_356:AWS EKS Cluster Autoscaler least-privilege guidance uses Resource "*" with cluster-specific ownership tag conditions for scaling actions; discovery APIs require wildcard resource scope

  statement {
    sid    = "AllowScopedNodeGroupScaling"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup"
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }

  statement {
    sid    = "AllowAutoscalingDiscovery"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup"
    ]

    resources = ["*"]
  }
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name   = "${var.project_name}-cluster-autoscaler-policy"
  policy = data.aws_iam_policy_document.cluster_autoscaler_permissions.json

  tags = {
    Name = "${var.project_name}-cluster-autoscaler-policy"
  }
}

data "aws_iam_policy_document" "cluster_autoscaler_assume_role" {
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
        "system:serviceaccount:kube-system:cluster-autoscaler"
      ]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.project_name}-cluster-autoscaler-role"

  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role.json

  tags = {
    Name = "${var.project_name}-cluster-autoscaler-role"
  }
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

# --------------------------------------------------
# Jenkins EC2 Role
# --------------------------------------------------

data "aws_iam_policy_document" "jenkins_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.project_name}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.jenkins_assume_role.json

  tags = {
    Name = "${var.project_name}-jenkins-role"
  }
}


# --------------------------------------------------
# Jenkins Application Deployment Permissions
# --------------------------------------------------

data "aws_iam_policy_document" "jenkins_permissions" {

  statement {
    sid    = "AllowECRAuthentication"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowApplicationImagePush"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer"
    ]

    resources = [
      aws_ecr_repository.application.arn
    ]
  }

  statement {
    sid    = "AllowEKSClusterDiscovery"
    effect = "Allow"

    actions = [
      "eks:DescribeCluster"
    ]

    resources = [
      aws_eks_cluster.main.arn
    ]
  }
}

resource "aws_iam_policy" "jenkins" {
  name   = "${var.project_name}-jenkins-policy"
  policy = data.aws_iam_policy_document.jenkins_permissions.json

  tags = {
    Name = "${var.project_name}-jenkins-policy"
  }
}

resource "aws_iam_role_policy_attachment" "jenkins" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.jenkins.arn
}


# --------------------------------------------------
# Jenkins Systems Manager Access
# --------------------------------------------------

resource "aws_iam_role_policy_attachment" "jenkins_ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}


# --------------------------------------------------
# Jenkins EC2 Instance Profile
# --------------------------------------------------

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-instance-profile"
  role = aws_iam_role.jenkins.name
}


# --------------------------------------------------
# Jenkins EKS Authentication
# --------------------------------------------------

resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.jenkins.arn
  type          = "STANDARD"

  kubernetes_groups = [
    "jenkins-deployers"
  ]

  tags = {
    Name = "${var.project_name}-jenkins-access"
  }
}

# --------------------------------------------------
# Ansible Execution Role Trust
# --------------------------------------------------

data "aws_iam_policy_document" "ansible_execution_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "AWS"

      identifiers = [
        "arn:aws:iam::421438965568:user/grc-engineer01"
      ]
    }
  }
}

resource "aws_iam_role" "ansible_execution" {
  name               = "${var.project_name}-ansible-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ansible_execution_assume_role.json

  tags = {
    Name    = "${var.project_name}-ansible-execution-role"
    Purpose = "Configure Jenkins through Ansible and SSM"
  }
}


data "aws_iam_policy_document" "ansible_execution_permissions" {

  # ------------------------------------------------
  # Ansible temporary S3 transport bucket
  # ------------------------------------------------

  statement {
    sid    = "AllowAnsibleTransportBucketDiscovery"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [
      aws_s3_bucket.ansible_transport.arn
    ]
  }

  statement {
    sid    = "AllowAnsibleTransportObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]

    resources = [
      "${aws_s3_bucket.ansible_transport.arn}/*"
    ]
  }

  # ------------------------------------------------
  # Discover Jenkins EC2 instance for dynamic inventory
  # ------------------------------------------------

  statement {
    sid    = "AllowEC2InventoryDiscovery"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances"
    ]

    resources = ["*"]
  }

  # ------------------------------------------------
  # Start SSM sessions only against Jenkins
  # ------------------------------------------------

  statement {
    sid    = "AllowJenkinsSSMSession"
    effect = "Allow"

    actions = [
      "ssm:StartSession"
    ]

    resources = [
      aws_instance.jenkins.arn,
      "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:document/SSM-SessionManagerRunShell",
      "arn:aws:ssm:${var.aws_region}::document/AWS-StartPortForwardingSession"
    ]
  }

  # ------------------------------------------------
  # Open the Session Manager data channel
  # ------------------------------------------------

  statement {
    sid    = "AllowSessionDataChannel"
    effect = "Allow"

    actions = [
      "ssmmessages:OpenDataChannel"
    ]

    resources = [
      "arn:aws:ssm:*:*:session/$${aws:userid}-*"
    ]
  }

  # ------------------------------------------------
  # Manage only sessions created by this identity
  # ------------------------------------------------

  statement {
    sid    = "AllowSessionLifecycle"
    effect = "Allow"

    actions = [
      "ssm:ResumeSession",
      "ssm:TerminateSession"
    ]

    resources = [
      "arn:aws:ssm:*:*:session/$${aws:userid}-*"
    ]
  }

  # ------------------------------------------------
  # Read SSM connection state
  # ------------------------------------------------

  statement {
    sid    = "AllowSSMInstanceDiscovery"
    effect = "Allow"

    actions = [
      "ssm:DescribeInstanceInformation"
    ]

    # AWS does not support resource-level permissions for this action.
    resources = ["*"]
  }

  statement {
    sid    = "AllowJenkinsConnectionStatus"
    effect = "Allow"

    actions = [
      "ssm:GetConnectionStatus"
    ]

    resources = [
      aws_instance.jenkins.arn
    ]
  }
}

resource "aws_iam_policy" "ansible_execution" {
  name   = "${var.project_name}-ansible-execution-policy"
  policy = data.aws_iam_policy_document.ansible_execution_permissions.json

  tags = {
    Name = "${var.project_name}-ansible-execution-policy"
  }
}

resource "aws_iam_role_policy_attachment" "ansible_execution" {
  role       = aws_iam_role.ansible_execution.name
  policy_arn = aws_iam_policy.ansible_execution.arn
}



