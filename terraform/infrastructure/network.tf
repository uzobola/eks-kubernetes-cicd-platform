data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  az_a = data.aws_availability_zones.available.names[0]
  az_b = data.aws_availability_zones.available.names[1]
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# --------------------------------------------------
# Public Subnets
# --------------------------------------------------

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.0.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.project_name}-public-a"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = local.az_b
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.project_name}-public-b"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --------------------------------------------------
# Private Subnets
# --------------------------------------------------

resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.10.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.project_name}-private-a"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.11.0/24"
  availability_zone       = local.az_b
  map_public_ip_on_launch = false

  tags = {
    Name                                        = "${var.project_name}-private-b"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# --------------------------------------------------
# Public Route Table
# --------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# --------------------------------------------------
# NAT Gateway - AZ A
# --------------------------------------------------

resource "aws_eip" "nat_a" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-a-eip"
  }
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id

  depends_on = [
    aws_internet_gateway.main
  ]

  tags = {
    Name = "${var.project_name}-nat-a"
  }
}

# --------------------------------------------------
# NAT Gateway - AZ B
# --------------------------------------------------

resource "aws_eip" "nat_b" {
  domain = "vpc"

  tags = {
    Name = "${var.project_name}-nat-b-eip"
  }
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id

  depends_on = [
    aws_internet_gateway.main
  ]

  tags = {
    Name = "${var.project_name}-nat-b"
  }
}

# --------------------------------------------------
# Private Route Table - AZ A
# --------------------------------------------------

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.a.id
  }

  tags = {
    Name = "${var.project_name}-private-a-rt"
  }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

# --------------------------------------------------
# Private Route Table - AZ B
# --------------------------------------------------

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.b.id
  }

  tags = {
    Name = "${var.project_name}-private-b-rt"
  }
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

# --------------------------------------------------
# Default Security Group
# --------------------------------------------------
# The platform uses explicitly managed security groups.
# The VPC default security group permits no ingress or egress.

resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id

  ingress = []
  egress  = []

  tags = {
    Name = "${var.project_name}-default-sg-restricted"
  }
}