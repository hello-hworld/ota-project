#!/usr/bin/env bash
# =====================================================================
# http-watch.sh — Service(ClusterIP) 경유 /healthz 연속 조회: 롤링 업데이트·실패 주입 중 실제 실패 요청 수를 센다
# 실행 위치 : [ota-host] ~/ota-project, 별도 터미널 (day7-session.env를 source)
# 사용법    : ./scripts/http-watch.sh <staging|production> <초> <증거 이름>
#             예) ./scripts/http-watch.sh production 600 21-s2-http
# 결과 파일 : docs/evidence/day7/<증거 이름>.txt — 요청마다 'UTC시각 HTTP코드 version', 끝에 SUMMARY
# 방식      : 클러스터 노드에서 curl로 ClusterIP를 INTERVAL초(기본 0.5)마다 조회한다
#             (ota-host에서는 ClusterIP에 닿지 않고, port-forward는 Pod 1개에 고정되어 Service 검증이 아니다)
#             시간이 다 되거나 Ctrl+C를 누르면 멈추고 SUMMARY를 남긴다
# =====================================================================
set -uo pipefail

ENV="${1:-}"; DUR="${2:-}"; NAME="${3:-}"
case "$ENV" in
  staging)    CTX="${OTA_CTX_A:-ota-a}"; NODE=192.168.56.21 ;;
  production) CTX="${OTA_CTX_B:-ota-b}"; NODE=192.168.56.31 ;;
  *) ENV="" ;;
esac
if [[ -z "$ENV" || ! "$DUR" =~ ^[0-9]+$ || -z "$NAME" ]]; then
  echo "사용법: $0 <staging|production> <초> <증거 이름>" >&2
  exit 2
fi

REPO="${REPO:-$HOME/ota-project}"
KEY="${KEY:-$HOME/.ssh/ota_lab}"
EV="${EV:-$REPO/docs/evidence/day7}"
INTERVAL="${INTERVAL:-0.5}"
OUT="$EV/$NAME.txt"
mkdir -p "$EV"

IP="$(kubectl --context "$CTX" -n "$ENV" get svc ota-demo -o jsonpath='{.spec.clusterIP}')"
[[ "$IP" =~ ^[0-9.]+$ ]] || { echo "Service ota-demo의 ClusterIP를 얻지 못했다: '$IP'" >&2; exit 2; }

echo "== http-watch $ENV svc=$IP:8080 node=$NODE duration=${DUR}s interval=${INTERVAL}s start=$(date -u +%FT%TZ)" > "$OUT"
ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "devops@$NODE" \
  "DUR=$DUR IP=$IP INTERVAL=$INTERVAL bash -s" >> "$OUT" 2>&1 <<'REMOTE' &
end=$(( $(date +%s) + DUR ))
while [ "$(date +%s)" -lt "$end" ]; do
  t=$(date -u +%T.%3N)
  b=$(curl -s -m 2 -w ' %{http_code}' "http://$IP:8080/healthz" 2>/dev/null)
  v=$(printf '%s' "$b" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
  c=${b##* }
  echo "$t ${c:-000} ${v:--}"
  sleep "$INTERVAL"
done
REMOTE
PID=$!
trap 'kill "$PID" 2>/dev/null' INT TERM
tail -n +1 -f --pid="$PID" "$OUT" &
TPID=$!
wait "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
wait "$TPID" 2>/dev/null
trap - INT TERM

{
  echo
  echo "===== SUMMARY ($(date -u +%FT%TZ)) ====="
  awk 'NF==3 && $1 ~ /^[0-9][0-9]:/ {
         n++; v[$3]++
         if ($2 == "200") ok++
         else { bad++; if (first == "") first = $1; last = $1 }
       }
       END {
         printf "total=%d ok(200)=%d fail=%d\n", n, ok, bad
         if (bad > 0) printf "fail window: %s ~ %s\n", first, last
         for (k in v) printf "version %s = %d\n", k, v[k]
       }' "$OUT"
} | tee -a "$OUT"
echo "저장 → $OUT"
