variable "region" {
  description = "AWS region of the existing cluster"
  default     = "ap-south-1"
}

# ---------------------------------------------------------------------------
# Existing cluster (read-only inputs). Nothing here is created or modified by
# Terraform; these just tell the module where the live cluster is so new nodes
# can join it.
# ---------------------------------------------------------------------------

variable "existing_cluster_name" {
  description = "Name of the existing TiUP-managed cluster (as shown by `tiup cluster list` on the controller, e.g. tidb-prod). The scale-out script refuses to run if no cluster by this name exists on the controller."
}

variable "controller_host" {
  description = "Reachable IP or DNS of the EXISTING TiUP control machine. Terraform SSHes here to run `tiup cluster scale-out`. The controller must already manage existing_cluster_name and already hold the SSH key (~/.ssh/tidb-key) it uses to reach cluster nodes."
}

variable "controller_user" {
  description = "SSH user on the controller"
  default     = "ubuntu"
}

variable "ssh_private_key" {
  description = "Local path to the private key that can SSH into the controller (matches the controller's EC2 key pair)."
  default     = "~/.ssh/id_ed25519"
}

# ---------------------------------------------------------------------------
# Network / placement for the NEW nodes. Reuse the existing cluster's network so
# the new nodes are reachable by PD and the controller. These are IDs of
# EXISTING resources — Terraform reads/attaches but never manages them.
# ---------------------------------------------------------------------------

variable "subnet_id" {
  description = "Existing subnet to launch new nodes into. Must be the same VPC as the existing cluster (and ideally the same/peered subnet) so PD and the controller can reach them over private IPs."
}

variable "security_group_ids" {
  description = "Existing security group IDs to attach to the new nodes. Must permit intra-cluster traffic with the existing cluster (PD 2379/2380, TiKV 20160/20180, TiDB 4000/10080) and SSH from the controller."
  type        = list(string)
}

variable "key_name" {
  description = "Name of an existing AWS EC2 key pair (in var.region) to launch the new nodes with — this is the SAME key pair the existing cluster used, NOT the controller's ~/.ssh/tidb-key filename. Its private key must be the one on the controller as ~/.ssh/tidb-key so the controller can SSH into the new nodes for tiup scale-out. Find it with: aws ec2 describe-instances --filters Name=tag:Name,Values=tf-db-tidb-* --query 'Reservations[].Instances[].KeyName'."
}

variable "associate_public_ip" {
  description = "Give new nodes public IPs. Usually false: the controller reaches them over private IPs and tiup pushes binaries over SSH (no node internet needed). Set true only if the subnet has no other outbound path and you need it."
  type        = bool
  default     = false
}

variable "ami" {
  description = "AMI for new nodes. Empty = latest Ubuntu 24.04 LTS (matches the greenfield module). Pin this to match the existing cluster's image if needed."
  default     = ""
}

# ---------------------------------------------------------------------------
# Scaling knobs. Bump and `terraform apply` to scale OUT (online, no downtime).
# To scale DOWN, use scale-down.sh (drains the node first) — never just lower
# these and apply, or Terraform terminates a live member. Both floor at 0: the
# minimum cluster (PD quorum etc.) lives in the existing, unmanaged base.
# ---------------------------------------------------------------------------

variable "tidb_extra_count" {
  description = "Number of ADDITIONAL TiDB SQL nodes to add to the existing cluster."
  type        = number
  default     = 0

  validation {
    condition     = var.tidb_extra_count >= 0
    error_message = "tidb_extra_count must be >= 0."
  }
}

variable "tikv_extra_count" {
  description = "Number of ADDITIONAL TiKV storage nodes to add to the existing cluster. Scaling these down requires region migration first — see scale-down.sh."
  type        = number
  default     = 0

  validation {
    condition     = var.tikv_extra_count >= 0
    error_message = "tikv_extra_count must be >= 0."
  }
}

variable "tidb_instance_type" {
  description = "Instance type for new TiDB nodes (match the existing tier for uniform performance)."
  default     = "c5.4xlarge"
}

variable "tikv_instance_type" {
  description = "Instance type for new TiKV nodes. With tikv_use_instance_store = true it must have an instance-store NVMe (cloud-init mounts /data1 from it)."
  default     = "g4dn.4xlarge"
}

variable "tikv_use_instance_store" {
  description = "Mount the local NVMe instance store at /data1 for new TiKV nodes. Set false for instance types WITHOUT an instance store (e.g. t2.*), which puts the data dir on the root EBS volume instead. EBS mode has no real durability — test clusters only. Match the existing cluster's TiKV storage."
  type        = bool
  default     = true
}
