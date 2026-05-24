global:
  user: "ubuntu"
  ssh_port: 22
  deploy_dir: "/home/ubuntu/tidb-deploy"
  data_dir: "/home/ubuntu/tidb-data"
  arch: "amd64"

monitored:
  node_exporter_port: 9100
  blackbox_exporter_port: 9115

# PD is colocated on the TiDB hosts (same private IPs as tidb_servers).
pd_servers:
%{ for ip in pd_ips ~}
  - host: ${ip}
%{ endfor ~}

tidb_servers:
%{ for ip in tidb_ips ~}
  - host: ${ip}
%{ endfor ~}

# TiKV stores data on the local NVMe mounted at /data1.
tikv_servers:
%{ for ip in tikv_ips ~}
  - host: ${ip}
    data_dir: "/data1/tikv-data"
%{ endfor ~}

cdc_servers:
%{ for ip in cdc_ips ~}
  - host: ${ip}
%{ endfor ~}

monitoring_servers:
  - host: ${monitor_ip}

grafana_servers:
  - host: ${monitor_ip}

alertmanager_servers:
  - host: ${monitor_ip}
