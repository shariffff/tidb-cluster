output "vpc_id" {
  description = "VPC the cluster runs in (created or existing)"
  value       = local.vpc_id
}

output "subnet_id" {
  description = "Subnet the cluster runs in (created or existing)"
  value       = local.subnet_id
}

output "controller" {
  description = "Control machine (TiUP + monitoring) public IP"
  value       = aws_instance.controller.public_ip
}

output "tidb_private_ips" {
  description = "TiDB + PD nodes (private)"
  value       = aws_instance.tidb[*].private_ip
}

output "tikv_private_ips" {
  value = aws_instance.tikv[*].private_ip
}

output "ticdc_private_ip" {
  value = aws_instance.ticdc[0].private_ip
}

output "proxy_public_ip" {
  description = "HAProxy endpoint for client connections"
  value       = aws_instance.proxy[0].public_ip
}

output "grafana" {
  description = "Grafana dashboard URL (default login admin/admin)"
  value       = "http://${aws_instance.controller.public_ip}:3000"
}

output "connect" {
  description = "Connect to the cluster through HAProxy once apply finishes"
  value       = "mysql -h ${aws_instance.proxy[0].public_ip} -P 4000 -u root"
}
