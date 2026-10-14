#!/usr/bin/env bash
# =====================================================================
# calico-upgrade.sh — manifest로 설치한 Calico를 minor 하나만 올리고 판정한다 (Kubernetes API datastore)
# 실행 위치 : [ota-host] ~/ota-project, upg-session.env를 source한 터미널
# 사용법    : ./scripts/calico-upgrade.sh <a|b> <Calico 버전> <증거 이름>
#             예) ./scripts/calico-upgrade.sh a 3.29.7 10-calico-3.29.7-a
# 결과 파일 : docs/evidence/k8s-upgrade/<증거 이름>.txt (+ <증거 이름>-ippools-before/after.txt)
# 방법      : Calico 공식 'Upgrading an installation that uses manifests and the Kubernetes API datastore'와 같다
#             → kubectl apply --server-side --force-conflicts -f calico.yaml (고정해 둔 k8s/calico/calico-v<버전>.yaml)
# 사전 관문 : manifest 해시 = k8s/calico/SHA256SUMS, 현재 Calico = 정해 둔 바로 전 버전(같으면 재실행 → 확인만)
#             현재 API 서버 minor가 새 Calico의 테스트 범위 안, 모든 Node Ready, 비정상 Pod 없음, A는 Agent·Staging 0개
# 사후 관문 : calico-node·calico-kube-controllers = 새 버전·준비 완료, 모든 Node NetworkUnavailable=False,
#             IPPool 전후 동일, 모든 Pod Ready, A: Registry 응답 / B: demo-check production PASS
# 판정      : RESULT=PASS(0) / RESULT=STOP(1)
# =====================================================================
set -uo pipefail

C="${1:-}"; V="${2:-}"; NAME="${3:-}"
usage() { echo "사용법: $0 <a|b> <Calico 버전 예: 3.29.7> <증거 이름>" >&2; exit 2; }
[[ "$C" == a || "$C" == b ]] || usage
[[ "$V" =~ ^3\.[0-9]+\.[0-9]+$ ]] || usage
[[ -n "$NAME" ]] || usage

REPO="${REPO:-$HOME/ota-project}"
EV="${EV:-$REPO/docs/evidence/k8s-upgrade}"
PROD_IMG="${PROD_IMG:-C}"
# shellcheck source=upg-lib.sh
source "$REPO/scripts/upg-lib.sh"
CTX="$(ctx_of "$C")"
MAN="$REPO/k8s/calico/calico-v$V.yaml"
OUT="$EV/$NAME.txt"
mkdir -p "$EV"

# 이 문서의 Calico 경로: 3.28.2 → 3.29.7 → 3.30.7 → 3.31.7 → 3.32.2 (minor 하나씩)
declare -A PREV=([3.29.7]=3.28.2 [3.30.7]=3.29.7 [3.31.7]=3.30.7 [3.32.2]=3.31.7)

stop() { echo "STOP: $*"; echo "RESULT=STOP"; exit 1; }
st()   { python3 "$REPO/scripts/upg-state.py" "$CTX" "$@"; }

{
  T0=$(date +%s)
  echo "== calico-upgrade cluster=$C context=$CTX target=v$V start=$(now)"

  echo "-- 사전 관문"
  [[ -n "${PREV[$V]:-}" ]] || stop "이 문서의 경로에 없는 버전 $V"
  [[ -f "$MAN" ]] || stop "$MAN 없음 (STEP 0)"
  ( cd "$REPO/k8s/calico" && grep " calico-v$V.yaml\$" SHA256SUMS | sha256sum -c - ) || stop "manifest 해시 불일치"

  CV="$(calico_version "$CTX")"
  APPLY=1
  if [[ "$CV" == "v$V" ]]; then
    echo "이미 v$V → 재실행: 적용하지 않고 확인만 한다"
    APPLY=0
  elif [[ "$CV" != "v${PREV[$V]}" ]]; then
    stop "현재 Calico $CV, 이 단계의 시작 버전은 v${PREV[$V]}"
  fi

  SV="$(server_version "$CTX")"
  SM="$(minor_of "$SV")"
  read -r LO HI <<< "$(calico_range "$(calico_minor_of "$V")")"
  (( SM >= LO && SM <= HI )) || stop "API 서버 $SV 가 Calico $V 테스트 범위 1.$LO~1.$HI 밖"
  echo "Calico $CV → v$V, API 서버 $SV (새 Calico 테스트 범위 1.$LO~1.$HI) OK"

  st nodes - || stop "Node 상태"
  st pods    || stop "비정상 Pod가 있다"
  if [[ "$C" == a ]]; then
    a="$(pods_in "$CTX" ci)"; s="$(pods_in "$CTX" staging)"
    echo "agent(ci)=$a staging=$s"
    [[ "$a" -eq 0 && "$s" -eq 0 ]] || stop "Agent·Staging Pod가 남아 있다"
  fi
  st ippools > "$EV/$NAME-ippools-before.txt" || stop "IPPool 조회 실패"
  grep 'ippool ' "$EV/$NAME-ippools-before.txt"

  if [[ $APPLY -eq 1 ]]; then
    echo "-- apply ($(now))"
    tl "calico v$V cluster $C apply start"
    kubectl --context "$CTX" apply --server-side --force-conflicts -f "$MAN" || stop "apply 실패"
    echo "-- rollout ($(now))"
    kubectl --context "$CTX" -n kube-system rollout status ds/calico-node --timeout=900s || stop "calico-node rollout"
    kubectl --context "$CTX" -n kube-system rollout status deploy/calico-kube-controllers --timeout=300s || stop "kube-controllers rollout"
    tl "calico v$V cluster $C rollout end"
    echo "rollout end=$(now) (+$(( $(date +%s) - T0 ))s)"
  fi

  echo "-- 사후 관문"
  st calico "$V" --wait 300 || stop "Calico 상태"
  st ippools > "$EV/$NAME-ippools-after.txt" || stop "IPPool 조회 실패"
  if diff <(grep 'ippool ' "$EV/$NAME-ippools-before.txt") <(grep 'ippool ' "$EV/$NAME-ippools-after.txt"); then
    echo "IPPool 전후 동일"
  else
    stop "IPPool이 바뀌었다"
  fi
  st nodes - --wait 300 || stop "Node 상태"
  st pods --wait 600    || stop "Pod 준비 (10분)"
  if [[ "$C" == a ]]; then
    curl -fsS -m 10 http://192.168.56.21:32000/v2/day6/demo/tags/list || stop "Registry 응답 없음"
    echo
  else
    python3 "$REPO/scripts/demo-check.py" production "$PROD_IMG" "$NAME-demo" || stop "Production 데모 확인 실패"
  fi
  echo "end=$(now) (+$(( $(date +%s) - T0 ))s)"
  echo "RESULT=PASS"
} 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
echo "저장 → $OUT"
exit "$rc"
