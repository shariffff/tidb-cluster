#!/bin/bash
# Idempotent TiDB deploy / scale-out, run on the controller by Terraform.
#   - First run (cluster absent): tiup cluster deploy + start using topology.yaml.
#   - Later runs: diff the desired node set against the live cluster and
#     tiup cluster scale-out only the new TiDB / TiKV / TiCDC nodes (online).
# PD is intentionally never scaled here; it stays on the first 3 TiDB hosts.
set -euo pipefail

CLUSTER="tidb-prod"
VERSION="${tidb_version}"
KEY="$HOME/.ssh/tidb-key"
export PATH="$PATH:$HOME/.tiup/bin"

DESIRED_TIDB="${join(" ", tidb_ips)}"
DESIRED_TIKV="${join(" ", tikv_ips)}"
DESIRED_CDC="${join(" ", cdc_ips)}"

# TiKV stores data on the instance-store NVMe; wait until cloud-init has it
# mounted on every desired TiKV node before touching the cluster.
for ip in $DESIRED_TIKV; do
  echo "waiting for /data1 on $ip"
  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$KEY" ubuntu@$ip mountpoint -q /data1; do
    sleep 5
  done
done

if ! test -x "$HOME/.tiup/bin/tiup"; then
  curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
fi

# First deploy: cluster name not yet known to tiup.
if ! tiup cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER"; then
  tiup cluster deploy "$CLUSTER" "$VERSION" "$HOME/topology.yaml" -u ubuntu -i "$KEY" --yes
  tiup cluster start "$CLUSTER"
  tiup cluster display "$CLUSTER"
  exit 0
fi

# Cluster exists: compute which desired hosts are not yet members, per role.
DISPLAY="$(tiup cluster display "$CLUSTER")"
existing_role() { echo "$DISPLAY" | awk -v r="$1" '$2==r{print $3}' | sort -u; }
new_hosts() {
  comm -23 \
    <(echo "$1" | tr ' ' '\n' | sed '/^$/d' | sort -u) \
    <(echo "$2" | sed '/^$/d' | sort -u)
}

NEW_TIDB="$(new_hosts "$DESIRED_TIDB" "$(existing_role tidb)")"
NEW_TIKV="$(new_hosts "$DESIRED_TIKV" "$(existing_role tikv)")"
NEW_CDC="$(new_hosts "$DESIRED_CDC" "$(existing_role cdc)")"

SCALE="$HOME/scale.yaml"
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
if [ -n "$NEW_CDC" ]; then
  echo "cdc_servers:" >> "$SCALE"
  for ip in $NEW_CDC; do echo "  - host: $ip" >> "$SCALE"; done
fi

if [ -s "$SCALE" ]; then
  echo "scaling out new nodes:"
  cat "$SCALE"
  tiup cluster scale-out "$CLUSTER" "$SCALE" -u ubuntu -i "$KEY" --yes
else
  echo "no new nodes to scale out"
fi

tiup cluster display "$CLUSTER"
