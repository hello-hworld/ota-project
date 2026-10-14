#!/usr/bin/env bash
# =====================================================================
# install-cli.sh — ota-host의 kubectl·helm을 공식 배포물로 바꾼다 (체크섬 확인 후 ~/.local/bin에 버전별로 두고 링크)
# 실행 위치 : [ota-host] ~/ota-project
# 사용법    : ./scripts/install-cli.sh kubectl <버전> <증거 이름>   예) ./scripts/install-cli.sh kubectl 1.31.14 12-kubectl-1.31.14
#             ./scripts/install-cli.sh helm    <버전> <증거 이름>   예) ./scripts/install-cli.sh helm 3.22.0 70-helm-3.22.0
# 결과      : ~/.local/bin/<도구>-v<버전> 설치, ~/.local/bin/<도구> → 그 파일 링크
#             기존 ~/.local/bin/<도구>가 일반 파일이면 지우지 않고 <도구>-<원래 버전>으로 이름만 바꾼다(되돌리기용)
#             /usr/bin 등 다른 위치의 도구는 건드리지 않는다. PATH에서 ~/.local/bin이 앞이라 새 링크가 쓰인다
# 체크섬    : kubectl = dl.k8s.io의 kubectl.sha256, helm = get.helm.sh의 .sha256sum. 다르면 설치하지 않는다
# 주의      : 실행한 터미널에서 'hash -r' 을 해야 bash가 예전 경로를 잊는다
# =====================================================================
set -euo pipefail

TOOL="${1:-}"; V="${2:-}"; NAME="${3:-}"
[[ "$TOOL" == kubectl || "$TOOL" == helm ]] && [[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [[ -n "$NAME" ]] \
  || { echo "사용법: $0 <kubectl|helm> <버전> <증거 이름>" >&2; exit 2; }

REPO="${REPO:-$HOME/ota-project}"
EV="${EV:-$REPO/docs/evidence/k8s-upgrade}"
BIN="$HOME/.local/bin"
OUT="$EV/$NAME.txt"
mkdir -p "$BIN" "$EV"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

{
  echo "== install-cli $TOOL v$V at=$(date -u +%FT%TZ)"
  echo "before: $(type -a "$TOOL" 2>/dev/null | tr '\n' ' ')"
  case "$TOOL" in
    kubectl)
      U="https://dl.k8s.io/release/v$V/bin/linux/amd64"
      curl -fsSL -o "$D/kubectl" "$U/kubectl"
      curl -fsSL -o "$D/kubectl.sha256" "$U/kubectl.sha256"
      echo "official sha256: $(cat "$D/kubectl.sha256")"
      echo "$(cat "$D/kubectl.sha256")  $D/kubectl" | sha256sum --check
      NEW="$D/kubectl"
      ver_of() { "$1" version --client -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])'; }
      ;;
    helm)
      F="helm-v$V-linux-amd64.tar.gz"
      curl -fsSL -o "$D/$F" "https://get.helm.sh/$F"
      curl -fsSL -o "$D/$F.sha256sum" "https://get.helm.sh/$F.sha256sum"
      echo "official sha256: $(cat "$D/$F.sha256sum")"
      ( cd "$D" && sha256sum --check "$F.sha256sum" )
      tar -xzf "$D/$F" -C "$D" linux-amd64/helm
      NEW="$D/linux-amd64/helm"
      ver_of() { "$1" version --template '{{.Version}}' 2>/dev/null; }
      ;;
  esac

  if [[ -f "$BIN/$TOOL" && ! -L "$BIN/$TOOL" ]]; then
    old="$(ver_of "$BIN/$TOOL" || echo unknown)"
    [[ -e "$BIN/$TOOL-$old" ]] && { echo "STOP: $BIN/$TOOL-$old 이(가) 이미 있다"; exit 1; }
    mv "$BIN/$TOOL" "$BIN/$TOOL-$old"
    echo "기존 $BIN/$TOOL → $BIN/$TOOL-$old (보존)"
  fi
  install -m 0755 "$NEW" "$BIN/$TOOL-v$V"
  ln -sfn "$TOOL-v$V" "$BIN/$TOOL"
  got="$(ver_of "$BIN/$TOOL")"
  echo "installed: $BIN/$TOOL → $(readlink "$BIN/$TOOL") ($got)"
  [[ "$got" == "v$V" ]] || { echo "STOP: 설치 후 버전 $got != v$V"; exit 1; }
  echo "after: $(type -a "$TOOL" | tr '\n' ' ')"
  echo "RESULT=PASS (이 터미널에서 hash -r)"
} 2>&1 | tee "$OUT"
exit "${PIPESTATUS[0]}"
