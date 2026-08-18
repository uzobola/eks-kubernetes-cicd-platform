resource "aws_ecr_repository" "application" {
  #checkov:skip=CKV_AWS_136:Repository is encrypted at rest with AES256/SSE-S3; KMS would require repository replacement and is recorded as the production hardening direction
  name                 = "${var.project_name}-app"
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "${var.project_name}-app"
  }
}