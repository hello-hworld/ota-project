#!/usr/bin/env bash
# =====================================================================
# gitops-sync.sh — Argo CD 수동 Sync 1회: Push 확인 → Refresh → Diff → Sync → Wait → 상태 기록
# 실행 위치 : [ota-host] ~/ota-project (day7-session.env를 source하고 argocd login을 마친 터미널)
# 사용법    : ./scripts/gitops-sync.sh <app> <증거 이름> [--expect-fail]
#             예) ./scripts/gitops-sync.sh ota-demo-staging 10-staging-G-sync
# 결과 파일 : docs/evidence/day7/<증거 이름>.txt
# 판정      : 기본          → Sync 성공 + Synced·Healthy + Sync한 revision = origin/main 이면 RESULT=PASS(0)
#             --expect-fail → Sync 성공 후 Healthy에 도달하지 못하면 RESULT=EXPECTED_FAIL(0), Healthy가 되면 1
# 규칙      : origin/main에 Push되지 않은 상태로는 Sync하지 않는다
#             argocd app diff 종료 코드 1은 '차이 있음'(정상), 0은 '차이 없음', 2 이상은 오류다
# =====================================================================
set -uo pipefail

APP="${1:-}"; NAME="${2:-}"; MODE="${3:-}"
if [[ -z "$APP" || -z "$NAME" ]] || [[ -n "$MODE" && "$MODE" != "--expect-fail" ]]; then
  echo "사용법: $0 <app> <증거 이름> [--expect-fail]" >&2
  exit 2
fi

REPO="${REPO:-$HOME/ota-project}"
CTX_A="${OTA_CTX_A:-ota-a}"
EV="${EV:-$REPO/docs/evidence/day7}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-180}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"
FAIL_WAIT_TIMEOUT="${FAIL_WAIT_TIMEOUT:-240}"
ALLOW_NO_DIFF="${ALLOW_NO_DIFF:-0}"
OUT="$EV/$NAME.txt"
mkdir -p "$EV"
command -v argocd >/dev/null || { echo "argocd CLI 없음" >&2; exit 2; }

now()   { date -u +%FT%TZ; }
appf()  { kubectl --context "$CTX_A" -n argocd get application "$APP" -o jsonpath="$1" 2>/dev/null; }
state() {
  printf 'state: sync=%s health=%s compared-rev=%s op=%s synced-rev=%s op-start=%s op-end=%s\n' \
    "$(appf '{.status.sync.status}')" "$(appf '{.status.health.status}')" \
    "$(appf '{.status.sync.revision}')" "$(appf '{.status.operationState.phase}')" \
    "$(appf '{.status.operationState.syncResult.revision}')" \
    "$(appf '{.status.operationState.startedAt}')" "$(appf '{.status.operationState.finishedAt}')"
}
stop()  { echo "STOP: $*"; echo "RESULT=STOP"; exit 1; }

{
  echo "== $NAME  app=$APP  mode=${MODE:-normal}  start=$(now)"
  git -C "$REPO" fetch -q origin main || stop "git fetch 실패"
  LOCAL="$(git -C "$REPO" rev-parse HEAD)"
  REMOTE="$(git -C "$REPO" rev-parse origin/main)"
  echo "git: HEAD=$LOCAL origin/main=$REMOTE"
  [[ "$LOCAL" == "$REMOTE" ]] || stop "HEAD와 origin/main이 다르다 (Push 안 됨 또는 로컬이 뒤처짐)"
  git -C "$REPO" --no-pager log -1 --format='git: last commit %h %s'
  appf '{.metadata.name}' >/dev/null || stop "Application $APP 없음"

  echo "-- refresh ($(now))"
  argocd app get "$APP" --refresh -o json >/dev/null || stop "refresh 실패"
  for _ in $(seq 1 30); do
    [[ "$(appf '{.status.sync.revision}')" == "$REMOTE" ]] && break
    sleep 2
  done
  [[ "$(appf '{.status.sync.revision}')" == "$REMOTE" ]] || stop "60초 안에 Argo CD가 $REMOTE 를 비교 대상으로 잡지 못했다"
  state

  echo "-- diff ($(now))"
  argocd app diff "$APP"; rc=$?
  case "$rc" in
    1) echo "diff: 차이 있음 (rc=1, 정상)" ;;
    0) if [[ "$ALLOW_NO_DIFF" == "1" ]]; then echo "diff: 차이 없음 (rc=0, ALLOW_NO_DIFF=1)"
       else stop "diff: 차이 없음 (rc=0) — 바꾼 values가 렌더링 결과에 반영되지 않았다"; fi ;;
    *) stop "diff 오류 (rc=$rc)" ;;
  esac

  echo "-- sync"
  T0=$(date +%s); echo "sync-start=$(now)"
  argocd app sync "$APP" --timeout "$SYNC_TIMEOUT" || stop "sync 실패 (Sync operation 자체가 끝나지 않았거나 실패)"
  echo "sync-end=$(now) (+$(( $(date +%s) - T0 ))s)"

  echo "-- wait"
  if [[ "$MODE" == "--expect-fail" ]]; then
    argocd app wait "$APP" --sync --health --timeout "$FAIL_WAIT_TIMEOUT"; rc=$?
    echo "wait rc=$rc end=$(now) (+$(( $(date +%s) - T0 ))s)  ← 의도한 실패: 0이 아니어야 한다"
    state
    H="$(appf '{.status.health.status}')"
    if [[ $rc -ne 0 && "$H" != "Healthy" ]]; then
      echo "RESULT=EXPECTED_FAIL health=$H"
      exit 0
    fi
    echo "RESULT=UNEXPECTED health=$H (실패를 의도했는데 Healthy)"
    exit 1
  fi
  argocd app wait "$APP" --sync --health --timeout "$WAIT_TIMEOUT"; rc=$?
  echo "wait rc=$rc end=$(now) (+$(( $(date +%s) - T0 ))s)"
  state
  [[ $rc -eq 0 ]] || stop "Synced·Healthy에 도달하지 못했다"
  SR="$(appf '{.status.operationState.syncResult.revision}')"
  [[ "$SR" == "$REMOTE" ]] || stop "Sync한 revision($SR)이 origin/main($REMOTE)과 다르다"
  echo "RESULT=PASS"
} 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
echo "저장 → $OUT"
exit "$rc"
