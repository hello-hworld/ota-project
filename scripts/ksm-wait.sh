#!/usr/bin/env bash
# =====================================================================
# ksm-wait.sh — 재기동 뒤 KSM 절약량(general_profit)이 안정될 때까지 기다린다 (측정 P0·P1 전에)
#   근거: 측정분석 DAY1~6 — 재기동 직후 KSM이 0에서 시작해 Host MemAvailable 차이의 부호가 뒤집혔다(DAY6 P0 → P1)
# 실행 위치 : [ota-host] ~/ota-project
# 사용법    : ./scripts/ksm-wait.sh <증거 이름>
# 판정      : INTERVAL초(기본 600) 간격 두 값의 차 < DELTA_MIB(기본 50) → RESULT=STABLE(0)
#             MAX회(기본 6, 약 60분) 안에 안정되지 않으면 RESULT=NOT_STABLE(1). 측정은 하되 비교표에 '불안정'으로 적는다
# =====================================================================
set -uo pipefail
NAME="${1:-}"
[[ -n "$NAME" ]] || { echo "사용법: $0 <증거 이름>" >&2; exit 2; }
REPO="${REPO:-$HOME/ota-project}"
EV="${EV:-$REPO/docs/evidence/k8s-upgrade}"
INTERVAL="${INTERVAL:-600}"; MAX="${MAX:-6}"; DELTA_MIB="${DELTA_MIB:-50}"
K="${KSM_DIR:-/sys/kernel/mm/ksm}"
OUT="$EV/$NAME.txt"
mkdir -p "$EV"
{
  echo "== ksm-wait interval=${INTERVAL}s max=$MAX delta<${DELTA_MIB}MiB start=$(date -u +%FT%TZ)"
  for f in run pages_to_scan sleep_millisecs merge_across_nodes use_zero_pages; do echo "$f=$(cat "$K/$f" 2>/dev/null || echo NA)"; done
  [[ -r "$K/general_profit" ]] || { echo "general_profit 없음"; echo "RESULT=NOT_STABLE"; exit 1; }
  prev="$(cat "$K/general_profit")"
  echo "$(date -u +%T) general_profit=$(( prev / 1048576 ))MiB"
  for i in $(seq 1 "$MAX"); do
    sleep "$INTERVAL"
    cur="$(cat "$K/general_profit")"
    d=$(( cur - prev )); d=${d#-}
    echo "$(date -u +%T) general_profit=$(( cur / 1048576 ))MiB delta=$(( d / 1048576 ))MiB ($i/$MAX)"
    if (( d < DELTA_MIB * 1048576 )); then echo "RESULT=STABLE"; exit 0; fi
    prev="$cur"
  done
  echo "RESULT=NOT_STABLE"
  exit 1
} 2>&1 | tee "$OUT"
exit "${PIPESTATUS[0]}"
