
#!/usr/bin/env bash
# =====================================================================
# measure.sh — 계층별 자원 스냅샷 (Physical Host → VM(Guest) → K8s)
# 실행 위치 : [ota-host] ~/ota-project
# 사용법    : ./scripts/measure.sh <라벨>      예) ./scripts/measure.sh day5r-P0
# 결과 파일 : docs/evidence/measure/<YYYYmmdd-HHMMSS>-<라벨>.txt
# 정의(고정): Host RAM Used = MemTotal - MemAvailable
#             CPU/Swap 값   = vmstat 1 6 의 2~6번째 샘플 평균 (첫 줄은 부팅 이후 평균이라 제외)
#             VM Storage    = /var/lib/libvirt/ota 사용량 (backup 디렉터리 제외)
# =====================================================================
set -uo pipefail

LABEL="${1:-}"
if [[ -z "$LABEL" ]]; then
  echo "사용법:$0 <라벨>   예)$0 day5r-P0" >&2
  exit 1
fi

REPO="${REPO:-$HOME/ota-project}"
KEY="${KEY:-$HOME/.ssh/ota_lab}"
OUT_DIR="$REPO/docs/evidence/measure"
OUT="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-${LABEL}.txt"
SSH=(ssh -n -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5)
VMS=(
  "cp-a 192.168.56.20"
  "worker-a1 192.168.56.21"
  "cp-b 192.168.56.30"
  "worker-b1 192.168.56.31"
  "worker-b2 192.168.56.32"
)

mkdir -p "$OUT_DIR"
sudo -v || { echo "sudo 인증 실패" >&2; exit 1; }

sec() { printf '\n===== %s =====\n' "$1"; }

# ---- 원시값 먼저 수집 (요약과 원문이 같은 값을 쓰도록) ----
VMSTAT="$(vmstat 1 6)"
MEMINFO="$(grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo)"
LOADAVG="$(cat /proc/loadavg)"
QEMU_TOTAL="$(ps -eo rss=,comm= | awk '$2 ~ /^qemu-system/ {s+=$1} END {printf "%.1f", s/1024}')"
VMSTORE="$(sudo du -sh --exclude=backup /var/lib/libvirt/ota 2>/dev/null | awk '{print $1}')"

{
  sec "META"
  echo "label :$LABEL"
  echo "date  :$(date '+%F %T %Z')"
  echo "git   :$(git -C "$REPO" log -1 --oneline 2>/dev/null || echo n/a)"
  echo "vms   :$(sudo virsh list --name | xargs)"

  sec "SUMMARY (비교표 입력용)"
  echo "$MEMINFO" | awk '
    /^MemTotal/     {t=$2}
    /^MemAvailable/ {a=$2}
    /^SwapTotal/    {st=$2}
    /^SwapFree/     {sf=$2}
    END {
      printf "Host RAM Used (Total-Avail) : %9.1f MiB\n", (t-a)/1024
      printf "Host MemAvailable           : %9.1f MiB\n", a/1024
      printf "Swap Used                   : %9.1f MiB\n", (st-sf)/1024
    }'
  printf "Load 1m / 5m / 15m          : %s\n" "$(echo "$LOADAVG" | awk '{print $1" / "$2" / "$3}')"
  echo "$VMSTAT" | awk 'NR>3 {us+=$13; sy+=$14; id+=$15; wa+=$16; si+=$7; so+=$8; n++}
    END {
      if (n>0) {
        printf "CPU us / sy / id / wa (%%)   : %.1f / %.1f / %.1f / %.1f\n", us/n, sy/n, id/n, wa/n
        printf "Swap si / so (평균)         : %.1f / %.1f\n", si/n, so/n
      }
    }'
  printf "Root Used                   : %s\n" "$(df -h --output=used,size / | tail -1 | awk '{print $1" / "$2}')"
  printf "VM Storage Used (du)        : %s\n" "$VMSTORE"
  printf "Total QEMU RSS              : %s MiB\n" "$QEMU_TOTAL"

  sec "[Host] free -m";        free -m
  sec "[Host] meminfo (kB)";   echo "$MEMINFO"
  sec "[Host] uptime";         uptime
  sec "[Host] vmstat 1 6";     echo "$VMSTAT"
  sec "[Host] df";             df -h / /var/lib/libvirt/ota
  sec "[Host] du (항목별)";    sudo du -sh /var/lib/libvirt/ota/* 2>/dev/null
  sec "[Host] QEMU RSS (VM별)"
  for vm in $(sudo virsh list --name); do
    sudo virsh dommemstat "$vm" | awk -v vm="$vm" '$1=="rss" {printf "%-10s %10.1f MiB\n", vm, $2/1024}'
  done
  echo "TOTAL QEMU RSS:${QEMU_TOTAL} MiB"

  for e in "${VMS[@]}"; do
    read -r name ip <<< "$e"
    sec "[Guest]$name ($ip)"
    "${SSH[@]}" "devops@$ip" '
      echo "loadavg: $(cat /proc/loadavg)"
      free -m
      df -h /
      if [ -d /opt/local-path-provisioner ]; then
        echo "--- /opt/local-path-provisioner 실제 사용량"
        sudo -n du -sh /opt/local-path-provisioner 2>/dev/null \
          || du -sh /opt/local-path-provisioner 2>/dev/null \
          || echo "(권한 부족 → 수동 측정)"
      fi' 2>&1 || echo "(SSH 실패:$name)"
  done

  for e in "cp-a 192.168.56.20" "cp-b 192.168.56.30"; do
    read -r name ip <<< "$e"
    sec "[K8s]$name"
    "${SSH[@]}" "devops@$ip" '
      kubectl get nodes -o wide
      echo "--- pods"
      kubectl get pods -A -o wide
      echo "--- sc / pv / pvc"
      kubectl get sc 2>&1
      kubectl get pv 2>&1
      kubectl get pvc -A 2>&1' 2>&1 || echo "(kubectl 실패:$name)"
  done
} 2>&1 | tee "$OUT"

echo
echo "저장 완료 →$OUT"