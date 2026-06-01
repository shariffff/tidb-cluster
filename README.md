# TiDB cluster on AWS (ap-south-1a)

Terraform for a real TiDB cluster. One `apply` builds the instances, mounts TiKV NVMe, runs TiUP deploy+start, and configures HAProxy.

```bash
cp terraform.tfvars.example terraform.tfvars   # key_name, admin_cidr (network is created for you)
terraform init                                 # first run only
terraform plan                                 # review: expect create-only
terraform apply                                # ~10-15 min
terraform output connect                       # mysql command via HAProxy
```

Needs: active AWS creds and an EC2 key pair in `ap-south-1` (+ local private key). A dedicated VPC + public subnet in `ap-south-1a` is created by default; to use an existing network set `create_network = false` and pass `vpc_id`/`subnet_id`. Check your **G-instance vCPU quota** first — the 3× g4dn fail without it.

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

## Scaling down the TiDB tier (drain first, then apply)

The Terraform automation is scale-*out* only. **Do not** just lower `tidb_count` and `apply` — Terraform terminates the EC2 instances directly while the cluster still thinks they're members, and leaves HAProxy pointing at dead backends. The drain has to happen *before* `apply` (Terraform destroys the doomed boxes during the apply, so a provisioner can't drain them in time).

Use the **`scale-down.sh`** helper, which `tiup cluster scale-in`s the surplus TiDB nodes on the controller, then runs `terraform apply` with the lower count:

```bash
./scale-down.sh --tidb 4          # 5 -> 4 TiDB, drained safely
./scale-down.sh --tidb 3 --yes    # skip the confirm + auto-approve apply
```

It removes the **highest-numbered** nodes (matching Terraform's top-of-`count` destroy order), floors at 3, and never touches `db-tidb-01..03` (PD). Reaches the controller with `~/.ssh/id_ed25519` by default — override with `SSH_KEY=...`. Pass `-var tidb_count=N` on later applies (or set it in `terraform.tfvars`) so it sticks.

**Manual equivalent:** SSH to the controller, `tiup cluster scale-in tidb-prod --node <ip>:4000` the highest-numbered TiDB node, then `terraform apply -var tidb_count=N`.

**TiKV is out of scope** — scaling storage down means region migration: `tiup cluster scale-in` the TiKV node, wait until `tiup cluster display tidb-prod` shows it `Tombstone`, `tiup cluster prune tidb-prod`, *then* lower `tikv_count`. Terminating a TiKV node before it tombstones permanently loses that replica (data is on ephemeral NVMe). Do this by hand.

## Monitoring

- **Grafana:** `terraform output grafana` (admin/admin)
- **HAProxy stats:** `:8404` (SSH-tunnel via the proxy node)

## Caveats

- **TiKV data is on ephemeral NVMe** — losing a node loses its local data; durability relies on 3x replication. Never stop all TiKV nodes at once.
- **Single HAProxy is a SPOF and funnel.** All client traffic flows through one c5.xlarge proxy with no redundancy or failover. It's the weakest link for high concurrency — add a second proxy (or front it with an NLB) before pushing serious load.
- **`associate_public_ip = true`** by default. For a private subnet, set `false` + use NAT (controller/proxy still need reachable IPs for provisioners).
