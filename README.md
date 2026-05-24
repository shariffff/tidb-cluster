# TiDB production cluster (ap-southeast-1a)

Terraform for a real TiDB cluster on AWS (`ap-southeast-1a`).

## TL;DR

```bash
cp terraform.tfvars.example terraform.tfvars   # set vpc_id, subnet_id, key_name, admin_cidr
terraform plan                                 # expect: create only, 0 to destroy
terraform apply                                # ~10-15 min
terraform output connect                       # mysql command via HAProxy
```

Prereqs: AWS creds active (`aws sts get-caller-identity` works), an existing
EC2 key pair in `ap-southeast-1` with its private key on this machine, and a
subnet in `ap-southeast-1a`. `terraform init` is only needed the first time.

One `apply` does everything: instances → NVMe format/mount on TiKV → TiUP
deploy+start → HAProxy install/config. Nothing is set up by hand. Heads-up:
the 3× g4dn GPU instances can fail at apply if your account's G-instance
vCPU quota is too low — check that before applying.

## Topology

| Instance | Type | Role |
|---|---|---|
| db-tidb-controller | t2.medium | TiUP control machine + monitoring (Prometheus/Grafana/AlertManager) |
| db-tidb-01/02/03 | c5.4xlarge | TiDB server + PD (colocated) |
| db-tikv-01/02/03 | g4dn.4xlarge | TiKV — data on local NVMe `/data1` |
| db-ticdc-01 | c5.2xlarge | TiCDC |
| db-proxy-01 | c5.xlarge | HAProxy load balancer for client `:4000` |

## Notes / caveats

- **TiKV data is on ephemeral NVMe.** Stopping or terminating a TiKV
  instance loses its local data; durability relies on TiKV's 3x
  replication. Don't stop all TiKV nodes at once.
- **PD is colocated with TiDB** on the three c5.4xlarge nodes.
- `associate_public_ip = true` by default so nodes can install TiUP/HAProxy.
  For a hardened setup, use a private subnet with a NAT gateway and set it
  to `false` (the controller and proxy still need a public IP or a bastion
  for the Terraform provisioners to reach them).
- HAProxy stats UI is on `:8404` (not exposed externally; reach it via an
  SSH tunnel through the proxy node).
