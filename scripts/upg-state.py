#!/usr/bin/env python3
"""upg-state.py — K8s 업그레이드 관문용 상태 판정 (kubectl --context로 읽기만 한다)

실행 위치: [ota-host] ~/ota-project, upg-session.env를 source한 터미널
사용법  : python3 scripts/upg-state.py <context> <검사> [인자] [--wait 초]
  server   <버전>        API 서버 gitVersion = v<버전>
  nodes    <버전|->      모든 Node Ready·스케줄 가능, kubelet = v<버전> ('-'이면 버전 비교 생략)
  pods                   Running·Ready가 아닌 Pod 없음 (Succeeded 제외, 종료 중 Pod도 실패로 본다)
  addons   <버전>        apiserver·controller-manager·scheduler·kube-proxy 이미지 태그 = v<버전>, kube-proxy·CoreDNS 준비 완료
  calico   <버전|->      calico-node·calico-kube-controllers 이미지 태그 = v<버전>, 모두 준비 완료, Node NetworkUnavailable=False
  ippools                IPPool 요약 한 줄씩 (전후 비교용, 판정 없음)
  deprecated <minor>     요청된 deprecated API 중 removed_release <= 1.<minor> 인 것이 없음
  --wait 초              PASS가 될 때까지 10초 간격으로 다시 본다 (기본 0 = 한 번만)
판정    : 마지막 줄 'CHECK <검사> PASS|FAIL', 종료 코드 0(PASS) / 1(FAIL) / 2(조회 실패·사용법 오류)
"""
import json
import re
import subprocess
import sys
import time


class QueryError(Exception):
    pass


