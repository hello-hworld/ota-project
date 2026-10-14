#!/usr/bin/env bash
# =====================================================================
# k8s-hop.sh — 클러스터 하나를 Kubernetes minor 하나만 올리고 판정한다: 사전 관문 → 08-k8s-upgrade.yml → 사후 관문
# 실행 위치 : [ota-host] ~/ota-project, upg-session.env를 source한 터미널
# 사용법    : ./scripts/k8s-hop.sh <a|b> <목표 버전> <증거 이름>
#             예) ./scripts/k8s-hop.sh a 1.31.14 13-hop-1.31.14-a
# 결과 파일 : docs/evidence/k8s-upgrade/<증거 이름>.txt (Ansible 출력 포함)
# 판정      : RESULT=PASS(0) / RESULT=STOP(1). STOP이면 그 자리에서 원인을 찾는다(옵션을 바꿔 다시 실행하지 않는다)
# 사전 관문 : ota-host kubectl minor = 목표 minor
#             API 서버 = 목표의 바로 전 minor (같은 버전이면 재실행으로 보고 남은 Node만 올린다)
#             kubelet은 모두 바로 전 minor 또는 목표 버전, 모든 Node Ready·cordon 없음, 비정상 Pod 없음
#             Calico 테스트 범위에 목표 minor 포함, 목표 이하에서 제거되는 deprecated API 요청 없음
#             Node 디스크 사용률 < 80%, containerd 2.x, 목표 1.35 이상이면 cgroup v2
#             A는 Agent(ci)·Staging Pod 0개
# 사후 관문 : API 서버·모든 kubelet = 목표, 제어부·kube-proxy·CoreDNS·Calico 정상, 모든 Pod Ready(최대 15분)
#             A: Registry 응답, Argo CD Application 2개 Synced·Healthy / B: demo-check production PASS
# =====================================================================
set -uo pipefail

C="${1:-}"; V="${2:-}"; NAME="${3:-}"
usage() { echo "사용법: $0 <a|b> <목표 버전 예: 1.31.14> <증거 이름>" >&2; exit 2; }
[[ "$C" == a || "$C" == b ]] || usage
[[ "$V" =~ ^1\.[0-9]+\.[0-9]+$ ]] || usage
[[ -n "$NAME" ]] || usage

REPO="${REPO:-$HOME/ota-project}"
EV="${EV:-$REPO/docs/evidence/k8s-upgrade}"
PROD_IMG="${PROD_IMG:-C}"
# shellcheck source=upg-lib.sh
source "$REPO/scripts/upg-lib.sh"
CTX="$(ctx_of "$C")"
T="$(minor_of "$V")"
P=$((T - 1))
OUT="$EV/$NAME.txt"
mkdir -p "$EV"

stop() { echo "STOP: $*"; echo "RESULT=STOP"; exit 1; }
st()   { python3 "$REPO/scripts/upg-state.py" "$CTX" "$@"; }

