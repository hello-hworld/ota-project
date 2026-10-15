#!/usr/bin/env bash
# Run on ota-host after reviewing service file; no overwrite of an existing service.
set -euo pipefail
source "$HOME/ota-project/scripts/day9-session.env"
[[ "$(uname -m)" == x86_64 ]] || { echo 'STOP: expected linux-amd64'; exit 1; }
ip -4 addr show virbr56 | grep -F '192.168.56.1/24'
getent passwd nobody >/dev/null
getent group nogroup >/dev/null
if systemctl cat ota-node-exporter.service >/dev/null 2>&1; then
 echo 'STOP: existing service; inspect and preserve it'; exit 1
fi
[[ ! -e /etc/systemd/system/ota-node-exporter.service && ! -e /usr/local/libexec/ota-node-exporter-1.12.1 ]]
if ss -ltn '( sport = :19100 )' | tail -n +2 | grep -q .; then echo 'STOP: port 19100 in use'; exit 1; fi
cache="$HOME/.cache/ota-day9-downloads"
mkdir -p "$cache"
archive="$cache/node_exporter-1.12.1.linux-amd64.tar.gz"
if [[ ! -f "$archive" ]]; then
 curl --fail --location --retry 2 --output "$archive.part" \
  https://github.com/prometheus/node_exporter/releases/download/v1.12.1/node_exporter-1.12.1.linux-amd64.tar.gz
 mv -- "$archive.part" "$archive"
fi
printf 'b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63  %s\n' "$archive" | sha256sum --check
extract="$(mktemp -d "$cache/extract.XXXXXX")"
tar -xzf "$archive" -C "$extract" node_exporter-1.12.1.linux-amd64/node_exporter
"$extract/node_exporter-1.12.1.linux-amd64/node_exporter" --version
sudo install -d -m 0755 /usr/local/libexec
sudo install -m 0755 "$extract/node_exporter-1.12.1.linux-amd64/node_exporter" /usr/local/libexec/ota-node-exporter-1.12.1
sudo install -m 0644 ops/monitoring/ota-node-exporter.service /etc/systemd/system/ota-node-exporter.service
sudo systemd-analyze verify /etc/systemd/system/ota-node-exporter.service
sudo systemctl daemon-reload
sudo systemctl enable --now ota-node-exporter.service
sudo systemctl is-active --quiet ota-node-exporter.service
curl --fail --silent --show-error http://192.168.56.1:19100/metrics > "$EV/02-physical-host-metrics.txt"
grep '^node_uname_info{' "$EV/02-physical-host-metrics.txt"
echo 'RESULT=PASS'