def kubectl(ctx, *args, raw=False):
    cmd = ["kubectl", "--context", ctx, *args]
    if not raw:
        cmd += ["-o", "json"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise QueryError(f"{' '.join(cmd)}: {r.stderr.strip()[:300]}")
    return r.stdout if raw else json.loads(r.stdout)


def tag(image):
    """registry/name:tag@sha256:... → tag"""
    image = image.split("@", 1)[0]
    last = image.rsplit("/", 1)[-1]
    return last.split(":", 1)[1] if ":" in last else ""


def want_v(version):
    return version if version.startswith("v") else "v" + version


def check_server(ctx, version):
    out = []
    v = kubectl(ctx, "version")
    got = v.get("serverVersion", {}).get("gitVersion", "")
    out.append(f"server {got} (client {v.get('clientVersion', {}).get('gitVersion', '')})")
    fails = [] if got == want_v(version) else [f"API 서버 {got} != {want_v(version)}"]
    return out, fails


def check_nodes(ctx, version):
    out, fails = [], []
    for n in kubectl(ctx, "get", "nodes")["items"]:
        name = n["metadata"]["name"]
        info = n["status"]["nodeInfo"]
        conds = {c["type"]: c["status"] for c in n["status"].get("conditions", [])}
        unsched = n["spec"].get("unschedulable", False)
        out.append(f"node {name} ready={conds.get('Ready')} unschedulable={unsched} kubelet={info['kubeletVersion']} "
                   f"runtime={info['containerRuntimeVersion']} kernel={info['kernelVersion']}")
        if conds.get("Ready") != "True":
            fails.append(f"{name} NotReady")
        if unsched:
            fails.append(f"{name} cordon 상태(unschedulable)")
        if version != "-" and info["kubeletVersion"] != want_v(version):
            fails.append(f"{name} kubelet {info['kubeletVersion']} != {want_v(version)}")
        for t in ("MemoryPressure", "DiskPressure", "PIDPressure"):
            if conds.get(t) == "True":
                fails.append(f"{name} {t}")
    return out, fails


def pod_problem(p):
    phase = p["status"].get("phase")
    if p["metadata"].get("deletionTimestamp"):
        return "종료 중(Terminating)"
    if phase == "Succeeded":
        return None
    if phase != "Running":
        reasons = [cs.get("state", {}).get("waiting", {}).get("reason")
                   for cs in p["status"].get("containerStatuses", []) or []]
        reasons = [r for r in reasons if r]
        return f"phase={phase}" + (f" ({','.join(reasons)})" if reasons else "")
    bad = [cs["name"] for cs in p["status"].get("containerStatuses", []) or [] if not cs.get("ready")]
    if bad:
        return f"NotReady 컨테이너 {','.join(bad)}"
    return None


def check_pods(ctx, _arg=None):
    out, fails = [], []
    items = kubectl(ctx, "get", "pods", "-A")["items"]
    for p in items:
        prob = pod_problem(p)
        if prob:
            fails.append(f"{p['metadata']['namespace']}/{p['metadata']['name']} {p['spec'].get('nodeName', '-')} {prob}")
    out.append(f"pods 전체 {len(items)}개, 문제 {len(fails)}개")
    return out, fails


def check_addons(ctx, version):
    out, fails = [], []
    want = want_v(version)
    pods = kubectl(ctx, "-n", "kube-system", "get", "pods")["items"]
    for comp in ("kube-apiserver", "kube-controller-manager", "kube-scheduler", "etcd"):
        ps = [p for p in pods if p["metadata"].get("labels", {}).get("component") == comp]
        if not ps:
            fails.append(f"{comp} Pod 없음")
            continue
        for p in ps:
            img = p["spec"]["containers"][0]["image"]
            prob = pod_problem(p)
            out.append(f"{comp} {p['metadata']['name']} image={img} {'OK' if not prob else prob}")
            if comp != "etcd" and tag(img) != want:
                fails.append(f"{p['metadata']['name']} 이미지 {tag(img)} != {want}")
            if prob:
                fails.append(f"{p['metadata']['name']} {prob}")
    ds = kubectl(ctx, "-n", "kube-system", "get", "ds", "kube-proxy")
    img = ds["spec"]["template"]["spec"]["containers"][0]["image"]
    st = ds["status"]
    out.append(f"kube-proxy image={img} desired={st.get('desiredNumberScheduled')} updated={st.get('updatedNumberScheduled')} "
               f"ready={st.get('numberReady')}")
    if tag(img) != want:
        fails.append(f"kube-proxy 이미지 {tag(img)} != {want}")
    if not (st.get("desiredNumberScheduled") == st.get("updatedNumberScheduled") == st.get("numberReady")):
        fails.append("kube-proxy 갱신·준비 미완료")
    dep = kubectl(ctx, "-n", "kube-system", "get", "deploy", "coredns")
    img = dep["spec"]["template"]["spec"]["containers"][0]["image"]
    want_r = dep["spec"].get("replicas", 1)
    ready = dep.get("status", {}).get("readyReplicas", 0)
    upd = dep.get("status", {}).get("updatedReplicas", 0)
    out.append(f"coredns image={img} replicas={want_r} ready={ready} updated={upd}")
    if not (want_r == ready == upd):
        fails.append(f"CoreDNS 준비 미완료 ({ready}/{want_r}, updated {upd})")
    return out, fails


def check_calico(ctx, version):
    out, fails = [], []
    ds = kubectl(ctx, "-n", "kube-system", "get", "ds", "calico-node")
    st = ds["status"]
    imgs = [c["image"] for c in ds["spec"]["template"]["spec"]["containers"]]
    out.append(f"calico-node images={imgs} desired={st.get('desiredNumberScheduled')} "
               f"updated={st.get('updatedNumberScheduled')} ready={st.get('numberReady')}")
    if not (st.get("desiredNumberScheduled") == st.get("updatedNumberScheduled") == st.get("numberReady")):
        fails.append("calico-node 갱신·준비 미완료")
    dep = kubectl(ctx, "-n", "kube-system", "get", "deploy", "calico-kube-controllers")
    kimg = dep["spec"]["template"]["spec"]["containers"][0]["image"]
    ready = dep.get("status", {}).get("readyReplicas", 0)
    upd = dep.get("status", {}).get("updatedReplicas", 0)
    want_r = dep["spec"].get("replicas", 1)
    out.append(f"calico-kube-controllers image={kimg} replicas={want_r} ready={ready} updated={upd}")
    if not (want_r == ready == upd):
        fails.append("calico-kube-controllers 준비 미완료")
    if version != "-":
        for img in imgs + [kimg]:
            if tag(img) != want_v(version):
                fails.append(f"Calico 이미지 {img} 태그 != {want_v(version)}")
    for n in kubectl(ctx, "get", "nodes")["items"]:
        c = {x["type"]: x for x in n["status"].get("conditions", [])}.get("NetworkUnavailable")
        s = c["status"] if c else "없음"
        r = c.get("reason", "") if c else ""
        out.append(f"node {n['metadata']['name']} NetworkUnavailable={s} {r}")
        if c and c["status"] != "False":
            fails.append(f"{n['metadata']['name']} NetworkUnavailable={s}")
    return out, fails


def check_ippools(ctx, _arg=None):
    out = []
    for p in sorted(kubectl(ctx, "get", "ippools.crd.projectcalico.org")["items"], key=lambda x: x["metadata"]["name"]):
        s = p["spec"]
        out.append(f"ippool {p['metadata']['name']} cidr={s.get('cidr')} blockSize={s.get('blockSize')} "
                   f"ipipMode={s.get('ipipMode')} vxlanMode={s.get('vxlanMode')} natOutgoing={s.get('natOutgoing')} "
                   f"disabled={s.get('disabled', False)} nodeSelector={s.get('nodeSelector')}")
    return out, []


METRIC = re.compile(r'^apiserver_requested_deprecated_apis\{(?P<labels>[^}]*)\}\s+(?P<value>\S+)')
LABEL = re.compile(r'(\w+)="([^"]*)"')


def check_deprecated(ctx, minor):
    out, fails = [], []
    target = int(minor)
    text = kubectl(ctx, "get", "--raw", "/metrics", raw=True)
    n = 0
    for line in text.splitlines():
        m = METRIC.match(line)
        if not m:
            continue
        n += 1
        lab = dict(LABEL.findall(m.group("labels")))
        rr = lab.get("removed_release", "")
        api = f"{lab.get('group') or 'core'}/{lab.get('version')} {lab.get('resource')}"
        out.append(f"deprecated 요청: {api} removed_release={rr or '-'}")
        mm = re.fullmatch(r"1\.(\d+)", rr)
        if mm and int(mm.group(1)) <= target:
            fails.append(f"{api}: 1.{mm.group(1)}에서 제거됨 (목표 1.{target})")
    if n == 0:
        out.append("deprecated API 요청 기록 없음 (API 서버 시작 이후)")
    return out, fails


CHECKS = {
    "server": (check_server, True),
    "nodes": (check_nodes, True),
    "pods": (check_pods, False),
    "addons": (check_addons, True),
    "calico": (check_calico, True),
    "ippools": (check_ippools, False),
    "deprecated": (check_deprecated, True),
}


def main():
    args = sys.argv[1:]
    wait = 0
    if "--wait" in args:
        i = args.index("--wait")
        try:
            wait = int(args[i + 1])
        except (IndexError, ValueError):
            print(__doc__)
            sys.exit(2)
        del args[i:i + 2]
    if len(args) < 2 or args[1] not in CHECKS:
        print(__doc__)
        sys.exit(2)
    ctx, name = args[0], args[1]
    fn, needs_arg = CHECKS[name]
    if needs_arg and len(args) < 3:
        print(f"{name}: 인자가 필요하다")
        sys.exit(2)
    arg = args[2] if len(args) > 2 else None
    deadline = time.time() + wait
    while True:
        try:
            out, fails = fn(ctx, arg)
        except (QueryError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError) as e:
            out, fails = [f"조회 실패: {e}"], None
        if (fails == [] ) or time.time() >= deadline:
            break
        time.sleep(10)
    print(f"== {name} context={ctx} arg={arg or '-'} at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    for line in out:
        print("  " + line)
    if fails is None:
        print(f"CHECK {name} ERROR")
        sys.exit(2)
    for f in fails:
        print(f"  - {f}")
    print(f"CHECK {name} {'PASS' if not fails else 'FAIL'}")
    sys.exit(0 if not fails else 1)


if __name__ == "__main__":
    main()