{
  T0=$(date +%s)
  echo "== k8s-hop cluster=$C context=$CTX target=v$V start=$(now)"

  echo "-- 사전 관문"
  CM="$(client_minor)"
  [[ "$CM" == "$T" ]] || stop "ota-host kubectl minor=$CM, 목표 minor=$T → 먼저 ./scripts/install-cli.sh kubectl $V 후 hash -r"
  echo "kubectl client minor=$CM OK"

  SV="$(server_version "$CTX")"
  [[ -n "$SV" ]] || stop "API 서버 버전을 읽지 못했다"
  if [[ "$SV" == "v$V" ]]; then
    echo "API 서버가 이미 v$V → 재실행: Control Plane은 apply를 건너뛰고 남은 Node만 올린다"
  elif [[ "$(minor_of "$SV")" == "$P" ]]; then
    echo "API 서버 $SV → v$V (minor $P → $T)"
  else
    stop "API 서버 $SV 는 목표 v$V 의 바로 전 minor가 아니다 (minor를 건너뛰지 않는다)"
  fi

  while IFS='=' read -r node kv; do
    [[ -z "$node" ]] && continue
    km="$(minor_of "$kv")"
    [[ "$kv" == "v$V" || "$km" == "$P" ]] || stop "$node kubelet $kv 가 minor $P 또는 v$V 가 아니다"
  done < <(kubelet_versions "$CTX")

  st nodes - || stop "Node 상태"
  st pods    || stop "비정상 Pod가 있다 (업그레이드 전에 정리)"

  CV="$(calico_version "$CTX")"
  read -r LO HI <<< "$(calico_range "$(calico_minor_of "$CV")")"
  [[ -n "${LO:-}" ]] || stop "Calico $CV 의 테스트 범위를 모른다"
  (( T >= LO && T <= HI )) || stop "Calico $CV 테스트 범위 1.$LO~1.$HI 에 목표 1.$T 가 없다 → Calico 먼저"
  echo "Calico $CV (테스트 범위 1.$LO~1.$HI) OK"

  st deprecated "$T" || stop "목표 버전 이하에서 제거되는 API를 쓰는 요청이 있다"

  if [[ "$C" == a ]]; then
    a="$(pods_in "$CTX" ci)"; s="$(pods_in "$CTX" staging)"
    echo "agent(ci)=$a staging=$s"
    [[ "$a" -eq 0 && "$s" -eq 0 ]] || stop "Agent·Staging Pod가 남아 있다"
  fi

  while IFS='=' read -r node rt; do
    [[ -z "$node" ]] && continue
    [[ "$rt" == containerd://2.* ]] || stop "$node 런타임 $rt (containerd 2.x 필요)"
  done < <(runtime_versions "$CTX")
  for ip in $(ips_of "$C"); do
    # shellcheck disable=SC2016  # 작은따옴표 안의 $()는 Node 셸에서 펼친다(의도)
    r="$(nssh "$ip" 'echo "$(df --output=pcent / | tail -1 | tr -dc 0-9) $(stat -fc %T /sys/fs/cgroup)"')" \
      || stop "SSH $ip 실패"
    read -r pct cg <<< "$r"
    echo "$(host_of "$ip") disk=${pct}% cgroup=$cg"
    [[ "$pct" =~ ^[0-9]+$ ]] || stop "$(host_of "$ip") 디스크 사용률을 읽지 못했다: '$r'"
    (( pct < 80 )) || stop "$(host_of "$ip") 디스크 사용률 ${pct}%"
    if (( T >= 35 )); then
      [[ "$cg" == cgroup2fs ]] || stop "$(host_of "$ip") cgroup v1 — kubelet 1.35부터 기본으로 시작을 거부한다"
    fi
  done
  echo "사전 관문 통과 ($(now))"

  echo "-- 변경 전 Node·제어부 이미지"
  kubectl --context "$CTX" get nodes -o wide
  kubectl --context "$CTX" -n kube-system get pods -o custom-columns='NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image' \
    | grep -E 'NAME|kube-apiserver|kube-controller|kube-scheduler|etcd|kube-proxy|coredns'

  echo "-- Ansible 08-k8s-upgrade.yml ($(now))"
  tl "hop v$V cluster $C ansible start"
  ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_RETRY_FILES_ENABLED=0 \
    ansible-playbook -i "$REPO/ansible/inventory/hosts.ini" "$REPO/ansible/playbooks/08-k8s-upgrade.yml" \
      -e "cluster=$C" -e "k8s_version=$V"
  rc=$?
  tl "hop v$V cluster $C ansible end rc=$rc"
  echo "ansible rc=$rc end=$(now) (+$(( $(date +%s) - T0 ))s)"
  [[ $rc -eq 0 ]] || stop "Ansible 실패 (위 출력의 마지막 실패 작업부터 본다. cordon된 Node가 있는지 확인)"

  echo "-- 사후 관문"
  st server "$V"              || stop "API 서버 버전"
  st nodes "$V" --wait 300    || stop "Node 버전·상태"
  st addons "$V" --wait 300   || stop "제어부·kube-proxy·CoreDNS"
  st calico - --wait 300      || stop "Calico"
  st pods --wait 900          || stop "Pod 준비 (15분)"

  if [[ "$C" == a ]]; then
    curl -fsS -m 10 http://192.168.56.21:32000/v2/day6/demo/tags/list || stop "Registry 응답 없음"
    echo
    ok=0
    for _ in $(seq 1 30); do
      apps="$(kubectl --context "$CTX" -n argocd get applications.argoproj.io \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}')"
      if [[ -n "$apps" ]] && ! grep -v -E ' Synced Healthy$' <<< "$apps" | grep -q .; then ok=1; break; fi
      sleep 10
    done
    echo "$apps"
    [[ $ok -eq 1 ]] || stop "Argo CD Application이 5분 안에 Synced·Healthy가 되지 않았다"
  else
    python3 "$REPO/scripts/demo-check.py" production "$PROD_IMG" "$NAME-demo" || stop "Production 데모 확인 실패"
  fi

  echo "-- 변경 후 Node"
  kubectl --context "$CTX" get nodes -o wide
  echo "end=$(now) (+$(( $(date +%s) - T0 ))s)"
  echo "RESULT=PASS"
} 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
echo "저장 → $OUT"
exit "$rc"
