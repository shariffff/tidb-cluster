terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Optional dedicated network. When var.create_network is true these build a VPC
# with a single public subnet wired to an internet gateway; otherwise the stack
# uses the existing var.vpc_id / var.subnet_id. local.vpc_id and local.subnet_id
# resolve to whichever is in effect and are used everywhere below.
resource "aws_vpc" "tidb" {
  count                = var.create_network ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "tidb-cluster-vpc" }
}

resource "aws_internet_gateway" "tidb" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.tidb[0].id

  tags = { Name = "tidb-cluster-igw" }
}

resource "aws_subnet" "tidb" {
  count                   = var.create_network ? 1 : 0
  vpc_id                  = aws_vpc.tidb[0].id
  cidr_block              = var.subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = var.associate_public_ip

  tags = { Name = "tidb-cluster-subnet" }
}

resource "aws_route_table" "tidb" {
  count  = var.create_network ? 1 : 0
  vpc_id = aws_vpc.tidb[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.tidb[0].id
  }

  tags = { Name = "tidb-cluster-rt" }
}

resource "aws_route_table_association" "tidb" {
  count          = var.create_network ? 1 : 0
  subnet_id      = aws_subnet.tidb[0].id
  route_table_id = aws_route_table.tidb[0].id
}

locals {
  vpc_id    = var.create_network ? aws_vpc.tidb[0].id : var.vpc_id
  subnet_id = var.create_network ? aws_subnet.tidb[0].id : var.subnet_id
}

# Latest Ubuntu 24.04 LTS (amd64), resolved per-region.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Single SG for the whole cluster. The self rule carries all intra-cluster
# traffic (PD 2379/2380, TiKV 20160/20180, TiDB 4000/10080, TiCDC 8300,
# monitoring 9090/9100/3000, HAProxy -> TiDB). Only SSH, the load-balanced
# MySQL port, and Grafana are exposed to the admin CIDR.
resource "aws_security_group" "tidb" {
  name        = "tidb-cluster-prod"
  description = "TiDB production cluster"
  vpc_id      = local.vpc_id

  ingress {
    description = "intra-cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "MySQL via HAProxy / TiDB"
    from_port   = 4000
    to_port     = 4000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

locals {
  common = {
    key_name                    = var.key_name
    subnet_id                   = local.subnet_id
    vpc_security_group_ids      = [aws_security_group.tidb.id]
    associate_public_ip_address = var.associate_public_ip
  }
}

# Control machine: runs TiUP and hosts the monitoring stack.
resource "aws_instance" "controller" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.controller_instance_type
  key_name                    = local.common.key_name
  subnet_id                   = local.common.subnet_id
  vpc_security_group_ids      = local.common.vpc_security_group_ids
  associate_public_ip_address = local.common.associate_public_ip_address

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = { Name = "db-tidb-controller" }
}

# TiDB SQL nodes. PD is colocated on the FIRST THREE of these hosts only
# (see the pd_ips slice in null_resource.deploy), so tidb_count can grow past 3
# without changing PD quorum.
resource "aws_instance" "tidb" {
  count                       = var.tidb_count
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.tidb_instance_type
  key_name                    = local.common.key_name
  subnet_id                   = local.common.subnet_id
  vpc_security_group_ids      = local.common.vpc_security_group_ids
  associate_public_ip_address = local.common.associate_public_ip_address

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = { Name = format("db-tidb-%02d", count.index + 1) }
}

# TiKV nodes on g4dn. The local NVMe instance store is formatted and mounted
# at /data1 by cloud-init; TiKV's data_dir points there. The store is
# EPHEMERAL: stopping/terminating an instance loses its data, so durability
# relies on TiKV's 3x replication across these three nodes.
resource "aws_instance" "tikv" {
  count                       = var.tikv_count
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.tikv_instance_type
  key_name                    = local.common.key_name
  subnet_id                   = local.common.subnet_id
  vpc_security_group_ids      = local.common.vpc_security_group_ids
  associate_public_ip_address = local.common.associate_public_ip_address

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -e
    # Identify the instance-store NVMe (root EBS is excluded by the model match).
    DEV=$(lsblk -dpno NAME,MODEL | grep -i 'Instance Storage' | awk '{print $1}' | head -n1)
    if [ -n "$DEV" ]; then
      if ! blkid "$DEV" >/dev/null 2>&1; then mkfs.ext4 -F "$DEV"; fi
      mkdir -p /data1
      mountpoint -q /data1 || mount "$DEV" /data1
      UUID=$(blkid -s UUID -o value "$DEV")
      grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data1 ext4 defaults,nofail 0 2" >> /etc/fstab
      mkdir -p /data1/tikv-data
      chown -R ubuntu:ubuntu /data1
    fi
  EOF

  tags = { Name = format("db-tikv-%02d", count.index + 1) }
}

# TiCDC. c5 has no local store, so the sort/staging dir lives on a larger
# EBS root volume.
resource "aws_instance" "ticdc" {
  count                       = 1
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.ticdc_instance_type
  key_name                    = local.common.key_name
  subnet_id                   = local.common.subnet_id
  vpc_security_group_ids      = local.common.vpc_security_group_ids
  associate_public_ip_address = local.common.associate_public_ip_address

  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }

  tags = { Name = "db-ticdc-01" }
}

