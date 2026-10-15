#!/usr/bin/env bash
# =====================================================================
# storage-test.sh — local-path 영속성 시험: PVC 1개 → Pod1(지정 Node)에서 파일 기록 → Pod1만 삭제
#                   → Pod2(Node 지정 없음)가 같은 PVC로 같은 내용을 읽는지. PV NodeAffinity가 Pod2를 같은 Node로 보내는지도 본다
# 실행 위치 : [ota-host] ~/ota-project, day8-session.env를 source한 터미널
# 사용법    : ./scripts/storage-test.sh <context> <node> <증거 이름>            시험
#             ./scripts/storage-test.sh <context> <node> <증거 이름> --cleanup  정리(Pod·PVC·Namespace 삭제, PV·Node 디렉터리 삭제 확인)
#             예) ./scripts/storage-test.sh ota-b worker-b2 12-b-storage-test
# 결과 파일 : docs/evidence/day8/<증거 이름>.txt
# 판정      : RESULT=PASS(0) / RESULT=FAIL(1) / RESULT=STOP(2, 시작 조건 불충족 — 아무것도 만들지 않았다)
# 이미지    : 그 클러스터 local-path-config의 helperPod 이미지를 그대로 쓴다(Provisioner가 이미 받은 이미지, 추가 Pull 없음)
# 주의      : 같은 Node의 로컬 디렉터리 보존 시험이다. Node 장애 시 다른 Node로 데이터가 옮겨진다는 뜻이 아니다
# =====================================================================
set -uo pipefail

CTX="${1:-}"; NODE="${2:-}"; NAME="${3:-}"; MODE="${4:-}"
[[ -n "$CTX" && -n "$NODE" && -n "$NAME" ]] && [[ -z "$MODE" || "$MODE" == "--cleanup" ]] \
  || { echo "사용법: $0 <context> <node> <증거 이름> [--cleanup]" >&2; exit 2; }

