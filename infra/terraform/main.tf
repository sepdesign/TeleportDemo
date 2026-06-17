# Latest Ubuntu 22.04 LTS image from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# SSH key pair generated locally so the build is self contained
resource "tls_private_key" "node" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "node" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.node.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.node.private_key_pem
  filename        = "${path.module}/${var.project}-key.pem"
  file_permission = "0400"
}

# Network
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc", Project = var.project }
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-subnet", Project = var.project }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw", Project = var.project }
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-rt", Project = var.project }
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

# Security group. One group for all nodes.
resource "aws_security_group" "cluster" {
  name        = "${var.project}-sg"
  description = "Kubeadm cluster traffic"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project}-sg", Project = var.project }
}

# All traffic between cluster members. Source is the group itself.
resource "aws_security_group_rule" "internal" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.cluster.id
  description       = "All traffic between cluster nodes"
}

resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr]
  security_group_id = aws_security_group.cluster.id
  description       = "SSH from my IP"
}

resource "aws_security_group_rule" "api" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip_cidr]
  security_group_id = aws_security_group.cluster.id
  description       = "Kubernetes API from my IP"
}

resource "aws_security_group_rule" "http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
  description       = "HTTP for the site and the ACME challenge"
}

resource "aws_security_group_rule" "https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
  description       = "HTTPS for the site"
}

resource "aws_security_group_rule" "egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.cluster.id
  description       = "All outbound"
}

# Node prep runs once at first boot
locals {
  node_prep = file("${path.module}/../scripts/node-prep.sh")
}

resource "aws_instance" "cp" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.cp_instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.node.key_name
  user_data              = local.node_prep

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-cp", Project = var.project, Role = "control-plane" }
}

resource "aws_instance" "worker" {
  count                  = 2
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.worker_instance_type
  subnet_id              = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.cluster.id]
  key_name               = aws_key_pair.node.key_name
  user_data              = local.node_prep

  root_block_device {
    volume_size = var.root_volume_gb
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-worker-${count.index + 1}", Project = var.project, Role = "worker" }
}

# Elastic IPs. The control plane gets one for a stable API endpoint.
# Worker 1 gets one for ingress and DNS.
resource "aws_eip" "cp" {
  domain   = "vpc"
  instance = aws_instance.cp.id
  tags     = { Name = "${var.project}-cp-eip", Project = var.project }
}

resource "aws_eip" "ingress" {
  domain   = "vpc"
  instance = aws_instance.worker[0].id
  tags     = { Name = "${var.project}-ingress-eip", Project = var.project }
}
