# --------------------------------------------------
# Ansible SSM Transport Bucket
# --------------------------------------------------

data "aws_caller_identity" "current" {}

locals {
  ansible_transport_bucket_name = "${var.project_name}-ansible-transport-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

resource "aws_s3_bucket" "ansible_transport" {
  #checkov:skip=CKV_AWS_145:Temporary Ansible SSM transport objects are encrypted with SSE-S3/AES256; SSE-KMS is a production policy option rather than a functional requirement
  #checkov:skip=CKV_AWS_18:Ephemeral one-day transport bucket does not use a dedicated persistent S3 access-log bucket in this challenge environment
  #checkov:skip=CKV2_AWS_62:Temporary Ansible transport objects have no event-driven consumer requiring S3 notifications
  #checkov:skip=CKV_AWS_21:Ansible aws_ssm documentation recommends versioning remain disabled because deleted transport files may contain secrets and persist in version history
  #checkov:skip=CKV_AWS_144:Cross-region replication conflicts with the ephemeral minimal-copy design of the temporary Ansible transport bucket

  bucket        = local.ansible_transport_bucket_name
  force_destroy = true

  tags = {
    Name    = "${var.project_name}-ansible-transport"
    Purpose = "Ansible SSM temporary file transport"
  }
}


# --------------------------------------------------
# Disable ACL-based ownership
# --------------------------------------------------

resource "aws_s3_bucket_ownership_controls" "ansible_transport" {
  bucket = aws_s3_bucket.ansible_transport.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}


# --------------------------------------------------
# Block Public Access
# --------------------------------------------------

resource "aws_s3_bucket_public_access_block" "ansible_transport" {
  bucket = aws_s3_bucket.ansible_transport.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# --------------------------------------------------
# Server-Side Encryption
# --------------------------------------------------

resource "aws_s3_bucket_server_side_encryption_configuration" "ansible_transport" {
  bucket = aws_s3_bucket.ansible_transport.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# --------------------------------------------------
# Delete abandoned temporary objects
# --------------------------------------------------

resource "aws_s3_bucket_lifecycle_configuration" "ansible_transport" {
  bucket = aws_s3_bucket.ansible_transport.id

  rule {
    id     = "expire-ansible-transport-files"
    status = "Enabled"

    filter {}

    expiration {
      days = 1
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}


# --------------------------------------------------
# Require TLS
# --------------------------------------------------

resource "aws_s3_bucket_policy" "ansible_transport_tls_only" {
  bucket = aws_s3_bucket.ansible_transport.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"

        Action = "s3:*"

        Resource = [
          aws_s3_bucket.ansible_transport.arn,
          "${aws_s3_bucket.ansible_transport.arn}/*"
        ]

        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [
    aws_s3_bucket_public_access_block.ansible_transport
  ]
}