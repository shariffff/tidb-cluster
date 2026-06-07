output "tidb_extra_private_ips" {
  description = "Private IPs of the Terraform-managed extra TiDB nodes"
  value       = aws_instance.tidb_extra[*].private_ip
}

output "tikv_extra_private_ips" {
  description = "Private IPs of the Terraform-managed extra TiKV nodes"
  value       = aws_instance.tikv_extra[*].private_ip
}

output "tidb_extra_ids" {
  value = aws_instance.tidb_extra[*].id
}

output "tikv_extra_ids" {
  value = aws_instance.tikv_extra[*].id
}

# Echoed for the scale-down helper, which reads them from `terraform output`.
output "controller_host" {
  value = var.controller_host
}

output "cluster_name" {
  value = var.existing_cluster_name
}