# HAProxy load balancer in front of the TiDB SQL nodes.
resource "aws_instance" "proxy" {
  count                       = 1
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.proxy_instance_type
  key_name                    = local.common.key_name
  subnet_id                   = local.common.subnet_id
  vpc_security_group_ids      = local.common.vpc_security_group_ids
  associate_public_ip_address = local.common.associate_public_ip_address

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "db-proxy-01" }
}

# Deploy + start TiDB via TiUP from the controller. The controller SSHes to
# every node over private IPs (allowed by the SG self rule).
resource "null_resource" "deploy" {
  depends_on = [
    aws_instance.tidb,
    aws_instance.tikv,
    aws_instance.ticdc,
    aws_instance.controller,
  ]

  # Re-run the deploy if any cluster member is replaced.
  triggers = {
    instances = join(",", concat(
      aws_instance.tidb[*].id,
      aws_instance.tikv[*].id,
      aws_instance.ticdc[*].id,
    ))
  }

  connection {
    type        = "ssh"
    host        = aws_instance.controller.public_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key))
    timeout     = "5m"
  }

  # Key the controller uses to reach every other node.
  provisioner "file" {
    source      = pathexpand(var.ssh_private_key)
    destination = "/home/ubuntu/.ssh/tidb-key"
  }

  # Full desired topology. Used only for the very first deploy; PD is pinned to
  # the first three TiDB hosts so growing tidb_count never adds PD members.
  provisioner "file" {
    content = templatefile("${path.module}/topology.yaml.tpl", {
      pd_ips     = slice(aws_instance.tidb[*].private_ip, 0, 3)
      tidb_ips   = aws_instance.tidb[*].private_ip
      tikv_ips   = aws_instance.tikv[*].private_ip
      cdc_ips    = aws_instance.ticdc[*].private_ip
      monitor_ip = aws_instance.controller.private_ip
    })
    destination = "/home/ubuntu/topology.yaml"
  }

  # Idempotent deploy/scale-out script. First run deploys; every later run
  # diffs the desired node set against the live cluster and scales out the new
  # TiDB/TiKV/TiCDC nodes online. PD is never scaled here.
  provisioner "file" {
    content = templatefile("${path.module}/scale.sh.tpl", {
      tidb_version = var.tidb_version
      tidb_ips     = aws_instance.tidb[*].private_ip
      tikv_ips     = aws_instance.tikv[*].private_ip
      cdc_ips      = aws_instance.ticdc[*].private_ip
    })
    destination = "/home/ubuntu/scale.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "chmod 600 /home/ubuntu/.ssh/tidb-key",
      "chmod +x /home/ubuntu/scale.sh",
      "bash /home/ubuntu/scale.sh",
    ]
  }
}

# Install and configure HAProxy on db-proxy-01, pointing at the TiDB nodes.
resource "null_resource" "proxy_setup" {
  depends_on = [null_resource.deploy]

  triggers = {
    tidb_ips = join(",", aws_instance.tidb[*].private_ip)
    proxy_id = aws_instance.proxy[0].id
  }

  connection {
    type        = "ssh"
    host        = aws_instance.proxy[0].public_ip
    user        = "ubuntu"
    private_key = file(pathexpand(var.ssh_private_key))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/haproxy.cfg.tpl", {
      tidb_ips = aws_instance.tidb[*].private_ip
    })
    destination = "/tmp/haproxy.cfg"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy",
      "sudo mv /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg",
      # Raise the fd limit so HAProxy can honor maxconn (needs ~2x for
      # client+server sockets). LimitNOFILE only takes effect on a full
      # restart, so restart when this override is new/changed; otherwise a
      # hitless reload is enough to pick up backend (scale-out) changes.
      "sudo mkdir -p /etc/systemd/system/haproxy.service.d",
      "printf '[Service]\\nLimitNOFILE=1048576\\n' | sudo tee /tmp/haproxy-limits.conf >/dev/null",
      "OVERRIDE=/etc/systemd/system/haproxy.service.d/limits.conf",
      "if sudo cmp -s /tmp/haproxy-limits.conf \"$OVERRIDE\"; then NEED_RESTART=0; else sudo mv /tmp/haproxy-limits.conf \"$OVERRIDE\"; sudo systemctl daemon-reload; NEED_RESTART=1; fi",
      "sudo systemctl enable haproxy",
      "if [ \"$NEED_RESTART\" = 1 ]; then sudo systemctl restart haproxy; else sudo systemctl reload haproxy || sudo systemctl restart haproxy; fi",
    ]
  }
}
