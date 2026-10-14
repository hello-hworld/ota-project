#!/usr/bin/env python3
"""demo-check.py — 데모 앱 실제 상태 확인 (Application · Deployment · Pod · Pod별/Service 경유 /healthz)

실행 위치: [ota-host] ~/ota-project, day7-session.env를 source한 터미널
사용법  : python3 scripts/demo-check.py <staging|production> <G|C> [증거 이름]
          예) python3 scripts/demo-check.py production C 18-prod-C-check
결과    : 화면 + docs/evidence/day7/<증거 이름>.txt (이름을 준 경우)
판정    : RESULT=PASS(0) / RESULT=FAIL(1) / 조회 실패(2)
  - Deployment spec.replicas = readyReplicas = updatedReplicas = 종료 중이 아닌 Pod 수
  - replicas 0이면 Pod가 0개가 될 때까지 최대 90초 기다린다 (python이 PID 1이라 SIGTERM을 무시 → 약 30초 걸림)
  - 모든 Pod의 spec image = <IMG_REPO>@<기대 digest>, 실행 imageID의 digest = 기대 digest
  - Pod별 /healthz와 Service(ClusterIP) /healthz SVC_N회: 모두 HTTP 200, status ok, version = 기대 version
  - production: Pod가 worker-b1, worker-b2에 하나씩
HTTP 조회는 클러스터 노드에서 한다. ota-host에서는 ClusterIP에 닿지 않고 port-forward는 Pod 1개에 고정되기 때문이다.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time

ENVS = {
    "staging": {"ctx": os.environ.get("OTA_CTX_A", "ota-a"), "node_ip": "192.168.56.21",
                "nodes": ["worker-a1"]},
    "production": {"ctx": os.environ.get("OTA_CTX_B", "ota-b"), "node_ip": "192.168.56.31",
                   "nodes": ["worker-b1", "worker-b2"]},
}
CTX_A = os.environ.get("OTA_CTX_A", "ota-a")
KEY = os.environ.get("KEY", os.path.expanduser("~/.ssh/ota_lab"))
REPO = os.environ.get("REPO", os.path.expanduser("~/ota-project"))
EV = os.environ.get("EV", os.path.join(REPO, "docs/evidence/day7"))
IMG_REPO = os.environ.get("IMG_REPO", "192.168.56.21:32000/day6/demo")
SVC_N = int(os.environ.get("SVC_N", "10"))
SEL = "app.kubernetes.io/name=ota-demo,app.kubernetes.io/instance={}"
LINES = []


def out(msg=""):
    print(msg, flush=True)
    LINES.append(msg)


def sh(args, timeout=60):
    r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr


def kjson(ctx, *args):
    rc, so, se = sh(["kubectl", "--context", ctx, *args, "-o", "json"])
    if rc != 0:
        out(f"조회 실패: kubectl --context {ctx} {' '.join(args)}: {se.strip()}")
        finish(2)
    return json.loads(so)


def finish(code, fails=None):
    if code == 0:
        out("RESULT=PASS")
    elif code == 1:
        out("RESULT=FAIL")
        for f in fails or []:
            out(f"  - {f}")
    else:
        out("RESULT=ERROR")
    if len(sys.argv) > 3:
        os.makedirs(EV, exist_ok=True)
        path = os.path.join(EV, sys.argv[3] + ".txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(LINES) + "\n")
        print(f"저장 → {path}")
    sys.exit(code)


def live_pods(ctx, ns, app):
    items = kjson(ctx, "-n", ns, "get", "pods", "-l", SEL.format(app))["items"]
    return [p for p in items if not p["metadata"].get("deletionTimestamp")], \
           [p for p in items if p["metadata"].get("deletionTimestamp")]


def http_from_node(node_ip, targets):
    """노드에서 curl. 결과: [(target, code, body)]"""
    for t in targets:
        if not re.fullmatch(r"[0-9.]+", t):
            out(f"잘못된 IP: {t}")
            finish(2)
    loop = " ".join(targets)
    remote = ("for t in " + loop + "; do "
              "b=$(curl -s -m 3 -w ' %{http_code}' http://$t:8080/healthz 2>/dev/null); "
              "echo \"$t $b\"; done")
    rc, so, se = sh(["ssh", "-n", "-i", KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                     f"devops@{node_ip}", remote], timeout=120)
    if rc != 0 and not so:
        out(f"SSH 실패 ({node_ip}): {se.strip()}")
        finish(2)
    res = []
    for line in so.splitlines():
        parts = line.split(" ")
        target, code = parts[0], parts[-1]
        body = " ".join(parts[1:-1]).strip()
        res.append((target, code, body))
    return res


def parse_body(body):
    try:
        d = json.loads(body)
        return d.get("status"), d.get("version")
    except (ValueError, AttributeError):
        return None, None


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ENVS or sys.argv[2] not in ("G", "C"):
        print(__doc__)
        sys.exit(2)
    env, img = sys.argv[1], sys.argv[2]
    cfg = ENVS[env]
    ctx, ns, app = cfg["ctx"], env, f"ota-demo-{env}"
    digest = os.environ.get(f"{img}_DIGEST", "")
    version = os.environ.get(f"{img}_VERSION", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest) or not version:
        print("G_/C_ 변수가 없다: source scripts/day7-session.env")
        sys.exit(2)
    want_image = f"{IMG_REPO}@{digest}"
    fails = []
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out(f"== demo-check {env} expect={img} digest={digest} version={version} at={now}")

    a = kjson(CTX_A, "-n", "argocd", "get", "application", app)
    st = a.get("status", {})
    op = st.get("operationState", {})
    out(f"-- application {app}: sync={st.get('sync', {}).get('status')} "
        f"health={st.get('health', {}).get('status')} compared-rev={st.get('sync', {}).get('revision')} "
        f"op={op.get('phase')} synced-rev={op.get('syncResult', {}).get('revision')}")

    d = kjson(ctx, "-n", ns, "get", "deploy", "ota-demo")
    spec_r = d["spec"].get("replicas", 1)
    ds = d.get("status", {})
    ready, upd, avail = ds.get("readyReplicas", 0), ds.get("updatedReplicas", 0), ds.get("availableReplicas", 0)
    spec_img = d["spec"]["template"]["spec"]["containers"][0]["image"]
    rpath = d["spec"]["template"]["spec"]["containers"][0].get("readinessProbe", {}).get("httpGet", {}).get("path")
    conds = {c["type"]: f"{c['status']}/{c.get('reason')}" for c in ds.get("conditions", [])}
    out(f"-- deployment: replicas={spec_r} ready={ready} updated={upd} available={avail} "
        f"readinessPath={rpath} conditions={conds}")
    out(f"   image={spec_img}")
    if spec_img != want_image:
        fails.append(f"Deployment image가 기대값과 다르다: {spec_img}")

    live, term = live_pods(ctx, ns, app)
    if spec_r == 0:
        for _ in range(45):
            if not live and not term:
                break
            time.sleep(2)
            live, term = live_pods(ctx, ns, app)
        out(f"-- pods: 실행 {len(live)}개, 종료 중 {len(term)}개 (replicas 0)")
        if live or term:
            fails.append(f"replicas 0인데 Pod가 남아 있다 (실행 {len(live)}, 종료 중 {len(term)})")
        finish(1 if fails else 0, fails)

    out("-- pods (NAME NODE PHASE READY RESTARTS IP / image / imageID)")
    nodes, ips = [], []
    for p in sorted(live, key=lambda x: x["spec"].get("nodeName", "")):
        cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
        node = p["spec"].get("nodeName", "-")
        ip = p.get("status", {}).get("podIP", "")
        rdy = cs.get("ready", False)
        out(f"   {p['metadata']['name']} {node} {p['status'].get('phase')} ready={rdy} "
            f"restarts={cs.get('restartCount', 0)} {ip}")
        out(f"     image={p['spec']['containers'][0]['image']}")
        out(f"     imageID={cs.get('imageID', '-')}")
        last = (cs.get("lastState") or {}).get("terminated", {}).get("reason")
        if last:
            fails.append(f"{p['metadata']['name']} 이전 종료 사유 {last}")
        if p["spec"]["containers"][0]["image"] != want_image:
            fails.append(f"{p['metadata']['name']} spec image 불일치")
        if cs.get("imageID", "").split("@")[-1] != digest:
            fails.append(f"{p['metadata']['name']} 실행 imageID digest 불일치: {cs.get('imageID')}")
        if not rdy:
            fails.append(f"{p['metadata']['name']} NotReady")
        nodes.append(node)
        if ip:
            ips.append(ip)
    for p in term:
        out(f"   (종료 중) {p['metadata']['name']} {p['spec'].get('nodeName', '-')}")
    if not (spec_r == ready == upd == len(live)):
        fails.append(f"수 불일치: replicas={spec_r} ready={ready} updated={upd} pods={len(live)}")
    if env == "production" and sorted(nodes) != sorted(cfg["nodes"]):
        fails.append(f"분산 불일치: {nodes} (기대 {cfg['nodes']})")
    if env == "staging" and any(n not in cfg["nodes"] for n in nodes):
        fails.append(f"배치 노드 불일치: {nodes}")

    svc = kjson(ctx, "-n", ns, "get", "svc", "ota-demo")
    cip = svc["spec"].get("clusterIP", "")
    targets = ips + [cip] * SVC_N
    res = http_from_node(cfg["node_ip"], targets)
    out(f"-- http (노드 {cfg['node_ip']}에서 curl, Service {cip}:8080 {SVC_N}회)")
    svc_ok, svc_bad = 0, []
    for target, code, body in res:
        status, ver = parse_body(body)
        good = code == "200" and status == "ok" and ver == version
        if target == cip:
            if good:
                svc_ok += 1
            else:
                svc_bad.append(f"{code} {body}")
        else:
            out(f"   pod {target}: {code} {body}")
            if not good:
                fails.append(f"Pod {target} 응답이 기대(200·ok·{version})와 다르다: {code} {body}")
    out(f"   service {cip}: {svc_ok}/{SVC_N} 정상")
    if svc_bad:
        fails.append(f"Service 응답 {len(svc_bad)}/{SVC_N}회가 기대(200·ok·{version})와 다르다. 예: {svc_bad[0]}")
    finish(1 if fails else 0, fails)


if __name__ == "__main__":
    main()
