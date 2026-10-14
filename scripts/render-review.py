#!/usr/bin/env python3
"""render-review.py — helm template 결과 검토: 종류 수, 워크로드별 replicas·nodeSelector·이미지·requests/limits, Secret 값 유무, Service
실행 위치: [ota-host] ~/ota-project
사용법  : python3 scripts/render-review.py <렌더링 파일.yaml>
"""
import sys, yaml, collections
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
print("kinds:", dict(sorted(collections.Counter(d["kind"] for d in docs).items())))
def mib(q):
    q = str(q)
    if q.endswith("Gi"): return float(q[:-2]) * 1024
    if q.endswith("Mi"): return float(q[:-2])
    return float(q) / 1048576
total = 0.0
for d in docs:
    if d["kind"] not in ("Deployment", "StatefulSet", "Job"):
        continue
    s = d["spec"]; t = s["template"]["spec"]
    print(f'{d["kind"]:11} {d["metadata"]["name"]:34} replicas={s.get("replicas", "-")} nodeSelector={t.get("nodeSelector")}')
    for kind in ("initContainers", "containers"):
        for c in t.get(kind, []):
            r = c.get("resources", {})
            print(f'   {kind[:4]} {c["name"]:24} {c["image"]}  req={r.get("requests")} lim={r.get("limits")}')
    if d["kind"] != "Job":
        n = s.get("replicas", 1)
        total += n * sum(mib(c.get("resources", {}).get("requests", {}).get("memory", 0)) for c in t["containers"])
for d in docs:
    if d["kind"] == "Secret":
        keys = sorted((d.get("data") or {}).keys()) + sorted((d.get("stringData") or {}).keys())
        print("Secret", d["metadata"]["name"], "값 있는 키:", keys or "없음")
    if d["kind"] == "Service":
        print("Service", d["metadata"]["name"], d["spec"].get("type", "ClusterIP"), [p["port"] for p in d["spec"]["ports"]])
print(f"상시 Pod memory requests 합계: {total:.0f}Mi  (init container는 Pod 단위로 max(init, 합계)라 더하지 않는다. Job 제외)")
