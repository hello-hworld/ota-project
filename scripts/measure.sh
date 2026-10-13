#!/usr/bin/env bash
# =====================================================================
# measure.sh v3 — 계층별 자원 스냅샷 (Physical Host → VM(Guest) → K8s)
# 실행 위치 : [ota-host] ~/ota-project
# 사용법    : ./scripts/measure.sh <라벨>      예) ./scripts/measure.sh day6-P0a
# 결과 파일 : docs/evidence/measure/<YYYYmmdd-HHMMSS>-<라벨>.txt
# v2 변경   : - K8s 수집을 ota-host의 kubectl --context로 (cp-a/cp-b SSH 제거)
#             - KSM·QEMU PSS·VM 커널·자동 업데이트 유효값·Node 할당량 기록, CPU 평균 창 60초
# v3 변경   : - 수집 실패를 0이나 정상으로 기록하지 않는다. 실패 항목을 COLLECTION 섹션에 남기고 종료 코드 1
#             - PSS는 5대 모두 읽혔을 때만 합계를 낸다(아니면 NA)
#             - KSM 절약량은 관리 비용을 뺀 general_profit 우선, 없으면 pages_sharing. zero page 지표 함께 기록
#             - 현재 여유의 주 지표는 MemAvailable. 'KSM 보정 사용량'은 시점 간 비교용 보조 추정치
# 정의(고정): Host RAM Used = MemTotal - MemAvailable
#             KSM 보정 사용량 = Host RAM Used + KSM 절약량 (보조 추정)
#             VM Storage    = /var/lib/libvirt/ota 사용량 (backup 디렉터리 제외)
# =====================================================================
set -uo pipefail

LABEL="${1:-}"
if [[ -z "$LABEL" ]]; then
  echo "사용법: $0 <라벨>   예) $0 day6-P0a" >&2
  exit 1
fi

