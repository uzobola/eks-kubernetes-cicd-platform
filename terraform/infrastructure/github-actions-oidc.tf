# --------------------------------------------------
# GitHub Actions OIDC Provider
# --------------------------------------------------

data "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"
}


# --------------------------------------------------
# GitHub Actions OIDC Trust
# Only the gitops branch of this exact repository
# may assume the role.
# --------------------------------------------------

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        data.aws_iam_openid_connect_provider.github_actions.arn
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"

      values = [
        "repo:uzobola@173111719/eks-kubernetes-cicd-platform@1333767654:ref:refs/heads/gitops"
      ]
    }
  }
}


# --------------------------------------------------
# GitHub Actions Role
# --------------------------------------------------

resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions-role"

  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

  tags = {
    Name    = "${var.project_name}-github-actions-role"
    Purpose = "Build and publish GitOps application images"
  }
}


# --------------------------------------------------
# GitHub Actions Permissions
# Build pipeline may publish images to one ECR repo.
# It receives no EKS deployment authority.
# --------------------------------------------------

data "aws_iam_policy_document" "github_actions_permissions" {

  statement {
    sid    = "AllowECRAuthentication"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowApplicationImagePublishing"
    effect = "Allow"

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages"
    ]

    resources = [
      aws_ecr_repository.application.arn
    ]
  }
}


resource "aws_iam_policy" "github_actions" {
  name   = "${var.project_name}-github-actions-policy"
  policy = data.aws_iam_policy_document.github_actions_permissions.json

  tags = {
    Name = "${var.project_name}-github-actions-policy"
  }
}


resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}