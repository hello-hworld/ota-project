#!/usr/bin/env bash
# =====================================================================
# sample.sh — 빌드 구간 연속 수집 (measure.sh는 한 시점 스냅샷이라 피크를 못 잡는다)
# 실행 위치 : [ota-host] ~/ota-project, 빌드 전에 별도 터미널에서 시작 → 빌드가 끝나면 Ctrl+C
# 사용법    : ./scripts/sample.sh <라벨>        예) ./scripts/sample.sh day6-build-run01
# 결과 파일 : docs/evidence/measure/<시각>-<라벨>-host-vmstat.txt  Host vmstat 1초
#             docs/evidence/measure/<시각>-<라벨>-worker-a1.txt     worker-a1 MemAvailable·CPU (INTERVAL초)
#             docs/evidence/measure/<시각>-<라벨>-domstats.csv      VM별 누적 CPU·RSS, Host MemAvailable, KSM (INTERVAL초)
# 주의      : vmstat의 free는 MemAvailable이 아니다. 여유 메모리 최저값은 MemAvailable 열로 본다.
# =====================================================================
set -uo pipefail

LABEL="${1:-}"
if [[ -z "$LABEL" ]]; then
  echo "사용법: $0 <라벨>" >&2
  exit 1
fi

REPO="${REPO:-$HOME/ota-project}"
KEY="${KEY:-$HOME/.ssh/ota_lab}"
INTERVAL="${INTERVAL:-5}"
OUT_DIR="$REPO/docs/evidence/measure"
BASE="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-${LABEL}"

mkdir -p "$OUT_DIR"
sudo -v || { echo "sudo 인증 실패" >&2; exit 1; }

vmstat -t 1 > "$BASE-host-vmstat.txt" &
PID_HOST=$!

ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 devops@192.168.56.21 \
  "INTERVAL=$INTERVAL bash -s" > "$BASE-worker-a1.txt" 2>&1 <<'REMOTE' &
echo "time MemAvailable_MiB MemFree_MiB r b us sy id wa st"
while true; do
  m=$(awk '/^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} END {printf "%.1f %.1f", a/1024, f/1024}' /proc/meminfo)
  v=$(vmstat 1 2 | tail -1 | awk '{print $1, $2, $13, $14, $15, $16, $17}')
  echo "$(date +%T) $m $v"
  sleep "$INTERVAL"
done
REMOTE
PID_GUEST=$!

stop() {
  kill "$PID_HOST" "$PID_GUEST" 2>/dev/null
  wait 2>/dev/null
  echo
  echo "저장 완료 → $BASE-*"
  exit 0
}
trap stop INT TERM

echo "epoch,vm,cpu_time_ns,rss_kib,host_memavail_kib,ksm_pages_sharing,ksm_general_profit" > "$BASE-domstats.csv"
echo "수집 중 (Ctrl+C로 종료) → $BASE-*"
while true; do
  now=$(date +%s)
  hma=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
  ksm=$(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null || echo NA)
  kgp=$(cat /sys/kernel/mm/ksm/general_profit 2>/dev/null || echo NA)
  sudo -n virsh domstats --cpu-total --balloon 2>/dev/null \
    | awk -v t="$now" -v h="$hma" -v k="$ksm" -v g="$kgp" '
      /^Domain:/                {vm=$2; gsub(/[^A-Za-z0-9_.-]/, "", vm)}
      $1 ~ /^cpu\.time=/        {split($1, a, "="); cpu=a[2]}
      $1 ~ /^balloon\.rss=/     {split($1, a, "="); print t "," vm "," cpu "," a[2] "," h "," k "," g}' \
    >> "$BASE-domstats.csv"
  sleep "$INTERVAL"
done
