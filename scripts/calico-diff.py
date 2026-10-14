#!/usr/bin/env python3
"""calico-diff.py — 설치된 Calico가 원본 manifest에서 바뀐 곳이 있는지 확인한다 (업그레이드 manifest에 같은 수정을 옮겨야 하는지 판단)

실행 위치: [ota-host] ~/ota-project
사용법  : python3 scripts/calico-diff.py <context> <원본 manifest>
          예) python3 scripts/calico-diff.py ota-a k8s/calico/calico-v3.28.2.yaml
비교 대상: ConfigMap kube-system/calico-config 의 data
          DaemonSet kube-system/calico-node, Deployment kube-system/calico-kube-controllers 의
          컨테이너·init 컨테이너 이름, env(값·참조), command·args  (이미지 태그는 비교하지 않는다)
판정    : 차이 없음 → RESULT=SAME(0)
          CALICO_IPV4POOL_* env만 다름 → RESULT=INFO_ONLY(0). 이 env는 IPPool이 하나도 없을 때 기본 풀을 만들 때만 쓰인다.
            이미 IPPool이 있으므로 업그레이드 manifest에 옮기지 않아도 동작이 바뀌지 않는다(풀은 datastore에 남는다)
          그 밖의 차이 → RESULT=DIFF(1). 같은 수정을 업그레이드 manifest마다 옮겨야 한다 → 업그레이드를 시작하지 않는다
          조회·읽기 실패 → 2
"""
import json
import subprocess
import sys

import yaml

INFO_PREFIX = ("CALICO_IPV4POOL_", "CALICO_IPV6POOL_")


def live(ctx, kind, name):
    r = subprocess.run(["kubectl", "--context", ctx, "-n", "kube-system", "get", kind, name, "-o", "json"],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        print(f"조회 실패: {kind}/{name}: {r.stderr.strip()}")
        sys.exit(2)
    return json.loads(r.stdout)


def from_manifest(path, kind, name):
    for d in yaml.safe_load_all(open(path, encoding="utf-8")):
        if d and d.get("kind") == kind and d.get("metadata", {}).get("name") == name:
            return d
    print(f"manifest에 {kind}/{name} 없음: {path}")
    sys.exit(2)


def env_map(container):
    m = {}
    for e in container.get("env", []) or []:
        if "value" in e:
            m[e["name"]] = ("value", str(e["value"]))
        elif "valueFrom" in e:
            vf = e["valueFrom"]
            if "fieldRef" in vf:
                m[e["name"]] = ("fieldRef", vf["fieldRef"].get("fieldPath"))
            elif "configMapKeyRef" in vf:
                r = vf["configMapKeyRef"]
                m[e["name"]] = ("configMapKeyRef", f"{r.get('name')}/{r.get('key')} optional={r.get('optional', False)}")
            elif "secretKeyRef" in vf:
                r = vf["secretKeyRef"]
                m[e["name"]] = ("secretKeyRef", f"{r.get('name')}/{r.get('key')} optional={r.get('optional', False)}")
            elif "resourceFieldRef" in vf:
                r = vf["resourceFieldRef"]
                m[e["name"]] = ("resourceFieldRef", f"{r.get('containerName', '')}/{r.get('resource')}")
            else:
                m[e["name"]] = ("valueFrom", json.dumps(vf, sort_keys=True))
        else:
            m[e["name"]] = ("value", "")
    return m


def compare_workload(kind, name, lv, mf, diffs, infos):
    for section in ("initContainers", "containers"):
        lc = {c["name"]: c for c in lv["spec"]["template"]["spec"].get(section, []) or []}
        mc = {c["name"]: c for c in mf["spec"]["template"]["spec"].get(section, []) or []}
        for cname in sorted(set(lc) | set(mc)):
            where = f"{kind}/{name} {section}/{cname}"
            if cname not in lc:
                diffs.append(f"{where}: 설치본에 없음 (manifest에만 있음)")
                continue
            if cname not in mc:
                diffs.append(f"{where}: 설치본에만 있음")
                continue
            le, me = env_map(lc[cname]), env_map(mc[cname])
            for k in sorted(set(le) | set(me)):
                if le.get(k) != me.get(k):
                    line = f"{where} env {k}: 설치본={le.get(k)} manifest={me.get(k)}"
                    (infos if k.startswith(INFO_PREFIX) else diffs).append(line)
            for fld in ("command", "args"):
                if (lc[cname].get(fld) or []) != (mc[cname].get(fld) or []):
                    diffs.append(f"{where} {fld}: 설치본={lc[cname].get(fld)} manifest={mc[cname].get(fld)}")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    ctx, path = sys.argv[1], sys.argv[2]
    diffs, infos = [], []

    lcm = live(ctx, "configmap", "calico-config").get("data", {}) or {}
    mcm = from_manifest(path, "ConfigMap", "calico-config").get("data", {}) or {}
    for k in sorted(set(lcm) | set(mcm)):
        a, b = lcm.get(k), mcm.get(k)
        if k == "cni_network_config" and a is not None and b is not None:
            try:                                   # JSON 의미가 같으면 공백 차이는 무시한다
                a, b = json.loads(a), json.loads(b)
            except ValueError:
                pass
        if a != b:
            diffs.append(f"ConfigMap/calico-config data.{k}: 설치본={lcm.get(k)!r} manifest={mcm.get(k)!r}")

    compare_workload("DaemonSet", "calico-node", live(ctx, "daemonset", "calico-node"),
                     from_manifest(path, "DaemonSet", "calico-node"), diffs, infos)
    compare_workload("Deployment", "calico-kube-controllers", live(ctx, "deployment", "calico-kube-controllers"),
                     from_manifest(path, "Deployment", "calico-kube-controllers"), diffs, infos)

    print(f"== calico-diff context={ctx} manifest={path}")
    for i in infos:
        print(f"  INFO {i}")
    for d in diffs:
        print(f"  DIFF {d}")
    if diffs:
        print("RESULT=DIFF")
        sys.exit(1)
    print("RESULT=INFO_ONLY" if infos else "RESULT=SAME")


if __name__ == "__main__":
    main()
