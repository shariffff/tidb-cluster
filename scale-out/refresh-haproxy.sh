#!/usr/bin/env bash
# Refresh the EXISTING HAProxy backend with the live TiDB node set (originals +
# scaled-out extras) and hitless-reload. Run after a TiDB scale-out OR scale-in
# so client traffic actually reaches the new nodes.
#
# TiKV scaling does NOT need this — PD routes to TiKV stores internally; HAProxy
# only fronts the TiDB SQL nodes.
#
# Usage:
#   ./refresh-haproxy.sh --proxy <haproxy-private-ip> [--controller <ip>] [--cluster <name>]
#   (--controller/--cluster fall back to `terraform output` when omitted)
#
# Env:
#   SSH_KEY   local key that reaches the controller (default ~/.ssh/id_ed25519)
set -euo pipefail

PROXY=""; CONTROLLER=""; CLUSTER=""
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"; KEY="${KEY/#\~/$HOME}"

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy) PROXY="$2"; shift 2;;
    --controller) CONTROLLER="$2"; shift 2;;
    --cluster) CLUSTER="$2"; shift 2;;
    -h|--help) sed -n '2,13p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$PROXY" ] || { echo "usage: $0 --proxy <haproxy-private-ip> [--controller <ip>] [--cluster <name>]" >&2; exit 1; }

[ -n "$CLUSTER" ]    || CLUSTER="$(terraform output -raw cluster_name 2>/dev/null || true)"
[ -n "$CONTROLLER" ] || CONTROLLER="$(terraform output -raw controller_host 2>/dev/null || true)"
[ -n "$CONTROLLER" ] && [ -n "$CLUSTER" ] || { echo "need --controller and --cluster (terraform outputs were empty)" >&2; exit 1; }

ctl() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY" ubuntu@"$CONTROLLER" "$@"; }

# 1. Live TiDB IPs straight from the cluster (originals + extras, always current).
IPS=$(ctl "export PATH=\$PATH:\$HOME/.tiup/bin; tiup cluster display $CLUSTER" \
        | awk '$2=="tidb"{split($1,a,":"); print a[1]}')
[ -n "$IPS" ] || { echo "no TiDB nodes found in $CLUSTER" >&2; exit 1; }
echo "TiDB backends: $(echo "$IPS" | tr '\n' ' ')"

# 2. Render haproxy.cfg locally.
CFG="$(mktemp)"
cat > "$CFG" <<'HEAD'
global
    maxconn 100000
    daemon
defaults
    log global
    mode tcp
    option tcplog
    option clitcpka
    option srvtcpka
    timeout connect 10s
    timeout client  30m
    timeout server  30m
frontend tidb-front
    bind *:4000
    maxconn 100000
    default_backend tidb-back
backend tidb-back
    balance leastconn
HEAD
i=0
for ip in $IPS; do
  i=$((i + 1))
  printf '    server tidb-%s %s:4000 check inter 2000 rise 2 fall 3\n' "$i" "$ip" >> "$CFG"
done

# 3. Push to the proxy via the controller (it always reaches the proxy over the
#    private network with its tidb-key) and hitless-reload.
scp -o StrictHostKeyChecking=no -i "$KEY" "$CFG" ubuntu@"$CONTROLLER":/tmp/haproxy.cfg
ctl "scp -o StrictHostKeyChecking=no -i \$HOME/.ssh/tidb-key /tmp/haproxy.cfg ubuntu@$PROXY:/tmp/haproxy.cfg && \
     ssh -o StrictHostKeyChecking=no -i \$HOME/.ssh/tidb-key ubuntu@$PROXY \
       'sudo mv /tmp/haproxy.cfg /etc/haproxy/haproxy.cfg && (sudo systemctl reload haproxy || sudo systemctl restart haproxy)'"
rm -f "$CFG"
echo "HAProxy on $PROXY refreshed and reloaded."
