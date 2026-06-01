variable "region" {
  description = "AWS region"
  default     = "ap-south-1"
}

# Networking. By default the stack creates its own VPC, subnet, internet
# gateway, and route table (see main.tf). Set create_network = false to launch
# into an existing network instead, in which case vpc_id and subnet_id are
# required and the cidr/az variables below are ignored.
variable "create_network" {
  description = "Create a dedicated VPC + public subnet for the cluster. Set false to use an existing vpc_id/subnet_id."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "ID of an existing VPC to launch into. Required only when create_network = false."
  default     = ""
}

variable "subnet_id" {
  description = "ID of an existing subnet (in availability_zone) to launch into. Required only when create_network = false."
  default     = ""
}

variable "availability_zone" {
  description = "AZ for the created subnet (and thus every instance). Must be in var.region. Only used when create_network = true."
  default     = "ap-south-1a"
}

variable "vpc_cidr" {
  description = "CIDR block for the created VPC. Only used when create_network = true."
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for the created subnet. Must sit inside vpc_cidr. Only used when create_network = true."
  default     = "10.0.1.0/24"
}

variable "key_name" {
  description = "Name of the AWS key pair to attach to the instances"
}

variable "ssh_private_key" {
  description = "Local path to the private key matching the AWS key pair (used to SSH/deploy)"
  default     = "~/.ssh/id_ed25519"
}

variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (22), the HAProxy MySQL port (4000), and Grafana (3000). Use x.x.x.x/32 for a single IP."
}

variable "associate_public_ip" {
  description = "Give instances public IPs. Required if the subnet has no NAT gateway (instances need outbound access to install TiUP/HAProxy). Set false for a private subnet that already has NAT."
  default     = true
}

variable "tidb_version" {
  description = "TiDB cluster version to deploy via TiUP"
  default     = "v8.5.1"
}

# Horizontal scaling knobs. Bump these and `terraform apply`: new instances are
# created and the deploy step runs an ONLINE `tiup scale-out` for the new nodes
# (no redeploy, no downtime). The first 3 TiDB nodes always carry PD, so
# scaling TiDB does not change PD quorum.
variable "tidb_count" {
  description = "Number of TiDB SQL nodes (>=3). Scale this for more concurrent users / query capacity. PD stays pinned to the first 3 nodes."
  default     = 3

  validation {
    condition     = var.tidb_count >= 3
    error_message = "tidb_count must be >= 3 so the 3 colocated PD members keep quorum."
  }
}

variable "tikv_count" {
  description = "Number of TiKV storage nodes (>=3). Scale this for more storage throughput / capacity."
  default     = 3

  validation {
    condition     = var.tikv_count >= 3
    error_message = "tikv_count must be >= 3 to satisfy TiKV's default 3x replication."
  }
}

# Instance types, defaulted to the requested production sizing.
variable "controller_instance_type" {
  default = "t2.medium"
}

variable "tidb_instance_type" {
  default = "c5.4xlarge"
}

variable "tikv_instance_type" {
  default = "g4dn.4xlarge"
}

variable "ticdc_instance_type" {
  default = "c5.2xlarge"
}

variable "proxy_instance_type" {
  default = "c5.xlarge"
}
