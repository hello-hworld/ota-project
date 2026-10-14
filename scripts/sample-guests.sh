#!/usr/bin/env bash
# =====================================================================
# sample-guests.sh — Guest(VM 내부) 연속 수집: MemAvailable·메모리 Pressure(PSI)·CPU
#   sample.sh는 worker-a1만 수집하므로 Cluster B Worker(배포·승격·복귀 구간)는 이 스크립트로 수집한다
# 실행 위치 : [ota-host] ~/ota-project, 별도 터미널 → 구간이 끝나면 Ctrl+C
# 사용법    : ./scripts/sample-guests.sh <라벨> [이름=IP ...]   (기본: worker-b1=192.168.56.31 worker-b2=192.168.56.32)
#             예) ./scripts/sample-guests.sh day7-deploy
# 결과 파일 : docs/evidence/measure/<시각>-<라벨>-<이름>.txt (INTERVAL초, 기본 5)
# 주의      : SSH가 끊기면 그 VM 파일이 거기서 끝난다. 끝난 뒤 각 파일의 마지막 시각을 확인한다
# =====================================================================
set -uo pipefail

LABEL="${1:-}"
[[ -n "$LABEL" ]] || { echo "사용법: $0 <라벨> [이름=IP ...]" >&2; exit 1; }
shift
TARGETS=("$@")
[[ ${#TARGETS[@]} -gt 0 ]] || TARGETS=("worker-b1=192.168.56.31" "worker-b2=192.168.56.32")

REPO="${REPO:-$HOME/ota-project}"
KEY="${KEY:-$HOME/.ssh/ota_lab}"
INTERVAL="${INTERVAL:-5}"
OUT_DIR="$REPO/docs/evidence/measure"
BASE="$OUT_DIR/$(date +%Y%m%d-%H%M%S)-${LABEL}"
mkdir -p "$OUT_DIR"

PIDS=()
for t in "${TARGETS[@]}"; do
  name="${t%%=*}"; ip="${t#*=}"
  [[ "$ip" =~ ^[0-9.]+$ && -n "$name" ]] || { echo "잘못된 대상: $t" >&2; exit 1; }
  ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "devops@$ip" \
    "INTERVAL=$INTERVAL bash -s" > "$BASE-$name.txt" 2>&1 <<'REMOTE' &
echo "time MemAvailable_MiB MemFree_MiB psi_mem_some_avg10 psi_mem_full_avg10 r b us sy id wa st"
while true; do
  m=$(awk '/^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} END {printf "%.1f %.1f", a/1024, f/1024}' /proc/meminfo)
  if [ -r /proc/pressure/memory ]; then
    p=$(awk '{for (i=2; i<=NF; i++) if ($i ~ /^avg10=/) {split($i, a, "="); x[$1]=a[2]}} END {print (x["some"]==""?"NA":x["some"]), (x["full"]==""?"NA":x["full"])}' /proc/pressure/memory)
  else
    p="NA NA"
  fi
  v=$(vmstat 1 2 | tail -1 | awk '{print $1, $2, $13, $14, $15, $16, $17}')
  echo "$(date -u +%T) $m $p $v"
  sleep "$INTERVAL"
done
REMOTE
  PIDS+=($!)
done

stop() {
  kill "${PIDS[@]}" 2>/dev/null
  wait 2>/dev/null
  echo
  echo "저장 완료 → $BASE-*"
  exit 0
}
trap stop INT TERM
echo "수집 중 (Ctrl+C로 종료) → $BASE-*"
wait
