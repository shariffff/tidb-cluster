# TiDB cluster on AWS (ap-south-1a)

Terraform for a real TiDB cluster. One `apply` builds the instances, mounts TiKV NVMe, runs TiUP deploy+start, and configures HAProxy.

```bash
cp terraform.tfvars.example terraform.tfvars   # key_name, admin_cidr (network is created for you)
terraform init                                 # first run only
terraform plan                                 # review: expect create-only
terraform apply                                # ~10-15 min
terraform output connect                       # mysql command via HAProxy
```

Needs: active AWS creds and an EC2 key pair in `ap-south-1` (+ local private key). A dedicated VPC + public subnet in `ap-south-1a` is created by default. Check your **G-instance vCPU quota** first — the 3× g4dn fail without it.

## Region & networking

By default the stack creates its own VPC + public subnet in `ap-south-1` / `ap-south-1a`. Override via `terraform.tfvars` (sticks across applies) or `-var` flags.

**Different region / AZ** — the EC2 key pair (`key_name`) must exist in the chosen region:

```hcl
region            = "us-east-1"
availability_zone = "us-east-1a"   # must be inside region
```

**Use an existing VPC + subnet** instead of creating one — set `create_network = false` and pass both IDs. The `vpc_cidr` / `subnet_cidr` / `availability_zone` vars are then ignored (instances inherit the subnet's AZ):

```hcl
create_network = false
vpc_id         = "vpc-0abc123..."   # must be in `region`
subnet_id      = "subnet-0def456..." # determines the AZ
```

Requirements for an existing subnet:
- **Outbound internet** at deploy time (instances install TiUP/HAProxy). Use a **public** subnet with an internet gateway and keep `associate_public_ip = true` (default), or a **private** subnet behind a NAT gateway with `associate_public_ip = false`.
- **The controller and proxy need reachable public IPs** for Terraform's SSH provisioners. A private-only subnet leaves those empty and the deploy/proxy steps fail to connect — prefer a public subnet with `associate_public_ip = true`.

## Using existing security groups & private provisioning

You can keep your existing AWS security groups and run the cluster into a private subnet without Terraform creating or modifying SG rules.

- To prevent Terraform creating a security group, set in `terraform.tfvars`:

```hcl
create_security_group = false
security_group_ids = ["sg-0123456789abcdef0"]
```

- To avoid assigning public IPs to instances and have Terraform connect over private IPs, set:

```hcl
associate_public_ip = false
use_private_provisioning = true
```

When `use_private_provisioning = true` the machine running `terraform apply` must be able to reach instance private IPs (run Terraform from an EC2 in the VPC, via a bastion host with SSH jump, or over a VPN). If you cannot reach private IPs, either temporarily allow public IPs for the controller/proxy or run the post-launch TiUP/HAProxy steps manually from a machine inside the VPC.

Run `terraform plan` after changing these values and confirm the plan does not create or modify security groups.

## Topology

| Instance | Type | Role |
|---|---|---|
| tf-db-tidb-controller | t2.medium | TiUP control + monitoring (Prometheus/Grafana/Alertmanager) |
| tf-db-tidb-01..N | c5.4xlarge | TiDB + PD (PD on first 3 only) |
| tf-db-tikv-01..N | g4dn.4xlarge | TiKV — data on local NVMe `/data1` |
| tf-db-ticdc-01 | c5.2xlarge | TiCDC |
| tf-db-proxy-01 | c5.xlarge | HAProxy `:4000` (maxconn 100k) |

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

It removes the **highest-numbered** nodes (matching Terraform's top-of-`count` destroy order), floors at 3, and never touches `tf-db-tidb-01..03` (PD). Reaches the controller with `~/.ssh/id_ed25519` by default — override with `SSH_KEY=...`. Pass `-var tidb_count=N` on later applies (or set it in `terraform.tfvars`) so it sticks.

**Manual equivalent:** SSH to the controller, `tiup cluster scale-in tidb-prod --node <ip>:4000` the highest-numbered TiDB node, then `terraform apply -var tidb_count=N`.

**TiKV is out of scope** — scaling storage down means region migration: `tiup cluster scale-in` the TiKV node, wait until `tiup cluster display tidb-prod` shows it `Tombstone`, `tiup cluster prune tidb-prod`, *then* lower `tikv_count`. Terminating a TiKV node before it tombstones permanently loses that replica (data is on ephemeral NVMe). Do this by hand.

## Monitoring

- **Grafana:** `terraform output grafana` (admin/admin)
- **HAProxy stats:** `:8404` (SSH-tunnel via the proxy node)

## Caveats

- **TiKV data is on ephemeral NVMe** — losing a node loses its local data; durability relies on 3x replication. Never stop all TiKV nodes at once.
- **Single HAProxy is a SPOF and funnel.** All client traffic flows through one c5.xlarge proxy with no redundancy or failover. It's the weakest link for high concurrency — add a second proxy (or front it with an NLB) before pushing serious load.
- **`associate_public_ip = true`** by default. For a private subnet, set `false` + use NAT (controller/proxy still need reachable IPs for provisioners).
