global
    log /dev/log local0
    maxconn 8192
    daemon

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    retries 2
    timeout connect 10s
    timeout client  30m
    timeout server  30m

# Optional stats UI on :8404 (reachable inside the SG / from admin via SSH tunnel).
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /
    stats refresh 10s

frontend tidb-front
    bind *:4000
    default_backend tidb-back

backend tidb-back
    balance leastconn
%{ for ip in tidb_ips ~}
    server tidb-${ip} ${ip}:4000 check inter 2000 rise 2 fall 3
%{ endfor ~}