REPO="${REPO:-$HOME/ota-project}"
KEY="${KEY:-$HOME/.ssh/ota_lab}"
EV="${EV:-$REPO/docs/evidence/day8}"
NS=day8-storage-test
OUT="$EV/$NAME.txt"
mkdir -p "$EV"
k() { kubectl --context "$CTX" "$@"; }
now() { date -u +%FT%TZ; }
fail() { echo "FAIL: $*"; echo "--- events"; k -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -15; echo "RESULT=FAIL"; exit 1; }
stop() { echo "STOP: $*"; echo "RESULT=STOP"; exit 2; }
node_ip() { k get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
nodessh() { ssh -n -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "devops@$1" "$2"; }

pod_manifest() {   # pod_manifest <이름> <이미지> <nodeSelector 사용 여부 1|0>
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
  labels: {app.kubernetes.io/part-of: day8-storage-test}
spec:
  terminationGracePeriodSeconds: 1
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile: {type: RuntimeDefault}
$( [[ "$3" == 1 ]] && printf '  nodeSelector:\n    kubernetes.io/hostname: %s\n' "$NODE" )
  containers:
    - name: t
      image: $2
      imagePullPolicy: IfNotPresent
      command: ["sleep", "3600"]
      resources:
        requests: {cpu: 5m, memory: 8Mi}
        limits: {cpu: 50m, memory: 32Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: {drop: ["ALL"]}
      volumeMounts:
        - {name: data, mountPath: /data}
  volumes:
    - name: data
      persistentVolumeClaim: {claimName: t-data}
EOF
}

{
  T0=$(date +%s)
  echo "== storage-test context=$CTX node=$NODE mode=${MODE:-test} start=$(now)"

  if [[ "$MODE" == "--cleanup" ]]; then
    PV="$(k -n "$NS" get pvc t-data -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
    DIR="$( [[ -n "$PV" ]] && k get pv "$PV" -o jsonpath='{.spec.hostPath.path}{.spec.local.path}' 2>/dev/null)"
    echo "PV=${PV:-없음} DIR=${DIR:-없음}"
    k -n "$NS" delete pod --all --wait=true --timeout=60s || fail "Pod 삭제"
    k -n "$NS" delete pvc t-data --wait=true --timeout=60s --ignore-not-found || fail "PVC 삭제"
    if [[ -n "$PV" ]]; then
      for _ in $(seq 1 30); do k get pv "$PV" >/dev/null 2>&1 || break; sleep 2; done
      k get pv "$PV" >/dev/null 2>&1 && fail "PV $PV 가 60초 안에 지워지지 않았다 (reclaimPolicy·helper Pod 확인)"
      echo "PV $PV 삭제됨 (reclaimPolicy Delete)"
      if [[ -n "$DIR" ]]; then
        r="$(nodessh "$(node_ip "$NODE")" "sudo test -e '$DIR' && echo 남아있음 || echo 없음")" || fail "SSH $NODE"
        echo "Node 디렉터리 $DIR: $r"
        [[ "$r" == 없음 ]] || fail "helper teardown 뒤에도 디렉터리가 남아 있다"
      fi
    fi
    k delete ns "$NS" --wait=true --timeout=60s || fail "Namespace 삭제"
    echo "end=$(now) (+$(( $(date +%s) - T0 ))s)"
    echo "RESULT=PASS"
    exit 0
  fi

  echo "-- 시작 조건"
  k get sc local-path -o custom-columns='NAME:.metadata.name,PROVISIONER:.provisioner,RECLAIM:.reclaimPolicy,BINDING:.volumeBindingMode' \
    || stop "StorageClass local-path 없음"
  k -n local-path-storage rollout status deploy/local-path-provisioner --timeout=60s || stop "Provisioner 준비 안 됨"
  k -n local-path-storage get pods -o wide
  if k get ns "$NS" >/dev/null 2>&1; then
    left="$(k -n "$NS" get pods,pvc --no-headers 2>/dev/null | grep -c . || true)"
    [[ "$left" -eq 0 ]] || stop "$NS 에 이전 시험 리소스가 있다 → --cleanup 먼저"
  fi
  IMG="$(k -n local-path-storage get cm local-path-config -o jsonpath='{.data.helperPod\.yaml}' | sed -n 's/^ *image: *//p' | head -1)"
  [[ -n "$IMG" ]] || stop "helperPod 이미지를 읽지 못했다"
  echo "시험 Pod 이미지 = helperPod 이미지: $IMG"

  echo "-- PVC 생성 ($(now))"
  k create ns "$NS" --dry-run=client -o yaml | k apply -f - || fail "Namespace"
  cat <<EOF | k apply -f - || fail "PVC 생성"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: t-data
  namespace: $NS
spec:
  storageClassName: local-path
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 1Gi}
EOF
  sleep 3
  echo "소비 Pod 전 PVC: $(k -n "$NS" get pvc t-data -o jsonpath='{.status.phase}') (WaitForFirstConsumer면 Pending이 정상)"

  echo "-- Pod1 (nodeSelector $NODE) ($(now))"
  pod_manifest t-writer "$IMG" 1 | k apply -f - || fail "Pod1 생성"
  k -n "$NS" wait --for=condition=Ready pod/t-writer --timeout=180s || fail "Pod1 Ready 대기 (helper Pod·이미지 Pull 확인)"
  k -n "$NS" get pod t-writer -o wide
  MARK="day8-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  k -n "$NS" exec t-writer -- sh -c "printf '%s\n' '$MARK' > /data/marker && sync && cat /data/marker" || fail "파일 기록"
  echo "기록한 식별 문자열: $MARK"

  echo "-- PV"
  PV="$(k -n "$NS" get pvc t-data -o jsonpath='{.spec.volumeName}')"
  [[ -n "$PV" ]] || fail "PVC가 PV에 묶이지 않았다"
  k get pv "$PV" -o custom-columns='NAME:.metadata.name,CAP:.spec.capacity.storage,RECLAIM:.spec.persistentVolumeReclaimPolicy,STATUS:.status.phase,CLAIM:.spec.claimRef.name,SC:.spec.storageClassName'
  echo "nodeAffinity: $(k get pv "$PV" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].key}={.spec.nodeAffinity.required.nodeSelectorTerms[*].matchExpressions[*].values}')"
  DIR="$(k get pv "$PV" -o jsonpath='{.spec.hostPath.path}{.spec.local.path}')"
  echo "실제 경로: $DIR"
  IP="$(node_ip "$NODE")"
  echo "-- $NODE($IP)의 실제 디렉터리"
  nodessh "$IP" "sudo ls -ld '$DIR' && sudo cat '$DIR/marker' && df -h / | tail -1" || fail "Node에서 디렉터리 확인"

  echo "-- Pod1만 삭제 ($(now))"
  k -n "$NS" delete pod t-writer --wait=true --timeout=60s || fail "Pod1 삭제"
  echo "Pod1 삭제 후 PVC=$(k -n "$NS" get pvc t-data -o jsonpath='{.status.phase}') PV=$(k get pv "$PV" -o jsonpath='{.status.phase}')"

  echo "-- Pod2 (Node 지정 없음 → PV NodeAffinity가 배치를 정해야 한다) ($(now))"
  pod_manifest t-reader "$IMG" 0 | k apply -f - || fail "Pod2 생성"
  k -n "$NS" wait --for=condition=Ready pod/t-reader --timeout=180s || fail "Pod2 Ready 대기"
  k -n "$NS" get pod t-reader -o wide
  N2="$(k -n "$NS" get pod t-reader -o jsonpath='{.spec.nodeName}')"
  GOT="$(k -n "$NS" exec t-reader -- cat /data/marker)" || fail "Pod2에서 읽기"
  echo "Pod2 node=$N2, 읽은 값: $GOT"
  [[ "$N2" == "$NODE" ]] || fail "Pod2가 $N2 에 배치됐다 (기대 $NODE)"
  [[ "$GOT" == "$MARK" ]] || fail "내용이 다르다"
  echo "image digest: $(k -n "$NS" get pod t-reader -o jsonpath='{.status.containerStatuses[0].imageID}')"
  echo "end=$(now) (+$(( $(date +%s) - T0 ))s)"
  echo "RESULT=PASS"
} 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
echo "저장 → $OUT"
exit "$rc"
