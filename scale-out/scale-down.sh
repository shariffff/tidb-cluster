#!/usr/bin/env bash
# Safe scale-DOWN of the Terraform-managed EXTRA nodes.
#
# Terraform only scales OUT. Lowering a count and running `terraform apply`
# directly would terminate live cluster members before they leave the cluster.
# The drain has to happen BEFORE the apply, so this wrapper:
#
#   1. tiup cluster scale-in the surplus (highest-numbered) EXTRA nodes via the
#      existing controller -- exactly the ones Terraform destroys from the top
#      of the count index.
#   2. For TiKV, wait until each node reaches `Tombstone` (its regions have been
#      migrated to other stores), then `tiup cluster prune`. Skipping this loses
#      that node's replica -- TiKV data lives on EPHEMERAL NVMe.
#   3. terraform apply with the lower count to terminate the now-empty instances.
#
# This only ever touches *_extra nodes (Terraform's count tail). The existing
# cluster's original nodes are not in this state and cannot be selected here.
#
# Usage:
#   ./scale-down.sh --tidb N            # set extra-TiDB count to N (drain tail)
#   ./scale-down.sh --tikv N            # set extra-TiKV count to N (region migrate)
#   ./scale-down.sh --tidb N --tikv M [--yes]
#
# Env overrides:
#   SSH_KEY   local private key used to reach the controller (default
#             ~/.ssh/id_ed25519, matching variables.tf's ssh_private_key).
set -euo pipefail

TIDB_PORT=4000
TIKV_PORT=20160
LOCAL_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

TIDB_TARGET=""
TIKV_TARGET=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --tidb) TIDB_TARGET="$2"; shift 2;;
    --tikv) TIKV_TARGET="$2"; shift 2;;
    --yes|-y) ASSUME_YES=1; shift;;
    -h|--help) sed -n '2,33p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

if [ -z "$TIDB_TARGET" ] && [ -z "$TIKV_TARGET" ]; then
  echo "usage: $0 [--tidb N] [--tikv N] [--yes]" >&2
  exit 1
fi
for v in "$TIDB_TARGET" "$TIKV_TARGET"; do
  case "$v" in '') ;; *[!0-9]*) echo "counts must be non-negative integers, got '$v'" >&2; exit 1;; esac
done

CLUSTER="$(terraform output -raw cluster_name)"
CONTROLLER="$(terraform output -raw controller_host)"

read_ips() { terraform output -json "$1" | tr -d '[]" ' | tr ',' '\n' | sed '/^$/d'; }

TIDB_IPS=(); while IFS= read -r l; do TIDB_IPS+=("$l"); done < <(read_ips tidb_extra_private_ips)
TIKV_IPS=(); while IFS= read -r l; do TIKV_IPS+=("$l"); done < <(read_ips tikv_extra_private_ips)

# Run a tiup command on the existing controller (tiup uses its own key there).
ctl() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "${LOCAL_KEY/#\~/$HOME}" \
            ubuntu@"$CONTROLLER" "export PATH=\$PATH:\$HOME/.tiup/bin; $*"; }

APPLY_ARGS=()

# --- TiDB: instant scale-in of the surplus tail, no data migration. ---------
if [ -n "$TIDB_TARGET" ]; then
  CUR=${#TIDB_IPS[@]}
  if [ "$TIDB_TARGET" -ge "$CUR" ]; then
    echo "extra TiDB already at $CUR; target $TIDB_TARGET is not a scale-down (use terraform apply -var tidb_extra_count=$TIDB_TARGET to scale out)." >&2
  else
    echo "TiDB extras: $CUR -> $TIDB_TARGET"
    for ((i=TIDB_TARGET; i<CUR; i++)); do
      echo ">> scale-in TiDB ${TIDB_IPS[$i]}:$TIDB_PORT"
      [ "$ASSUME_YES" -eq 1 ] || { printf "  proceed? [y/N] "; read -r a; case "$a" in y|Y|yes|YES) ;; *) echo aborted; exit 1;; esac; }
      ctl "tiup cluster scale-in $CLUSTER --node ${TIDB_IPS[$i]}:$TIDB_PORT --yes"
    done
    APPLY_ARGS+=(-var "tidb_extra_count=$TIDB_TARGET")
  fi
fi

# --- TiKV: scale-in, then WAIT for Tombstone (region migration), then prune. -
if [ -n "$TIKV_TARGET" ]; then
  CUR=${#TIKV_IPS[@]}
  if [ "$TIKV_TARGET" -ge "$CUR" ]; then
    echo "extra TiKV already at $CUR; target $TIKV_TARGET is not a scale-down (use terraform apply -var tikv_extra_count=$TIKV_TARGET to scale out)." >&2
  else
    echo "TiKV extras: $CUR -> $TIKV_TARGET   (region migration required)"
    echo "WARNING: TiKV data is on ephemeral NVMe. Each node must reach Tombstone before its instance is terminated, or its replica is lost."
    [ "$ASSUME_YES" -eq 1 ] || { printf "proceed with TiKV region migration? [y/N] "; read -r a; case "$a" in y|Y|yes|YES) ;; *) echo aborted; exit 1;; esac; }
    for ((i=TIKV_TARGET; i<CUR; i++)); do
      NODE="${TIKV_IPS[$i]}:$TIKV_PORT"
      echo ">> scale-in TiKV $NODE"
      ctl "tiup cluster scale-in $CLUSTER --node $NODE --yes"
      echo "   waiting for $NODE to reach Tombstone (regions draining)..."
      until ctl "tiup cluster display $CLUSTER" | awk -v n="$NODE" '$1==n{print $7}' | grep -qi tombstone; do
        sleep 15
      done
      echo "   $NODE is Tombstone; pruning."
      ctl "tiup cluster prune $CLUSTER --yes"
    done
    APPLY_ARGS+=(-var "tikv_extra_count=$TIKV_TARGET")
  fi
fi

if [ ${#APPLY_ARGS[@]} -eq 0 ]; then
  echo "nothing to do."
  exit 0
fi

echo ">> terraform apply ${APPLY_ARGS[*]}"
if [ "$ASSUME_YES" -eq 1 ]; then
  terraform apply -auto-approve "${APPLY_ARGS[@]}"
else
  terraform apply "${APPLY_ARGS[@]}"
fi

echo "done. Set the lowered count(s) in terraform.tfvars so they stick on future applies."
