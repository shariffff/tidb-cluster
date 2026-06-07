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

# SAFETY MODEL
# ------------
# This module NEVER represents the existing cluster as a Terraform resource. The
# existing PD / TiDB / TiKV / controller live entirely outside this state and are
# referenced only as read-only inputs (variables below). Terraform therefore has
# no way to modify or destroy them: a lowered count, a tainted resource, or even
# `terraform destroy` here can only ever touch the *_extra instances created
# below. New nodes join the live cluster via `tiup cluster scale-out` run on the
# EXISTING controller, and leave via the drain-first scale-down.sh helper.

# Latest Ubuntu 24.04 LTS (amd64), matching the greenfield module. Set var.ami to
# pin a specific image (e.g. to match the existing cluster's AMI exactly).
data "aws_ami" "ubuntu" {
  count       = var.ami == "" ? 1 : 0
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

locals {
  ami = var.ami != "" ? var.ami : data.aws_ami.ubuntu[0].id

  # Tags stamped on every node this module owns. The ManagedBy tag is the marker
  # that distinguishes Terraform-managed scale-out nodes from the originals.
  extra_tags = {
    ManagedBy = "terraform-scaleout"
    Cluster   = var.existing_cluster_name
  }
}

# Additional TiDB SQL nodes. These carry NO PD (PD stays on the existing cluster's
# original nodes), so any number can be added or removed without touching quorum.
resource "aws_instance" "tidb_extra" {
  count                       = var.tidb_extra_count
  ami                         = local.ami
  instance_type               = var.tidb_instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = merge(local.extra_tags, {
    Name = format("tf-db-tidb-extra-%02d", count.index + 1)
    Role = "tidb"
  })
}

# Additional TiKV storage nodes. By default the local NVMe instance store is
# mounted at /data1 and TiKV's data_dir points there (EPHEMERAL; durability
# relies on 3x replication). When tikv_use_instance_store = false (e.g. t2.* with
# no NVMe), /data1 is just a directory on the root EBS volume — test-only.
# Scaling these DOWN requires region migration first (see scale-down.sh / README).
locals {
  tikv_extra_user_data_nvme = <<-EOF
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

  tikv_extra_user_data_ebs = <<-EOF
    #!/bin/bash
    set -e
    # No instance store: TiKV data dir lives on the root EBS volume.
    mkdir -p /data1/tikv-data
    chown -R ubuntu:ubuntu /data1
  EOF

  tikv_extra_user_data = var.tikv_use_instance_store ? local.tikv_extra_user_data_nvme : local.tikv_extra_user_data_ebs
}

resource "aws_instance" "tikv_extra" {
  count                       = var.tikv_extra_count
  ami                         = local.ami
  instance_type               = var.tikv_instance_type
  key_name                    = var.key_name
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = local.tikv_extra_user_data

  tags = merge(local.extra_tags, {
    Name = format("tf-db-tikv-extra-%02d", count.index + 1)
    Role = "tikv"
  })
}

# Register the new nodes with the EXISTING cluster by running tiup on the
# EXISTING controller. The script refuses to deploy: if the named cluster is not
# already known to that controller's tiup it errors out, so a misconfigured
# controller_host / cluster name can never spin up a second, parallel cluster.
#
# Idempotent: the script diffs the desired new-node set against live membership
# and only scales out hosts the cluster doesn't already know, so re-applies are
# safe and a no-op once the nodes have joined.
resource "null_resource" "scale_out" {
  count = (var.tidb_extra_count + var.tikv_extra_count) > 0 ? 1 : 0

  depends_on = [
    aws_instance.tidb_extra,
    aws_instance.tikv_extra,
  ]

  triggers = {
    cluster = var.existing_cluster_name
    instances = join(",", concat(
      aws_instance.tidb_extra[*].id,
      aws_instance.tikv_extra[*].id,
    ))
  }

  connection {
    type        = "ssh"
    host        = var.controller_host
    user        = var.controller_user
    private_key = file(pathexpand(var.ssh_private_key))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/scale-out.sh.tpl", {
      cluster_name = var.existing_cluster_name
      tidb_ips     = aws_instance.tidb_extra[*].private_ip
      tikv_ips     = aws_instance.tikv_extra[*].private_ip
    })
    destination = "/home/${var.controller_user}/scale-out.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",
      "chmod +x /home/${var.controller_user}/scale-out.sh",
      "bash /home/${var.controller_user}/scale-out.sh",
    ]
  }
}
