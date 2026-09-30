terraform {
  required_version = ">= 1.5"

  # Task 2: remote state backend.
  # Config is in backend.hcl — init with:  terraform init -backend-config=backend.hcl
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Latest Amazon Linux 2023 AMI (x86_64) ───────────────────────────────────
# Using a data source avoids hardcoding a region-specific AMI ID in tfvars.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── VPC — public subnet only, no NAT gateway ────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Group ───────────────────────────────────────────────────────────
# Restrict ssh_allowed_cidr to your IP in production; 0.0.0.0/0 is for testing only.

resource "aws_security_group" "instances" {
  name        = "${var.project}-instances"
  description = "SSH inbound + unrestricted outbound for test fleet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-sg" }
}

# ── EC2 fleet (Task 1) ───────────────────────────────────────────────────────

module "ec2_fleet" {
  source = "./modules/ec2-multi-instance"

  ami                = data.aws_ami.al2023.id
  instances          = var.instances
  protected_instance = "db-server" # see NOTES.md
  subnet_id          = aws_subnet.public.id
  security_group_ids = [aws_security_group.instances.id]
  environment        = var.environment
  owner              = var.owner
}
