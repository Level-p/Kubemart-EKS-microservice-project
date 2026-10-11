# VPC with 3 public and 3 private subnets across 3 Availability Zones.
# EKS worker nodes live in the private subnets; ALBs live in the public subnets.

resource "aws_vpc" "vpc" {
  cidr_block           = var.cidr
  instance_tenancy     = "default"
  enable_dns_support   = true
  enable_dns_hostnames = true # required by EKS

  tags = {
    Name = "${var.name}-vpc"
  }
}

resource "aws_subnet" "public_subs" {
  for_each                = var.public_subnets
  vpc_id                  = aws_vpc.vpc.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name}-${each.key}"
    # The AWS Load Balancer Controller places internet-facing ALBs here
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_subs" {
  for_each          = var.private_subnets
  vpc_id            = aws_vpc.vpc.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "${var.name}-${each.key}"
    # Internal load balancers go here
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "${var.name}-igw" }
}

# Elastic IP for the NAT Gateway
resource "aws_eip" "eip" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat-eip" }
}

# NAT Gateway: lets private nodes pull images (ECR, Docker Hub) and reach AWS APIs
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.eip.id
  subnet_id     = aws_subnet.public_subs["pub1"].id
  tags          = { Name = "${var.name}-nat-gw" }

  depends_on = [aws_internet_gateway.igw]
}

# Route tables
resource "aws_route_table" "public-rt" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block = var.all_cidr
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.name}-pub-rt" }
}

resource "aws_route_table" "private-rt" {
  vpc_id = aws_vpc.vpc.id
  route {
    cidr_block     = var.all_cidr
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.name}-pri-rt" }
}

# Associations (public + private)
resource "aws_route_table_association" "public-RTA" {
  for_each       = aws_subnet.public_subs
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public-rt.id
}

resource "aws_route_table_association" "private-RTA" {
  for_each       = aws_subnet.private_subs
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private-rt.id
}
