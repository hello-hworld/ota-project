#!/usr/bin/env bash
# =====================================================================
# import-kubeconfig.sh — cp-a·cp-b의 관리자 kubeconfig를 받아 ota-a·ota-b context 하나로 합친다 (최초 1회)
# 실행 위치 : [ota-host] ~/ota-project, 녹화를 멈춘 별도 터미널
# 사용법    : ./scripts/import-kubeconfig.sh
# 결과      : ~/.kube/ota-lab.json (권한 0600, 저장소 밖). 이미 있으면 덮어쓰지 않고 생략한다
# 주의      : 결과 파일은 인증정보다. 내용을 화면에 출력하거나 저장소·증거에 넣지 않는다
#             인증정보가 든 임시 파일은 성공·실패와 관계없이 끝날 때 지운다
# =====================================================================
set -euo pipefail
set +x
umask 077

KEY="${KEY:-$HOME/.ssh/ota_lab}"
CP_A="${CP_A:-192.168.56.20}"
CP_B="${CP_B:-192.168.56.30}"
export OTA_KUBECONFIG_FILE="${OTA_KUBECONFIG_FILE:-$HOME/.kube/ota-lab.json}"

if [[ -e "$OTA_KUBECONFIG_FILE" ]]; then
  echo "이미 있음: $OTA_KUBECONFIG_FILE → 가져오기 생략, 1-3에서 확인만 한다"
  exit 0
fi
mkdir -p "$(dirname "$OTA_KUBECONFIG_FILE")"
OTA_KUBE_TMP="$(mktemp -d)"
export OTA_KUBE_TMP
trap 'rm -rf "$OTA_KUBE_TMP"' EXIT

fetch() {   # $1 = Control Plane IP, $2 = a|b
  ssh -n -i "$KEY" -o BatchMode=yes -o ConnectTimeout=5 "devops@$1" \
    'kubectl config view --raw --flatten --minify -o json' > "$OTA_KUBE_TMP/$2.json"
}
fetch "$CP_A" a
fetch "$CP_B" b

python3 - <<'PY'
import json
import os
from pathlib import Path

tmp = Path(os.environ["OTA_KUBE_TMP"])
target = Path(os.environ["OTA_KUBECONFIG_FILE"])
merged = {
    "apiVersion": "v1", "kind": "Config", "preferences": {},
    "clusters": [], "users": [], "contexts": [], "current-context": "ota-a",
}
for side in ("a", "b"):
    source = json.loads((tmp / f"{side}.json").read_text())
    assert len(source["clusters"]) == len(source["users"]) == len(source["contexts"]) == 1
    cluster, user, context = source["clusters"][0], source["users"][0], source["contexts"][0]
    cluster["name"] = f"ota-cluster-{side}"
    user["name"] = f"ota-admin-{side}"
    context["name"] = f"ota-{side}"
    context["context"]["cluster"] = cluster["name"]
    context["context"]["user"] = user["name"]
    merged["clusters"].append(cluster)
    merged["users"].append(user)
    merged["contexts"].append(context)
with target.open("x") as stream:
    json.dump(merged, stream, indent=2)
target.chmod(0o600)
print(f"Created {target}: contexts ota-a, ota-b")
PY
