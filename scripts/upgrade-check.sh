#!/usr/bin/env bash
# =====================================================================
# upgrade-check.sh — 업그레이드 전후 상태 기록과 판정 (A·B 클러스터, Node 5대, ota-host 도구)
# 실행 위치 : [ota-host] ~/ota-project, upg-session.env를 source한 터미널
# 사용법    : ./scripts/upgrade-check.sh <기대 K8s 버전> <기대 Calico 버전> <증거 이름>
#             예) ./scripts/upgrade-check.sh 1.30.14 3.28.2 01-state-before
#                 ./scripts/upgrade-check.sh 1.36.5  3.32.2 80-state-after
# 결과 파일 : docs/evidence/k8s-upgrade/<증거 이름>.txt
# 판정      : CHECK 줄의 FAIL 수. 0이면 RESULT=PASS(0), 아니면 RESULT=FAIL(1)
#             판정 항목: API 서버·kubelet·제어부 버전, Node 상태, 비정상 Pod, Calico 버전·상태, 1.36 이하에서 제거되는
#             deprecated API 요청, cgroup v2, containerd 2.x, Node 디스크 < 80%, Agent·Staging 0개, Argo CD 앱 상태
#             나머지(kubeadm-config, kube-proxy mode, kubeadm-flags.env, 인증서 만료, PDB, IPPool, 도구 버전)는 기록만 한다
# =====================================================================
set -uo pipefail

K="${1:-}"; CAL="${2:-}"; NAME="${3:-}"
[[ "$K" =~ ^1\.[0-9]+\.[0-9]+$ && "$CAL" =~ ^3\.[0-9]+\.[0-9]+$ && -n "$NAME" ]] \
  || { echo "사용법: $0 <K8s 버전> <Calico 버전> <증거 이름>" >&2; exit 2; }

REPO="${REPO:-$HOME/ota-project}"
EV="${EV:-$REPO/docs/evidence/k8s-upgrade}"
# shellcheck source=upg-lib.sh
source "$REPO/scripts/upg-lib.sh"
OUT="$EV/$NAME.txt"
mkdir -p "$EV"
FAILS=0
chk() {   # chk <이름> <명령...> : 명령 종료 코드로 CHECK 줄을 남긴다
  local n="$1"; shift
  if "$@"; then echo "CHECK $n PASS"; else echo "CHECK $n FAIL"; FAILS=$((FAILS + 1)); fi
}
sec() { echo; echo "===== $* ====="; }
# shellcheck disable=SC2329  # chk가 간접 호출한다
runtime_ok() {   # 모든 Node 런타임이 containerd 2.x
  local out; out="$(runtime_versions "$1")" || return 1
  echo "$out"
  [[ -n "$out" ]] && ! grep -v '=containerd://2\.' <<< "$out" | grep -q .
}
# shellcheck disable=SC2329  # chk가 간접 호출한다
apps_ok() {      # Argo CD Application이 1개 이상이고 모두 Synced·Healthy
  [[ -n "$1" ]] && ! grep -v -E ' Synced Healthy$' <<< "$1" | grep -q .
}

