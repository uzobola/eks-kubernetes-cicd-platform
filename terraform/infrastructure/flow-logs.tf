# --------------------------------------------------
# VPC Flow Logs
# --------------------------------------------------

locals {
  vpc_flow_log_group_name = "/aws/vpc/${var.project_name}/flow-logs"

  vpc_flow_log_group_arn = (
    "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.vpc_flow_log_group_name}"
  )
}


# --------------------------------------------------
# KMS - VPC Flow Logs
# --------------------------------------------------

data "aws_iam_policy_document" "vpc_flow_logs_kms" {
  #checkov:skip=CKV_AWS_356:In a KMS key policy Resource "*" refers only to the KMS key that owns the policy, per AWS KMS key-policy semantics
  #checkov:skip=CKV_AWS_109:The account-principal administration statement follows the AWS KMS default key-policy pattern and keeps the key administrable
  #checkov:skip=CKV_AWS_111:KMS key-management permissions are intentionally granted through the key's resource policy; Resource "*" is scoped to this KMS key

  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type = "AWS"

      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      ]
    }

    actions = [
      "kms:*"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogsEncryption"
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "logs.${var.aws_region}.amazonaws.com"
      ]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*"
    ]

    resources = ["*"]

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"

      values = [
        local.vpc_flow_log_group_arn
      ]
    }
  }
}

resource "aws_kms_key" "vpc_flow_logs" {
  description             = "KMS key for VPC Flow Logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.vpc_flow_logs_kms.json

  tags = {
    Name = "${var.project_name}-vpc-flow-logs"
  }
}

resource "aws_kms_alias" "vpc_flow_logs" {
  name          = "alias/${var.project_name}-vpc-flow-logs"
  target_key_id = aws_kms_key.vpc_flow_logs.key_id
}


# --------------------------------------------------
# CloudWatch Log Group
# --------------------------------------------------

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = local.vpc_flow_log_group_name
  retention_in_days = 365
  kms_key_id        = aws_kms_key.vpc_flow_logs.arn

  tags = {
    Name = "${var.project_name}-vpc-flow-logs"
  }
}


# --------------------------------------------------
# Flow Logs Service Identity
# --------------------------------------------------

data "aws_iam_policy_document" "vpc_flow_logs_assume_role" {

  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRole"
    ]

    principals {
      type = "Service"

      identifiers = [
        "vpc-flow-logs.amazonaws.com"
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"

      values = [
        data.aws_caller_identity.current.account_id
      ]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"

      values = [
        "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"
      ]
    }
  }
}

resource "aws_iam_role" "vpc_flow_logs" {
  name               = "${var.project_name}-vpc-flow-logs-role"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_logs_assume_role.json

  tags = {
    Name = "${var.project_name}-vpc-flow-logs-role"
  }
}


# --------------------------------------------------
# CloudWatch Publishing Permissions
# --------------------------------------------------

data "aws_iam_policy_document" "vpc_flow_logs_permissions" {

  statement {
    sid    = "DiscoverLogGroups"
    effect = "Allow"

    actions = [
      "logs:DescribeLogGroups"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "UseFlowLogGroup"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:DescribeLogStreams"
    ]

    resources = [
      local.vpc_flow_log_group_arn
    ]
  }

  statement {
    sid    = "WriteFlowLogStreams"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]

    resources = [
      "${local.vpc_flow_log_group_arn}:*"
    ]
  }
}

resource "aws_iam_policy" "vpc_flow_logs" {
  name   = "${var.project_name}-vpc-flow-logs-policy"
  policy = data.aws_iam_policy_document.vpc_flow_logs_permissions.json
}

resource "aws_iam_role_policy_attachment" "vpc_flow_logs" {
  role       = aws_iam_role.vpc_flow_logs.name
  policy_arn = aws_iam_policy.vpc_flow_logs.arn
}


# --------------------------------------------------
# VPC Flow Log
# --------------------------------------------------

resource "aws_flow_log" "main" {
  vpc_id = aws_vpc.main.id

  traffic_type = "ALL"

  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs.arn

  iam_role_arn = aws_iam_role.vpc_flow_logs.arn

  max_aggregation_interval = 60

  tags = {
    Name = "${var.project_name}-vpc-flow-log"
  }
}