variable "region" {
  description = "AWS region"
  default     = "ap-southeast-1"
}

# Existing network. The subnet's AZ determines where every instance lands,
# so point this at a subnet in ap-southeast-1a.
variable "vpc_id" {
  description = "ID of the existing VPC to launch into"
}

variable "subnet_id" {
  description = "ID of an existing subnet in ap-southeast-1a"
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
