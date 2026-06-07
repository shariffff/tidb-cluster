#!/bin/bash
# Online scale-OUT of NEW nodes into an EXISTING TiDB cluster.
#
# Runs on the existing TiUP control machine (invoked by Terraform). It NEVER
# deploys: if the named cluster isn't already known to this controller's tiup it
# errors out, so a wrong controller/cluster name can't spin up a parallel
# cluster. It diffs the desired new-node set against live membership and only
# scales out hosts the cluster doesn't already know — existing members are never
# touched, and re-runs are a safe no-op. PD is never scaled.
set -euo pipefail

CLUSTER="${cluster_name}"
KEY="$HOME/.ssh/tidb-key"
export PATH="$PATH:$HOME/.tiup/bin"

DESIRED_TIDB="${join(" ", tidb_ips)}"
DESIRED_TIKV="${join(" ", tikv_ips)}"

if ! test -x "$HOME/.tiup/bin/tiup" && ! command -v tiup >/dev/null 2>&1; then
  echo "ERROR: tiup not found on $(hostname). This module manages an EXISTING tiup cluster; point controller_host at the real control machine." >&2
  exit 1
fi

# Hard guard: the cluster MUST already exist. We never deploy from here.
if ! tiup cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER"; then
  echo "ERROR: cluster '$CLUSTER' not found on this controller. Refusing to deploy a new one." >&2
  echo "       Check existing_cluster_name and controller_host." >&2
  exit 1
fi

# Wait for SSH to come up on every desired node before touching the cluster.
# Freshly-launched instances may still be booting (sshd not yet listening ->
# "connection refused"), and tiup scale-out fails fast if it can't reach a host.
# Already-running members pass instantly.
for ip in $DESIRED_TIDB $DESIRED_TIKV; do
  [ -n "$ip" ] || continue
  echo "waiting for ssh on $ip"
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY" ubuntu@$ip true 2>/dev/null; do
    sleep 5
  done
done

# Wait until cloud-init has prepared TiKV's data dir on every new node before
# touching the cluster. Works for both storage modes (NVMe mount or EBS dir):
# /data1/tikv-data only appears once /data1 is ready.
for ip in $DESIRED_TIKV; do
  [ -n "$ip" ] || continue
  echo "waiting for /data1/tikv-data on $ip"
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY" ubuntu@$ip test -d /data1/tikv-data; do
    sleep 5
  done
done

# Compute which desired hosts are not yet members, per role.
DISPLAY="$(tiup cluster display "$CLUSTER")"
existing_role() { echo "$DISPLAY" | awk -v r="$1" '$2==r{print $3}' | sort -u; }
new_hosts() {
  comm -23 \
    <(echo "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u) \
    <(echo "$2" | sed '/^$/d' | sort -u)
}

NEW_TIDB="$(new_hosts "$DESIRED_TIDB" "$(existing_role tidb)")"
NEW_TIKV="$(new_hosts "$DESIRED_TIKV" "$(existing_role tikv)")"

SCALE="$HOME/scale-extra.yaml"
: > "$SCALE"

if [ -n "$NEW_TIDB" ]; then
  echo "tidb_servers:" >> "$SCALE"
  for ip in $NEW_TIDB; do echo "  - host: $ip" >> "$SCALE"; done
fi
if [ -n "$NEW_TIKV" ]; then
  echo "tikv_servers:" >> "$SCALE"
  for ip in $NEW_TIKV; do
    printf '  - host: %s\n    data_dir: "/data1/tikv-data"\n' "$ip" >> "$SCALE"
  done
fi

if [ -s "$SCALE" ]; then
  echo "scaling out new nodes into $CLUSTER:"
  cat "$SCALE"
  tiup cluster scale-out "$CLUSTER" "$SCALE" -u ubuntu -i "$KEY" --yes
else
  echo "no new nodes to scale out"
fi

tiup cluster display "$CLUSTER"
