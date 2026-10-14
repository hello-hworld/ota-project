#!/usr/bin/env bash
# =====================================================================
# vm-power.sh — VM 5대를 정해진 순서로 정상 종료하거나 기동한다 (콜드 백업·재기동 확인용)
# 실행 위치 : [ota-host] ~/ota-project, upg-session.env를 source한 터미널
# 사용법    : ./scripts/vm-power.sh stop  <증거 이름>   Worker → Control Plane 순서로 virsh shutdown, 모두 shut off까지 대기
#             ./scripts/vm-power.sh start <증거 이름>   Control Plane 기동 → API 응답 → Worker 기동 → 5 Node Ready까지 대기
# 결과 파일 : docs/evidence/k8s-upgrade/<증거 이름>.txt
# 규칙      : 종료 전 Agent(ci)·Staging Pod가 0개가 아니면 멈춘다
#             시간 안에 shut off가 되지 않아도 강제 종료(virsh destroy)하지 않는다 → 멈추고 원인을 본다
# =====================================================================
set -uo pipefail

ACT="${1:-}"; NAME="${2:-}"
[[ ( "$ACT" == stop || "$ACT" == start ) && -n "$NAME" ]] || { echo "사용법: $0 <stop|start> <증거 이름>" >&2; exit 2; }
REPO="${REPO:-$HOME/ota-project}"
EV="${EV:-$REPO/docs/evidence/k8s-upgrade}"
# shellcheck source=upg-lib.sh
source "$REPO/scripts/upg-lib.sh"
OUT="$EV/$NAME.txt"
mkdir -p "$EV"
STOP_ORDER=(worker-b2 worker-b1 worker-a1 cp-b cp-a)
CPS=(cp-a cp-b)
WORKERS=(worker-a1 worker-b1 worker-b2)
CTX_A="$(ctx_of a)"; CTX_B="$(ctx_of b)"

stop() { echo "STOP: $*"; echo "RESULT=STOP"; exit 1; }
state() { sudo env LC_ALL=C virsh domstate "$1" 2>/dev/null; }

sudo -v || exit 1
{
  T0=$(date +%s)
  echo "== vm-power $ACT at=$(now)"
  for vm in "${STOP_ORDER[@]}"; do echo "$vm: $(state "$vm")"; done
  if [[ "$ACT" == stop ]]; then
    a="$(pods_in "$CTX_A" ci)"; s="$(pods_in "$CTX_A" staging)"
    echo "agent(ci)=$a staging=$s"
    [[ "$a" -eq 0 && "$s" -eq 0 ]] || stop "Agent·Staging Pod가 남아 있다"
    tl "vm stop start"
    for vm in "${STOP_ORDER[@]}"; do
      [[ "$(state "$vm")" == "shut off" ]] && continue
      sudo virsh shutdown "$vm"
      for _ in $(seq 1 60); do [[ "$(state "$vm")" == "shut off" ]] && break; sleep 5; done
      [[ "$(state "$vm")" == "shut off" ]] || stop "$vm 이(가) 300초 안에 shut off가 되지 않았다 (강제 종료하지 않는다)"
      echo "$vm shut off (+$(( $(date +%s) - T0 ))s)"
    done
    tl "vm stop end"
  else
    tl "vm start start"
    for vm in "${CPS[@]}"; do [[ "$(state "$vm")" == running ]] || sudo virsh start "$vm"; done
    for ctx in "$CTX_A" "$CTX_B"; do
      ok=0
      for _ in $(seq 1 60); do
        kubectl --context "$ctx" get --raw=/readyz >/dev/null 2>&1 && { ok=1; break; }
        sleep 5
      done
      [[ $ok -eq 1 ]] || stop "$ctx API가 300초 안에 응답하지 않는다"
      echo "$ctx API ready (+$(( $(date +%s) - T0 ))s)"
    done
    for vm in "${WORKERS[@]}"; do [[ "$(state "$vm")" == running ]] || sudo virsh start "$vm"; done
    python3 "$REPO/scripts/upg-state.py" "$CTX_A" nodes - --wait 600 || stop "A Node Ready 대기 실패"
    python3 "$REPO/scripts/upg-state.py" "$CTX_B" nodes - --wait 600 || stop "B Node Ready 대기 실패"
    tl "vm start end (nodes ready)"
    echo "5 Node Ready (+$(( $(date +%s) - T0 ))s)"
  fi
  for vm in "${STOP_ORDER[@]}"; do echo "$vm: $(state "$vm")"; done
  echo "RESULT=PASS"
} 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
echo "저장 → $OUT"
exit "$rc"
