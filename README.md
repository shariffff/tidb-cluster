# TiDB cluster on AWS (ap-south-1a)

Terraform for a real TiDB cluster. One `apply` builds the instances, mounts TiKV NVMe, runs TiUP deploy+start, and configures HAProxy.

```bash
cp terraform.tfvars.example terraform.tfvars   # vpc_id, subnet_id, key_name, admin_cidr
terraform init                                 # first run only
terraform apply                                # ~10-15 min
terraform output connect                       # mysql command via HAProxy
```

Needs: active AWS creds, an EC2 key pair in `ap-south-1` (+ local private key), a subnet in `ap-south-1a`. Check your **G-instance vCPU quota** first — the 3× g4dn fail without it.

## Topology

| Instance | Type | Role |
|---|---|---|
| db-tidb-controller | t2.medium | TiUP control + monitoring (Prometheus/Grafana/Alertmanager) |
| db-tidb-01..N | c5.4xlarge | TiDB + PD (PD on first 3 only) |
| db-tikv-01..N | g4dn.4xlarge | TiKV — data on local NVMe `/data1` |
| db-ticdc-01 | c5.2xlarge | TiCDC |
| db-proxy-01 | c5.xlarge | HAProxy `:4000` (maxconn 100k) |

## Scaling (online, no downtime)

```bash
terraform apply -var tidb_count=5    # more concurrent users / SQL capacity
terraform apply -var tikv_count=5    # more storage throughput
```

Re-apply does an online `tiup scale-out` of new nodes only. PD stays pinned to the first 3 TiDB nodes; both counts floor at 3. Scale-*out* only — to remove a node, `tiup cluster scale-in` it first.

## Monitoring

- **Grafana:** `terraform output grafana` (admin/admin)
- **HAProxy stats:** `:8404` (SSH-tunnel via the proxy node)

## Caveats

- **TiKV data is on ephemeral NVMe** — losing a node loses its local data; durability relies on 3x replication. Never stop all TiKV nodes at once.
- **Single HAProxy is a SPOF and funnel.** All client traffic flows through one c5.xlarge proxy with no redundancy or failover. It's the weakest link for high concurrency — add a second proxy (or front it with an NLB) before pushing serious load.
- **`associate_public_ip = true`** by default. For a private subnet, set `false` + use NAT (controller/proxy still need reachable IPs for provisioners).
