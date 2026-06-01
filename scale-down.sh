#!/usr/bin/env bash
# Safe scale-DOWN of the TiDB SQL tier.
#
# Terraform only scales OUT. Lowering tidb_count and running `terraform apply`
# directly would terminate live TiDB nodes before they leave the cluster (and
# leave HAProxy pointing at dead backends). The drain has to happen BEFORE the
# apply, so this wrapper:
#
#   1. tiup cluster scale-in the surplus (highest-numbered) TiDB nodes on the
#      controller -- exactly the ones Terraform destroys from the top of the
#      count index.
#   2. terraform apply with the lower tidb_count to terminate the now-empty
#      instances and re-point HAProxy at the remaining TiDB nodes.
#
# TiKV is intentionally out of scope -- draining storage nodes (region
# migration, tombstone waits, prune) is done by hand; see the README.
#
# Usage:
#   ./scale-down.sh --tidb N [--yes]
#
# tidb_count floors at 3 (PD quorum). Removes from the tail only, so
# db-tidb-01..03 (which carry PD) are never touched.
#
# Env overrides:
#   SSH_KEY   local private key used to reach the controller (default
#             ~/.ssh/id_ed25519, matching variables.tf's ssh_private_key).
set -euo pipefail

CLUSTER="tidb-prod"
TIDB_PORT=4000
LOCAL_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

TIDB_TARGET=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tidb) TIDB_TARGET="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    -h|--help) sed -n '2,28p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

if [ -z "$TIDB_TARGET" ]; then
  echo "usage: $0 --tidb N [--yes]" >&2
  exit 1
fi
case "$TIDB_TARGET" in ''|*[!0-9]*) echo "tidb target must be an integer, got '$TIDB_TARGET'" >&2; exit 1;; esac
if [ "$TIDB_TARGET" -lt 3 ]; then echo "tidb floors at 3 (got $TIDB_TARGET)" >&2; exit 1; fi

# Pull live cluster facts from Terraform state (bash 3.2 friendly: no mapfile/jq).
CONTROLLER="$(terraform output -raw controller)"
TIDB_IPS=()
while IFS= read -r l; do TIDB_IPS+=("$l"); done < <(terraform output -json tidb_private_ips | tr -d '[]" ' | tr ',' '\n' | sed '/^$/d')

CUR="${#TIDB_IPS[@]}"
if [ "$TIDB_TARGET" -ge "$CUR" ]; then
  echo "tidb is already at $CUR; target $TIDB_TARGET is not a scale-down. Use 'terraform apply -var tidb_count=$TIDB_TARGET' to scale out." >&2
  exit 1
fi

# The surplus tail nodes -- exactly what Terraform will destroy.
DRAIN=()
for ((i=TIDB_TARGET; i<CUR; i++)); do DRAIN+=("${TIDB_IPS[$i]}"); done

echo "Cluster '$CLUSTER' via controller $CONTROLLER"
echo "  TiDB: $CUR -> $TIDB_TARGET   draining: ${DRAIN[*]}"

if [ "$ASSUME_YES" -ne 1 ]; then
  printf "Proceed with scale-in then terraform apply? [y/N] "
  read -r ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1;; esac
fi

# Run a tiup command on the controller (tiup uses its own key there).
ctl() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${LOCAL_KEY/#\~/$HOME}" \
            ubuntu@"$CONTROLLER" "export PATH=\$PATH:\$HOME/.tiup/bin; $*"; }

# 1. Scale in the surplus TiDB nodes (instant -- no data to migrate).
for ip in "${DRAIN[@]}"; do
  echo ">> scale-in TiDB $ip:$TIDB_PORT"
  ctl "tiup cluster scale-in $CLUSTER --node $ip:$TIDB_PORT --yes"
done

# 2. Terraform terminates the now-empty instances and updates the HAProxy backend.
echo ">> terraform apply -var tidb_count=$TIDB_TARGET"
if [ "$ASSUME_YES" -eq 1 ]; then
  terraform apply -auto-approve -var "tidb_count=$TIDB_TARGET"
else
  terraform apply -var "tidb_count=$TIDB_TARGET"
fi

echo "done. Pass -var tidb_count=$TIDB_TARGET on future applies (or set it in terraform.tfvars) so it sticks."
