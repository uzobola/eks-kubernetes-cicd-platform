# --------------------------------------------------
# Latest Amazon Linux 2023 AMI
# --------------------------------------------------

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name = "name"

    values = [
      "al2023-ami-2023.*-x86_64"
    ]
  }

  filter {
    name = "architecture"

    values = [
      "x86_64"
    ]
  }

  filter {
    name = "virtualization-type"

    values = [
      "hvm"
    ]
  }

  filter {
    name = "root-device-type"

    values = [
      "ebs"
    ]
  }
}


# --------------------------------------------------
# Jenkins Security Group
# --------------------------------------------------

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Jenkins controller security group"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-jenkins-sg"
  }
}


# Jenkins UI - administrator IP only
resource "aws_vpc_security_group_ingress_rule" "jenkins_ui" {
  security_group_id = aws_security_group.jenkins.id

  description = "Jenkins UI from administrator IP"

  cidr_ipv4   = var.admin_cidr
  from_port   = 8080
  to_port     = 8080
  ip_protocol = "tcp"
}


# Outbound access for package installation, AWS APIs,
# ECR, GitHub, EKS, etc.
resource "aws_vpc_security_group_egress_rule" "jenkins_egress" {
  security_group_id = aws_security_group.jenkins.id

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}


# --------------------------------------------------
# Jenkins EC2
# --------------------------------------------------

resource "aws_instance" "jenkins" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "c7i-flex.large"

  subnet_id = aws_subnet.public_a.id

  associate_public_ip_address = true

  vpc_security_group_ids = [
    aws_security_group.jenkins.id
  ]

  iam_instance_profile = aws_iam_instance_profile.jenkins.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-jenkins"
    Role = "jenkins"
  }

  depends_on = [
    aws_iam_role_policy_attachment.jenkins,
    aws_iam_role_policy_attachment.jenkins_ssm
  ]
}