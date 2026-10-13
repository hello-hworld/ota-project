#!/usr/bin/env bash
# =====================================================================
# measure.sh — 계층별 자원 스냅샷 (Physical Host → VM(Guest) → Node → Pod)
# 실행 위치 : [ota-host] ~/ota-project
# 사용법    : bash scripts/measure.sh <라벨>      예) bash scripts/measure.sh day6-P0
# 결과 파일 : docs/evidence/measure/<YYYYmmdd-HHMMSS>-<라벨>.txt
# 정의(고정): Host RAM Used = MemTotal - MemAvailable
#             CPU/Swap 값   = vmstat 1 6 의 2~6번째 샘플 평균 (첫 줄은 부팅 이후 평균이라 제외)
#             VM Storage    = /var/lib/libvirt/ota 사용량 (backup 디렉터리 제외)
#             KSM saved     = pages_sharing × page size (KSM이 VM 간 같은 페이지를 합쳐 아낀 메모리)
# 변경 이력 : v1 (10/12) 최초
#             v2 (10/13) KSM, Node(Allocatable/requests/limits), 커널·uptime, 자동 업데이트 상태 추가.
#                        v1 SUMMARY 항목과 계산식은 바꾸지 않고 아래에 덧붙임 → P0a/P0b/P1과 그대로 비교 가능
# =====================================================================
set -uo pipefail

LABEL="${1:-}"
if [[ -z "$LABEL" ]]; then
  echo "사용법: bash $0 <라벨>   예) bash $0 day6-P0" >&2
  exit 1
fi

REPO="${REPO:-$HOME/ota-project}"
KEY="${KEY:-$HOME/.ssh/ota_lab}"
OUT_DIR="$REPO/docs/evidence/measure"
OUT="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-${LABEL}.txt"
SSH=(ssh -n -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5)
SSH_IN=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5)   # 원격 스크립트를 stdin으로 넘길 때
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
ksm() { cat "/sys/kernel/mm/ksm/$1" 2>/dev/null || echo "n/a"; }
ksmd_ticks() {
  local p
  p="$(pgrep -x ksmd | head -1)"
  if [[ -n "$p" ]]; then awk '{print $14 + $15}' "/proc/$p/stat"; fi
}
onoff() { [[ -f "$1" ]] && echo yes || echo no; }

# ---- 원시값 먼저 수집 (요약과 원문이 같은 값을 쓰도록) ----
CLK="$(getconf CLK_TCK)"
PAGE_KB=$(( $(getconf PAGESIZE) / 1024 ))
T0="$(ksmd_ticks)"; S0="$(date +%s.%N)"
VMSTAT="$(vmstat 1 6)"
T1="$(ksmd_ticks)"; S1="$(date +%s.%N)"
MEMINFO="$(grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo)"
LOADAVG="$(cat /proc/loadavg)"
QEMU_TOTAL="$(ps -eo rss=,comm= | awk '$2 ~ /^qemu-system/ {s+=$1} END {printf "%.1f", s/1024}')"
VMSTORE="$(sudo du -sh --exclude=backup /var/lib/libvirt/ota 2>/dev/null | awk '{print $1}')"
UP_S="$(awk '{printf "%d", $1}' /proc/uptime)"

USED_KB="$(echo "$MEMINFO" | awk '/^MemTotal/ {t=$2} /^MemAvailable/ {a=$2} END {print t-a}')"
KSM_RUN="$(ksm run)"
KSM_SHARING="$(ksm pages_sharing)"
if [[ "$KSM_SHARING" =~ ^[0-9]+$ ]]; then
  KSM_SAVED_MIB="$(awk -v p="$KSM_SHARING" -v k="$PAGE_KB" 'BEGIN {printf "%.1f", p*k/1024}')"
  USED_PLUS_KSM="$(awk -v u="$USED_KB" -v p="$KSM_SHARING" -v k="$PAGE_KB" 'BEGIN {printf "%.1f", (u + p*k)/1024}')"
else
  KSM_SAVED_MIB="n/a"; USED_PLUS_KSM="n/a"
fi
KSMD_WIN="$(awk -v a="$T0" -v b="$T1" -v s0="$S0" -v s1="$S1" -v c="$CLK" \
  'BEGIN { if (a=="" || b=="") print "n/a"; else printf "%.1f", (b-a)/c/(s1-s0)*100 }')"
KSMD_AVG="$(awk -v b="$T1" -v u="$UP_S" -v c="$CLK" \
  'BEGIN { if (b=="" || u==0) print "n/a"; else printf "%.2f", b/c/u*100 }')"

