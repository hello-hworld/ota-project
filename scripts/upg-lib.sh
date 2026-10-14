# shellcheck shell=bash
# =====================================================================
# upg-lib.sh — K8s 업그레이드 스크립트 공통 함수 (k8s-hop.sh·calico-upgrade.sh·upgrade-check.sh·vm-power.sh가 source 한다)
# 직접 실행하지 않는다. 인증정보 없음
# =====================================================================
UPG_KEY="${KEY:-$HOME/.ssh/ota_lab}"

now()      { date -u +%FT%TZ; }
# 구간 기록: 측정 파일의 피크를 어느 작업이 만들었는지 맞춰 보는 UTC 시각표 (day7-session.env의 mark와 같은 파일)
tl()       { printf '%s %s\n' "$(now)" "$*" >> "${EV:?EV 없음}/00-timeline.txt"; }
ctx_of()   { case "$1" in a) echo "${OTA_CTX_A:-ota-a}" ;; b) echo "${OTA_CTX_B:-ota-b}" ;; *) return 1 ;; esac; }
ips_of()   { case "$1" in a) echo "192.168.56.20 192.168.56.21" ;; b) echo "192.168.56.30 192.168.56.31 192.168.56.32" ;; *) return 1 ;; esac; }
host_of()  {
  case "$1" in
    192.168.56.20) echo cp-a ;; 192.168.56.21) echo worker-a1 ;; 192.168.56.30) echo cp-b ;;
    192.168.56.31) echo worker-b1 ;; 192.168.56.32) echo worker-b2 ;; *) echo "$1" ;;
  esac
}

# 1.31.14 / v1.31.14 → 31
minor_of() { local v="${1#v}"; v="${v#*.}"; echo "${v%%.*}"; }
# 3.29.7 / v3.29.7 → 3.29
calico_minor_of() { local v="${1#v}"; echo "${v%.*}"; }

# Calico 공식 문서의 테스트 범위(Kubernetes minor 하한·상한). 문서 작성 시 docs.tigera.io 원본(tigera/docs)에서 확인한 값
calico_range() {
  case "$1" in
    3.28) echo "27 30" ;; 3.29) echo "29 32" ;; 3.30) echo "31 35" ;;
    3.31) echo "32 35" ;; 3.32) echo "34 36" ;; 3.33) echo "35 37" ;;
    *) echo "" ;;
  esac
}

# 노드 SSH (명령 하나). 실패하면 0이 아닌 종료 코드
nssh() { ssh -n -i "$UPG_KEY" -o BatchMode=yes -o ConnectTimeout=5 "devops@$1" "$2"; }

server_version() {
  kubectl --context "$1" version -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null
}
client_minor() {
  kubectl version --client -o json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["minor"].rstrip("+"))' 2>/dev/null
}
calico_version() {
  kubectl --context "$1" -n kube-system get ds calico-node \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="calico-node")].image}' 2>/dev/null \
    | sed -E 's/.*:(v[0-9]+\.[0-9]+\.[0-9]+).*/\1/'
}
kubelet_versions() {
  kubectl --context "$1" get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.nodeInfo.kubeletVersion}{"\n"}{end}'
}
runtime_versions() {
  kubectl --context "$1" get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.nodeInfo.containerRuntimeVersion}{"\n"}{end}'
}
pods_in() { kubectl --context "$1" -n "$2" get pods -o name 2>/dev/null | grep -c . || true; }
