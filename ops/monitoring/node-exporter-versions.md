# Physical Host Node Exporter

- Version: v1.12.1, linux-amd64. Existing cluster exporter version is also 1.12.1.
- Official archive: https://github.com/prometheus/node_exporter/releases/download/v1.12.1/node_exporter-1.12.1.linux-amd64.tar.gz
- Official checksum list: https://github.com/prometheus/node_exporter/releases/download/v1.12.1/sha256sums.txt
- SHA256 verified from the official list: `b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63`.
- Bind: ota-host libvirt bridge 192.168.56.1:19100. Default port 9100 is not reused.
- Service: ota-node-exporter. Job: ota-host. instance=ota-host, scope=physical-host.
- No mount namespace isolation: physical filesystem observations must use the host's mount view.