{
  sec "META"
  echo "label : $LABEL"
  echo "date  : $(date '+%F %T %Z')"
  echo "git   : $(git -C "$REPO" log -1 --oneline 2>/dev/null || echo n/a)"
  echo "vms   : $(sudo virsh list --name | xargs)"
  echo "host  : kernel $(uname -r), $(uptime -p), reboot-required=$(onoff /var/run/reboot-required)"
  echo "host auto-upgrade timer : $(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || true)"
  echo "script: measure.sh v2"

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
  echo "--- v2 추가"
  echo "$VMSTAT" | awk 'NR>3 {gu+=$18; n++} END {if (n>0) printf "Guest CPU gu (%%)            : %.1f\n", gu/n}'
  printf "KSM run                     : %s\n" "$KSM_RUN"
  printf "KSM saved (pages_sharing)   : %s MiB\n" "$KSM_SAVED_MIB"
  printf "Host RAM Used + KSM saved   : %s MiB  (KSM이 없을 때 추정 수요)\n" "$USED_PLUS_KSM"
  printf "ksmd CPU 측정 6초 / 부팅 후  : %s%% / %s%%  (CPU 1개 기준)\n" "$KSMD_WIN" "$KSMD_AVG"

  sec "[Host] free -m";        free -m
  sec "[Host] meminfo (kB)";   echo "$MEMINFO"
  sec "[Host] uptime";         uptime
  sec "[Host] vmstat 1 6";     echo "$VMSTAT"
  sec "[Host] df";             df -h / /var/lib/libvirt/ota
  sec "[Host] du (항목별)";    sudo du -sh /var/lib/libvirt/ota/* 2>/dev/null
  sec "[Host] KSM"
  for f in run pages_to_scan sleep_millisecs pages_shared pages_sharing pages_unshared pages_volatile full_scans general_profit; do
    printf "%-16s %s\n" "$f" "$(ksm "$f")"
  done
  sec "[Host] QEMU RSS (VM별)"
  for vm in $(sudo virsh list --name); do
    sudo virsh dommemstat "$vm" | awk -v vm="$vm" '$1=="rss" {printf "%-10s %10.1f MiB\n", vm, $2/1024}'
  done
  echo "TOTAL QEMU RSS: ${QEMU_TOTAL} MiB"

  for e in "${VMS[@]}"; do
    read -r name ip <<< "$e"
    sec "[Guest] $name ($ip)"
    "${SSH[@]}" "devops@$ip" '
      echo "kernel : $(uname -r)"
      echo "uptime : $(uptime -p)"
      echo "auto-upgrade timer : $(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null)"
      if [ -f /var/run/reboot-required ]; then echo "reboot-required : yes"; else echo "reboot-required : no"; fi
      echo "loadavg: $(cat /proc/loadavg)"
      free -m
      df -h /
      if [ -d /opt/local-path-provisioner ]; then
        echo "--- /opt/local-path-provisioner 실제 사용량"
        sudo -n du -sh /opt/local-path-provisioner 2>/dev/null \
          || du -sh /opt/local-path-provisioner 2>/dev/null \
          || echo "(권한 부족 → 수동 측정)"
      fi' 2>&1 || echo "(SSH 실패: $name)"
  done

  for e in "cp-a 192.168.56.20" "cp-b 192.168.56.30"; do
    read -r name ip <<< "$e"
    sec "[K8s] $name"
    "${SSH[@]}" "devops@$ip" '
      kubectl get nodes -o wide
      echo "--- pods"
      kubectl get pods -A -o wide
      echo "--- sc / pv / pvc"
      kubectl get sc 2>&1
      kubectl get pv 2>&1
      kubectl get pvc -A 2>&1' 2>&1 || echo "(kubectl 실패: $name)"
  done

  for e in "cp-a 192.168.56.20" "cp-b 192.168.56.30"; do
    read -r name ip <<< "$e"
    sec "[Node] $name 클러스터 — Allocatable / requests / limits"
    "${SSH_IN[@]}" "devops@$ip" bash -s <<'REMOTE' 2>&1 || echo "(kubectl 실패: $name)"
for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  kubectl describe node "$n" | awk -v n="$n" '
    /^Allocatable:/         {s="a"; next}
    /^Allocated resources:/ {s="r"; next}
    /^[A-Za-z]/             {s=""}
    s=="a" && $1=="cpu:"    {acpu=$2}
    s=="a" && $1=="memory:" {amem=$2}
    s=="r" && $1=="cpu"     {rc=$2 $3; lc=$4 $5}
    s=="r" && $1=="memory"  {rm=$2 $3; lm=$4 $5}
    END {
      if (amem ~ /Ki$/) { sub(/Ki$/, "", amem); amem = sprintf("%.0fMi", amem/1024) }
      printf "%-10s allocatable cpu=%s mem=%s | requests cpu=%s mem=%s | limits cpu=%s mem=%s\n", n, acpu, amem, rc, rm, lc, lm
    }'
done
echo "--- Pod별 requests / limits"
kubectl get pods -A --sort-by=.spec.nodeName -o custom-columns='NODE:.spec.nodeName,NAMESPACE:.metadata.namespace,POD:.metadata.name,CPU_REQ:.spec.containers[*].resources.requests.cpu,MEM_REQ:.spec.containers[*].resources.requests.memory,CPU_LIM:.spec.containers[*].resources.limits.cpu,MEM_LIM:.spec.containers[*].resources.limits.memory'
REMOTE
  done
} 2>&1 | tee "$OUT"

echo
echo "저장 완료 → $OUT"