{
  echo "== upgrade-check expect k8s=v$K calico=v$CAL at=$(now) git=$(git -C "$REPO" log -1 --format=%h)"

  sec "ota-host 도구"
  for t in kubectl helm argocd ansible-playbook; do echo "$t → $(type -a "$t" 2>/dev/null | tr '\n' ' ')"; done
  kubectl version --client 2>&1 | head -1
  helm version --short 2>&1
  argocd version --client --short 2>&1 | head -1

  for c in a b; do
    CTX="$(ctx_of "$c")"
    sec "Cluster $c ($CTX)"
    chk "$c-server"  python3 "$REPO/scripts/upg-state.py" "$CTX" server "$K"
    chk "$c-nodes"   python3 "$REPO/scripts/upg-state.py" "$CTX" nodes "$K"
    chk "$c-addons"  python3 "$REPO/scripts/upg-state.py" "$CTX" addons "$K"
    chk "$c-pods"    python3 "$REPO/scripts/upg-state.py" "$CTX" pods
    chk "$c-calico"  python3 "$REPO/scripts/upg-state.py" "$CTX" calico "$CAL"
    chk "$c-deprecated" python3 "$REPO/scripts/upg-state.py" "$CTX" deprecated 36
    python3 "$REPO/scripts/upg-state.py" "$CTX" ippools
    chk "$c-runtime" runtime_ok "$CTX"

    echo "--- Calico 설치 방식 (kube-system의 calico-node = manifest, calico-system = operator)"
    kubectl --context "$CTX" get ds -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name' | grep -E 'NS|calico' || true
    kubectl --context "$CTX" get ns tigera-operator calico-system 2>&1 | tail -n +1
    echo "--- kubeadm-config ClusterConfiguration"
    kubectl --context "$CTX" -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}'; echo
    echo "--- kube-proxy mode (빈 값 = iptables)"
    kubectl --context "$CTX" -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^mode:' || echo "(mode 줄 없음)"
    echo "--- kubelet-config (cgroupDriver·failCgroupV1)"
    kubectl --context "$CTX" -n kube-system get cm kubelet-config -o jsonpath='{.data.kubelet}' | grep -E 'cgroupDriver|failCgroupV1|containerRuntimeEndpoint' || true
    echo "--- PodDisruptionBudget (drain을 막을 수 있다)"
    kubectl --context "$CTX" get pdb -A 2>&1
    if [[ "$c" == a ]]; then
      a="$(pods_in "$CTX" ci)"; s="$(pods_in "$CTX" staging)"
      echo "--- agent(ci)=$a staging=$s"
      chk "a-agent-staging-zero" test "$a" -eq 0 -a "$s" -eq 0
      echo "--- Argo CD Application"
      apps="$(kubectl --context "$CTX" -n argocd get applications.argoproj.io \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>&1)"
      echo "$apps"
      chk "a-argocd-apps" apps_ok "$apps"
      echo "--- Registry"
      curl -fsS -m 10 http://192.168.56.21:32000/v2/day6/demo/tags/list; echo
    fi

    for ip in $(ips_of "$c"); do
      h="$(host_of "$ip")"
      sec "Node $h ($ip)"
      # shellcheck disable=SC2016  # 작은따옴표 안의 $는 Node 셸에서 펼친다(의도)
      nssh "$ip" '
        echo "kubeadm=$(kubeadm version -o short 2>&1) kubelet=$(kubelet --version 2>&1) kubectl=$(kubectl version --client 2>&1 | head -1)"
        echo "containerd=$(containerd --version 2>&1)"
        echo "kernel=$(uname -r) cgroup=$(stat -fc %T /sys/fs/cgroup)"
        echo "disk_pct=$(df --output=pcent / | tail -1 | tr -dc 0-9)"
        df -h / | tail -1
        echo "--- apt 저장소 / hold"
        cat /etc/apt/sources.list.d/kubernetes.list
        apt-mark showhold | xargs
        echo "--- /var/lib/kubelet/kubeadm-flags.env"
        sudo -n cat /var/lib/kubelet/kubeadm-flags.env
        sudo -n test -f /var/lib/kubelet/instance-config.yaml && echo "instance-config.yaml 있음" || echo "instance-config.yaml 없음"
        echo "--- 이미지 수 $(sudo -n crictl --runtime-endpoint unix:///run/containerd/containerd.sock images -q 2>/dev/null | wc -l)"
        if [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
          echo "--- 인증서 만료"
          sudo -n kubeadm certs check-expiration 2>&1 | sed -n "/CERTIFICATE /,/^$/p;/CERTIFICATE AUTHORITY/,/^$/p"
          echo "--- etcd 데이터·kubeadm 백업 폴더 크기"
          sudo -n du -sh /var/lib/etcd /etc/kubernetes/tmp 2>&1
        fi' 2>&1 | tee "$EV/.node-$h.tmp" || echo "SSH 실패: $h"
      pct="$(sed -n 's/^disk_pct=//p' "$EV/.node-$h.tmp")"
      cg="$(sed -n 's/.*cgroup=//p' "$EV/.node-$h.tmp")"
      chk "$h-disk<80" test "${pct:-100}" -lt 80
      chk "$h-cgroup2" test "$cg" = cgroup2fs
      rm -f "$EV/.node-$h.tmp"
    done
  done

  sec "SUMMARY"
  echo "CHECK FAIL 수: $FAILS"
  if [[ $FAILS -eq 0 ]]; then echo "RESULT=PASS"; else echo "RESULT=FAIL"; fi
  [[ $FAILS -eq 0 ]]
} 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
echo "저장 → $OUT"
exit "$rc"
