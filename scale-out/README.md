# Scale-out runbook — add TiDB/TiKV to an existing cluster

Adds Terraform-managed TiDB/TiKV nodes to an **already-running** `tiup` cluster,
without ever putting the existing nodes under Terraform's control. Use this (not
the greenfield `../main.tf`) to scale a live cluster.

## Safety model (why the originals can't be touched)

The existing PD/TiDB/TiKV/controller are **never Terraform resources** — only
read-only inputs (`controller_host`, `subnet_id`, `security_group_ids`, …). This
module has its **own state**, separate from the root module. So a lowered count,
a taint, or even `terraform destroy` here can only ever affect the `*_extra`
nodes it creates. There is no `terraform import` of existing nodes.

> Proof, every time: `terraform plan` for a scale-out shows only
> `aws_instance.*_extra` + `null_resource.scale_out`, and `0 to destroy` for the
> originals (they don't appear at all).

## Prerequisites

- The cluster already exists and a reachable **controller** runs `tiup`
  (`tiup cluster list` shows it) with `~/.ssh/tidb-key` to reach nodes.
- New nodes use the **same EC2 key pair** as the cluster (`key_name`) and go in
  the **same VPC + a SG that allows intra-cluster traffic** (reuse the existing
  SG so the controller can SSH in and PD/TiKV/TiDB ports are open).
- `cp terraform.tfvars.example terraform.tfvars`, fill it in, `terraform init`.

---

# Action points

## 1. Scale OUT (online, no downtime)

Counts are **absolute totals of extra nodes** (on top of the originals), not
increments. Bump and apply:

```bash
cd scale-out

terraform apply -var tidb_extra_count=3                      # 3 extra TiDB
terraform apply -var tikv_extra_count=2                      # 2 extra TiKV
terraform apply -var tidb_extra_count=3 -var tikv_extra_count=2   # both
```

Each apply launches the instances and runs `tiup cluster scale-out` for the new
ones (the controller does it). Re-applying with the same numbers is a no-op.
Make the numbers stick by setting them in `terraform.tfvars`.

> On t2/other non-NVMe instances, set `tikv_use_instance_store = false` and
> `tikv_instance_type` to your test type (default is `g4dn.4xlarge`).

## 2. Update HAProxy after a TiDB scale — REQUIRED

**Scale-out does NOT update HAProxy.** A new TiDB node joins the cluster but the
existing HAProxy keeps load-balancing only the old nodes, so **clients never
reach the new node until you refresh the backend.**

- **TiKV scale-out:** nothing to do — PD routes to TiKV stores internally.
- **TiDB scale-out / scale-in:** run the refresh (derives the live TiDB list and
  hitless-reloads HAProxy):

```bash
./refresh-haproxy.sh --proxy <haproxy-private-ip>
# if `terraform output` is empty, pass them explicitly:
./refresh-haproxy.sh --proxy 10.0.1.76 --controller <controller-ip> --cluster tidb-prod
```

## 3. Verify after scaling

```bash
CTRL=<controller-ip>; PROXY=<proxy-ip>
# a) node joined and Up (counts should reflect the new totals):
ssh -i ~/.ssh/id_ed25519 ubuntu@$CTRL \
  'export PATH=$PATH:~/.tiup/bin; tiup cluster display tidb-prod'

# b) TiDB sees all SQL nodes:
mysql -h $PROXY -P 4000 -u root -e \
  "SELECT TYPE,INSTANCE FROM information_schema.cluster_info WHERE TYPE='tidb';"

# c) TiKV stores are Up (one row per store):
mysql -h $PROXY -P 4000 -u root -e \
  "SELECT STORE_ID,ADDRESS,STORE_STATE_NAME FROM information_schema.tikv_store_status;"

# d) HAProxy backend includes the new TiDB node:
ssh -i ~/.ssh/id_ed25519 ubuntu@$CTRL \
  "ssh -i ~/.ssh/tidb-key ubuntu@$PROXY 'grep server /etc/haproxy/haproxy.cfg'"
```
Watch region rebalancing onto new TiKV in Grafana (**PD/TiKV** dashboards) or the
TiDB Dashboard → Cluster Info.

## 4. Scale DOWN (drain first — never just lower the count)

Lowering a count and applying would yank a live member. Use the helper, which
`tiup scale-in`s the surplus tail first:

```bash
./scale-down.sh --tidb 1            # set extra-TiDB to 1 (drain tail)
./scale-down.sh --tikv 1 --yes      # TiKV: region-migrate to Tombstone, prune, then apply
```
Then refresh HAProxy (TiDB only): `./refresh-haproxy.sh --proxy <proxy-ip>`.

## 5. Restart TiDB

On the controller (`export PATH=$PATH:~/.tiup/bin`):

```bash
tiup cluster restart tidb-prod -R tidb                 # rolling-restart only the TiDB role
tiup cluster restart tidb-prod -N 10.0.1.50:4000       # one specific node
tiup cluster reload  tidb-prod -R tidb                 # apply config change, rolling
tiup cluster restart tidb-prod                         # whole cluster (DISRUPTIVE)
```
With ≥2 TiDB behind HAProxy, `-R tidb` is effectively zero-downtime (nodes
restart one at a time). For PD/TiKV restarts, prefer `-N` one node at a time.

## 6. If `terraform` fails — diagnostics (AWS CLI)

First, read the failing line — `terraform` names the resource and the cause.
Then by symptom (`REGION=ap-southeast-1`):

```bash
# "i/o timeout" SSH to controller/proxy  -> SG doesn't allow your IP on 22
curl -s https://checkip.amazonaws.com                          # your current IP
# fix: set admin_cidr to that /32 (or 0.0.0.0/0 for a throwaway test) and
#      re-apply the ROOT module; the SG updates in place.

# "connection refused" on a new node     -> it was still booting (sshd not up)
# fix: just re-apply — the scale-out waits for SSH now and tiup is idempotent.

# "InvalidKeyPair.NotFound"              -> key_name isn't an EC2 key pair here
aws ec2 describe-key-pairs --region $REGION --query 'KeyPairs[].KeyName' --output table

# "VcpuLimitExceeded"                    -> raise the vCPU quota, then re-apply
aws service-quotas request-service-quota-increase --region $REGION \
  --service-code ec2 --quota-code L-1216C47A --desired-value 64
aws service-quotas list-requested-service-quota-change-history-by-quota \
  --region $REGION --service-code ec2 --quota-code L-1216C47A \
  --query 'RequestedQuotas[0].Status' --output text          # wait for APPROVED

# "I don't see my instances"             -> wrong region / they're terminated
aws ec2 describe-instances --region $REGION \
  --filters "Name=tag:Name,Values=tf-db-*" \
  --query 'Reservations[].Instances[].{Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,Pub:PublicIpAddress}' \
  --output table

# Partial scale-out (instance up but not a cluster member)
ssh -i ~/.ssh/id_ed25519 ubuntu@<controller> \
  'export PATH=$PATH:~/.tiup/bin; tiup cluster display tidb-prod'
#   re-apply to retry; if a half-joined node is stuck, remove it then re-add:
ssh ... 'tiup cluster scale-in tidb-prod --node <ip>:<port> --yes; tiup cluster prune tidb-prod --yes'

# State lock from an interrupted run
terraform force-unlock <LOCK_ID>
```

`terraform plan` always shows intended actions before you commit — for scaling it
must read **create-only** (plus the `scale_out` marker). If a plan ever shows an
original node changing, stop: you're in the wrong directory/state.

## What this module does NOT do

- Touch PD (stays on the original nodes), or manage the cluster's lifecycle.
- Update any load balancer automatically — run `refresh-haproxy.sh` after a TiDB
  scale (see action point 2).