# 세션 설정(day6-session.env) 없이 실행해도 같은 값이 되도록 기본값을 둔다 (set -u 대비)
REPO="${REPO:-$HOME/ota-project}"
KEY="${KEY:-$HOME/.ssh/ota_lab}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/ota-lab.json}"
export PATH="$HOME/.local/bin:$PATH"
CTX_A="${OTA_CTX_A:-ota-a}"
CTX_B="${OTA_CTX_B:-ota-b}"
VMSTAT_INTERVAL="${VMSTAT_INTERVAL:-5}"
VMSTAT_COUNT="${VMSTAT_COUNT:-13}"
OUT_DIR="$REPO/docs/evidence/measure"
OUT="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-${LABEL}.txt"
SSH=(ssh -n -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5)
PAGE_KB=$(( $(getconf PAGESIZE) / 1024 ))
VMS=(
  "cp-a 192.168.56.20"
  "worker-a1 192.168.56.21"
  "cp-b 192.168.56.30"
  "worker-b1 192.168.56.31"
  "worker-b2 192.168.56.32"
)
EXPECTED_VMS=${#VMS[@]}

mkdir -p "$OUT_DIR"
sudo -v || { echo "sudo 인증 실패" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl 없음 (STEP 1 확인)" >&2; exit 1; }

FAILFILE="$(mktemp)"
trap 'rm -f "$FAILFILE"' EXIT
fail() { echo "$1" >> "$FAILFILE"; echo "(수집 실패: $1)"; }
sec()  { printf '\n===== %s =====\n' "$1"; }
ksm()  { cat "/sys/kernel/mm/ksm/$1" 2>/dev/null || echo NA; }
kc()   { local ctx="$1"; shift; kubectl --context "$ctx" "$@" 2>&1 || fail "kubectl $ctx $*"; }

# ---- 원시값 먼저 수집 (요약과 원문이 같은 값을 쓰도록) ----
VMSTAT="$(vmstat "$VMSTAT_INTERVAL" "$VMSTAT_COUNT")" || fail "vmstat"
MEMINFO="$(grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree):' /proc/meminfo)"
LOADAVG="$(cat /proc/loadavg)"
QEMU_TOTAL="$(ps -eo rss=,comm= | awk '$2 ~ /^qemu-system/ {s+=$1} END {printf "%.1f", s/1024}')"
VMSTORE="$(sudo du -sh --exclude=backup /var/lib/libvirt/ota 2>/dev/null | awk '{print $1}')"
[[ -n "$VMSTORE" ]] || { VMSTORE="NA"; fail "VM Storage du"; }
KSM_SHARING="$(ksm pages_sharing)"
KSM_PROFIT="$(ksm general_profit)"
KSMD_CPU="$(ps -C ksmd -o %cpu=,time= | xargs)"

PSS_LINES=""; PSS_OK=0; PSS_N=0
for pid in $(pgrep qemu-system); do
  PSS_N=$((PSS_N + 1))
  vm=$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 's/^guest=\([^,]*\).*/\1/p')
  pss=$(sudo awk '/^Pss:/ {print $2}' "/proc/$pid/smaps_rollup" 2>/dev/null)
  if [[ "$pss" =~ ^[0-9]+$ ]]; then
    PSS_OK=$((PSS_OK + 1)); PSS_LINES+="${vm:-pid$pid} $pss"$'\n'
  else
    PSS_LINES+="${vm:-pid$pid} NA"$'\n'; fail "PSS ${vm:-pid$pid}"
  fi
done
if [[ $PSS_N -eq $EXPECTED_VMS && $PSS_OK -eq $EXPECTED_VMS ]]; then
  PSS_TOTAL="$(printf '%s' "$PSS_LINES" | awk 'NF==2 && $2 ~ /^[0-9]+$/ {s+=$2} END {printf "%.1f", s/1024}')"
else
  PSS_TOTAL="NA (${PSS_OK}/${EXPECTED_VMS})"
  [[ $PSS_N -eq $EXPECTED_VMS ]] || fail "QEMU 프로세스 수 ${PSS_N}/${EXPECTED_VMS}"
fi

{
  sec "META"
  echo "label  : $LABEL"
  echo "date   : $(date '+%F %T %Z')"
  echo "git    : $(git -C "$REPO" log -1 --oneline 2>/dev/null || echo n/a)"
  echo "kernel : $(uname -r)"
  echo "vms    : $(sudo virsh list --name | xargs)"
  echo "k8s    : A $(kubectl --context "$CTX_A" version 2>/dev/null | awk '/Server/ {print $3}') / B $(kubectl --context "$CTX_B" version 2>/dev/null | awk '/Server/ {print $3}')"

  sec "SUMMARY (비교표 입력용)"
  echo "$MEMINFO" | awk -v sharing="$KSM_SHARING" -v profit="$KSM_PROFIT" -v pk="$PAGE_KB" '
    /^MemTotal/     {t=$2}
    /^MemAvailable/ {a=$2}
    /^SwapTotal/    {st=$2}
    /^SwapFree/     {sf=$2}
    END {
      used=(t-a)/1024
      printf "Host MemAvailable (주 지표)  : %9.1f MiB\n", a/1024
      printf "Host RAM Used (Total-Avail) : %9.1f MiB\n", used
      printf "Swap Used                   : %9.1f MiB\n", (st-sf)/1024
      if (profit ~ /^-?[0-9]+$/)      { saved=profit/1048576; how="general_profit" }
      else if (sharing ~ /^[0-9]+$/)  { saved=sharing*pk/1024; how="pages_sharing" }
      else                            { how="" }
      if (how != "") {
        printf "KSM 절약량 (%s) : %9.1f MiB\n", how, saved
        printf "KSM 보정 사용량 (보조 추정) : %9.1f MiB\n", used+saved
      } else {
        print "KSM 절약량                  : NA"
      }
    }'
  printf "KSM run / use_zero_pages / ksm_zero_pages : %s / %s / %s\n" "$(ksm run)" "$(ksm use_zero_pages)" "$(ksm ksm_zero_pages)"
  printf "Load 1m / 5m / 15m          : %s\n" "$(echo "$LOADAVG" | awk '{print $1" / "$2" / "$3}')"
  echo "$VMSTAT" | awk 'NR>3 {us+=$13; sy+=$14; id+=$15; wa+=$16; si+=$7; so+=$8; if (NF>=18) gu+=$18; n++}
    END {
      if (n>0) {
        printf "CPU us / sy / id / wa (%%)   : %.1f / %.1f / %.1f / %.1f\n", us/n, sy/n, id/n, wa/n
        printf "Guest CPU gu (%%)            : %.1f\n", gu/n
        printf "Swap si / so (평균)         : %.1f / %.1f\n", si/n, so/n
        printf "CPU 평균 샘플 수            : %d\n", n
      }
    }'
  printf "Root Used                   : %s\n" "$(df -h --output=used,size / | tail -1 | awk '{print $1" / "$2}')"
  printf "VM Storage Used (du)        : %s\n" "$VMSTORE"
  printf "Total QEMU RSS              : %s MiB\n" "$QEMU_TOTAL"
  printf "Total QEMU PSS              : %s MiB\n" "$PSS_TOTAL"
  printf "ksmd (%%cpu time)            : %s\n" "$KSMD_CPU"

  sec "[Host] free -m";        free -m
  sec "[Host] meminfo (kB)";   echo "$MEMINFO"
  sec "[Host] uptime";         uptime
  sec "[Host] vmstat $VMSTAT_INTERVAL $VMSTAT_COUNT"; echo "$VMSTAT"
  sec "[Host] df";             df -h / /var/lib/libvirt/ota
  sec "[Host] du (항목별)";    sudo du -sh /var/lib/libvirt/ota/* 2>/dev/null
  sec "[Host] KSM"
  for f in run pages_shared pages_sharing pages_unshared pages_volatile full_scans general_profit use_zero_pages ksm_zero_pages; do
    echo "$f=$(ksm "$f")"
  done
  sec "[Host] QEMU RSS (VM별, virsh dommemstat)"
  for vm in $(sudo virsh list --name); do
    sudo virsh dommemstat "$vm" | awk -v vm="$vm" '$1=="rss" {printf "%-10s %10.1f MiB\n", vm, $2/1024}'
  done
  echo "TOTAL QEMU RSS: ${QEMU_TOTAL} MiB"
  sec "[Host] QEMU PSS (VM별, smaps_rollup)"
  printf '%s' "$PSS_LINES" | awk 'NF==2 {if ($2 ~ /^[0-9]+$/) printf "%-10s %10.1f MiB\n", $1, $2/1024; else printf "%-10s %10s\n", $1, "NA"}'
  echo "TOTAL QEMU PSS: ${PSS_TOTAL} MiB"
  sec "[Host] 자동 업데이트"
  apt-config dump | grep -E '^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade) ' || echo "(none)"
  for t in apt-daily.timer apt-daily-upgrade.timer; do
    echo "$t=$(systemctl show -p UnitFileState --value "$t")/$(systemctl show -p ActiveState --value "$t")"
  done
  sec "[Host] timers (다음 실행 예정)"; systemctl list-timers --no-pager | head -20

  for e in "${VMS[@]}"; do
    read -r name ip <<< "$e"
    sec "[Guest] $name ($ip)"
    # shellcheck disable=SC2016  # 작은따옴표 안의 $는 게스트 셸에서 펼친다(의도)
    "${SSH[@]}" "devops@$ip" '
      echo "kernel : $(uname -r)"
      echo "loadavg: $(cat /proc/loadavg)"
      grep -E "^(MemTotal|MemAvailable):" /proc/meminfo
      apt-config dump | grep -E "^APT::Periodic::(Update-Package-Lists|Unattended-Upgrade) "
      for t in apt-daily.timer apt-daily-upgrade.timer; do
        echo "$t=$(systemctl show -p UnitFileState --value $t)/$(systemctl show -p ActiveState --value $t)"
      done
      free -m
      df -h /
      if [ -d /opt/local-path-provisioner ]; then
        echo "--- /opt/local-path-provisioner 실제 사용량"
        sudo -n du -sh /opt/local-path-provisioner 2>/dev/null \
          || du -sh /opt/local-path-provisioner 2>/dev/null \
          || echo "(권한 부족 → 수동 측정)"
      fi' 2>&1 || fail "SSH $name"
  done

  for ctx in "$CTX_A" "$CTX_B"; do
    sec "[K8s] $ctx"
    kc "$ctx" get nodes -o wide
    echo "--- allocatable / pressure"
    kc "$ctx" get nodes -o custom-columns='NODE:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,MemPressure:.status.conditions[?(@.type=="MemoryPressure")].status,DiskPressure:.status.conditions[?(@.type=="DiskPressure")].status'
    echo "--- allocated resources (requests / limits 합계)"
    { kubectl --context "$ctx" describe nodes | awk '/^Name:/ {print} /^Allocated resources:/ {f=1} /^Events:/ {f=0} f'; } 2>&1 \
      || fail "kubectl $ctx describe nodes"
    echo "--- pods"
    kc "$ctx" get pods -A -o wide
    echo "--- sc / pv / pvc"
    kc "$ctx" get sc,pv
    kc "$ctx" get pvc -A
  done
} 2>&1 | tee "$OUT"

NFAIL=$(wc -l < "$FAILFILE")
{
  sec "COLLECTION"
  echo "수집 실패: $NFAIL"
  sed 's/^/  - /' "$FAILFILE"
} | tee -a "$OUT"

echo
echo "저장 완료 → $OUT"
if [[ $NFAIL -gt 0 ]]; then
  echo "필수 항목 수집 실패가 있어 이 측정은 완료로 판정하지 않는다 (파일은 보존)" >&2
  exit 1
fi
