#!/usr/bin/env python3
"""prom-check.py — 클러스터 하나의 Prometheus가 오늘 필요한 지표를 실제로 모으는지 판정한다 (Targets·최근 수집·실제 샘플)

실행 위치: [ota-host] ~/ota-project, day8-session.env를 source한 터미널
사용법  : python3 scripts/prom-check.py <a|b> [증거 이름]
          예) python3 scripts/prom-check.py a 40-prom-a-check
조회 경로: kubectl get --raw → 그 클러스터 API 서버 → Service monitoring/prometheus-server (port-forward 불필요)
          PROM_URL을 주면 그 주소로 직접 조회한다 (예: PROM_URL=http://192.168.56.32:30909 → B의 NodePort 경로 확인)
판정    : RESULT=PASS(0) / RESULT=FAIL(1) / RESULT=ERROR(2, 조회 자체 실패)
  - /-/ready 응답
  - job 4개(prometheus, kubernetes-nodes, kubernetes-nodes-cadvisor, kubernetes-service-endpoints)의 모든 Target이 up,
    마지막 수집이 STALE_S초(기본 90 = 30초 간격 × 3) 이내
  - kubernetes-nodes·cadvisor Target 수 = Node 수, node-exporter Target이 Node마다 1개, kube-state-metrics Target 1개
  - 실제 샘플: node-exporter(node_uname_info)·kubelet(kubelet_running_pods)·cAdvisor(container_memory_working_set_bytes)가
    기대 Node 모두에서 나오고, kube-state-metrics가 Node 수·Pod·requests를 보여 준다. 샘플 시각이 STALE_S초 이내
  - 기록만: Control Plane 별도 job(API 서버·etcd·scheduler·controller-manager) 수집 여부, TSDB 시계열 수·디스크·Prometheus 메모리,
    job별 최대 scrape 시간
  - UP_WINDOW(예: 30m)를 주면: 그 구간 동안 4개 job의 up 최솟값이 1인지(수집 끊김 없음) 판정하고,
    구간 최대 scrape 시간·Prometheus RSS 최대를 기록한다 (CI 뒤 확인용)
조회 실패는 0으로 바꾸지 않고 RESULT=ERROR로 끝낸다.
"""
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

CLUSTERS = {
    "a": {"ctx": os.environ.get("OTA_CTX_A", "ota-a"), "nodes": {"cp-a", "worker-a1"}},
    "b": {"ctx": os.environ.get("OTA_CTX_B", "ota-b"), "nodes": {"cp-b", "worker-b1", "worker-b2"}},
}
NS = os.environ.get("MON_NS", "monitoring")
SVC = os.environ.get("PROM_SVC", "http:prometheus-server:80")
REPO = os.environ.get("REPO", os.path.expanduser("~/ota-project"))
EV = os.environ.get("EV", os.path.join(REPO, "docs/evidence/day8"))
STALE_S = int(os.environ.get("STALE_S", "90"))
UP_WINDOW = os.environ.get("UP_WINDOW", "")
JOBS = ("prometheus", "kubernetes-nodes", "kubernetes-nodes-cadvisor", "kubernetes-service-endpoints")
LINES = []


class QueryError(Exception):
    pass


def out(msg=""):
    print(msg, flush=True)
    LINES.append(msg)


def finish(code, fails=()):
    if code == 0:
        out("RESULT=PASS")
    elif code == 1:
        out("RESULT=FAIL")
        for f in fails:
            out(f"  - {f}")
    else:
        out("RESULT=ERROR")
    if len(sys.argv) > 2:
        os.makedirs(EV, exist_ok=True)
        path = os.path.join(EV, sys.argv[2] + ".txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(LINES) + "\n")
        print(f"저장 → {path}")
    sys.exit(code)


def raw(ctx, path):
    if os.environ.get("PROM_URL"):
        try:
            with urllib.request.urlopen(os.environ["PROM_URL"].rstrip("/") + path, timeout=30) as r:
                return r.read().decode()
        except OSError as e:
            raise QueryError(f"{path}: {e}")
    url = f"/api/v1/namespaces/{NS}/services/{SVC}/proxy{path}"
    r = subprocess.run(["kubectl", "--context", ctx, "get", "--raw", url], capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise QueryError(f"{path}: {r.stderr.strip()[:300]}")
    return r.stdout


def api(ctx, path, **params):
    q = ("?" + urllib.parse.urlencode(params)) if params else ""
    d = json.loads(raw(ctx, path + q))
    if d.get("status") != "success":
        raise QueryError(f"{path}: {d.get('errorType')} {d.get('error')}")
    return d["data"]


def query(ctx, expr):
    return api(ctx, "/api/v1/query", query=expr)["result"]


def label_set(res, label):
    return {r["metric"].get(label, "") for r in res}


def rfc3339_epoch(s):
    """Prometheus의 lastScrape(로컬 시간대 오프셋, 나노초) → epoch. 읽지 못하면 None"""
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)$", s or "")
    if not m:
        return None
    frac = (m.group(2) or ".0")[:7]
    tz = "+00:00" if m.group(3) == "Z" else m.group(3)
    return datetime.datetime.fromisoformat(m.group(1) + frac + tz).timestamp()


def age(res):
    """가장 오래된 샘플의 나이(초)"""
    if not res:
        return None
    return max(time.time() - float(r["value"][0]) for r in res)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in CLUSTERS:
        print(__doc__)
        sys.exit(2)
    c = CLUSTERS[sys.argv[1]]
    ctx, want = c["ctx"], c["nodes"]
    fails = []
    via = os.environ.get("PROM_URL") or f"kubectl --context {ctx} → {NS}/{SVC}"
    out(f"== prom-check cluster={sys.argv[1]} via={via} "
        f"at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} 기대 Node={sorted(want)}")
    try:
        out(f"-- ready: {raw(ctx, '/-/ready').strip()}")
        bi = api(ctx, "/api/v1/status/buildinfo")
        out(f"-- version: {bi.get('version')} (go {bi.get('goVersion')})")
        flags = api(ctx, "/api/v1/status/flags")
        out(f"-- retention: time={flags.get('storage.tsdb.retention.time')} size={flags.get('storage.tsdb.retention.size')} "
            f"lifecycle={flags.get('web.enable-lifecycle')}")

        targets = api(ctx, "/api/v1/targets", state="active")["activeTargets"]
        out(f"-- targets (활성 {len(targets)}개)")
        now = time.time()
        by_job = {}
        for t in targets:
            job = t["labels"].get("job", "")
            by_job.setdefault(job, []).append(t)
            ls = t.get("lastScrape", "")
            e = rfc3339_epoch(ls)
            a = None if e is None else now - e
            lab = t["labels"]
            who = lab.get("node") or lab.get("kubernetes_io_hostname") or lab.get("instance", "")
            svc = lab.get("service", "")
            out(f"   {job:32} {t['health']:7} {who:12} {svc:40} "
                f"age={'NA' if a is None else f'{a:.0f}s'} dur={t.get('lastScrapeDuration', 0):.3f}s "
                f"{('err=' + t['lastError']) if t.get('lastError') else ''}")
            if job in JOBS:
                if t["health"] != "up":
                    fails.append(f"{job} {who} {svc} health={t['health']} {t.get('lastError', '')}")
                if a is None or a > STALE_S:
                    fails.append(f"{job} {who} {svc} 마지막 수집이 {STALE_S}초보다 오래됐다 (age={a})")
        for job in JOBS:
            if job not in by_job:
                fails.append(f"job {job} 의 Target이 없다")
        for job in ("kubernetes-nodes", "kubernetes-nodes-cadvisor"):
            got = {t["labels"].get("kubernetes_io_hostname", "") for t in by_job.get(job, [])}
            if got != want:
                fails.append(f"{job} Target Node {sorted(got)} != 기대 {sorted(want)}")
        se = by_job.get("kubernetes-service-endpoints", [])
        ne = [t for t in se if t["labels"].get("service", "").endswith("node-exporter")]
        ksm = [t for t in se if t["labels"].get("service", "").endswith("kube-state-metrics")]
        if {t["labels"].get("node", "") for t in ne} != want or len(ne) != len(want):
            fails.append(f"node-exporter Target {sorted(t['labels'].get('node', '') for t in ne)} != 기대 {sorted(want)}")
        if len(ksm) != 1:
            fails.append(f"kube-state-metrics Target {len(ksm)}개 (기대 1)")
        other = sorted({t["labels"].get("service", "") for t in se} - {t["labels"].get("service", "") for t in ne + ksm})
        out(f"   (service-endpoints의 그 밖의 Service: {other or '없음'})")

        out("-- 실제 샘플")
        checks = [
            ("node-exporter", 'count by (node) (node_uname_info{job="kubernetes-service-endpoints"})', "node"),
            ("kubelet", 'count by (kubernetes_io_hostname) (kubelet_running_pods{job="kubernetes-nodes"})', "kubernetes_io_hostname"),
            ("cAdvisor", 'count by (kubernetes_io_hostname) (container_memory_working_set_bytes{container!="", container!="POD"})',
             "kubernetes_io_hostname"),
        ]
        for name, expr, lab in checks:
            res = query(ctx, expr)
            got = label_set(res, lab)
            out(f"   {name:13} Node={sorted(got)} 시계열={[int(float(r['value'][1])) for r in res]}")
            if got != want:
                fails.append(f"{name} 샘플 Node {sorted(got)} != 기대 {sorted(want)}")
        fresh = [
            ("node-exporter 최신", 'timestamp(node_memory_MemAvailable_bytes{job="kubernetes-service-endpoints"})'),
            ("cAdvisor 최신", 'max by (kubernetes_io_hostname) (timestamp(container_memory_working_set_bytes{container!="", container!="POD"}))'),
            ("kube-state-metrics 최신", "timestamp(kube_node_info)"),
        ]
        for name, expr in fresh:
            res = query(ctx, expr)
            a = age(res)
            out(f"   {name:22} 샘플 {len(res)}개, 가장 오래된 샘플 {('NA' if a is None else f'{a:.0f}s')} 전")
            if a is None or a > STALE_S:
                fails.append(f"{name}: 최근 {STALE_S}초 안의 샘플이 없다")
        ksm_q = [
            ("kube_node_info Node", "count(kube_node_info)", len(want)),
            ("kube_pod_info Pod", "count(kube_pod_info)", None),
            ("memory requests 시계열", 'count(kube_pod_container_resource_requests{resource="memory"})', None),
            ("Pod Ready 시계열", 'count(kube_pod_status_ready{condition="true"})', None),
            ("Node 조건 시계열", 'count(kube_node_status_condition{condition="MemoryPressure"})', None),
        ]
        for name, expr, exp in ksm_q:
            res = query(ctx, expr)
            v = int(float(res[0]["value"][1])) if res else None
            out(f"   kube-state-metrics {name}: {v}")
            if v is None or v == 0 or (exp is not None and v != exp):
                fails.append(f"kube-state-metrics {name} = {v} (기대 {exp if exp is not None else '> 0'})")

        if UP_WINDOW:
            out(f"-- 최근 {UP_WINDOW} 동안 수집 끊김")
            res = query(ctx, f'min by (job) (min_over_time(up{{job=~"{"|".join(JOBS)}"}}[{UP_WINDOW}]))')
            got = {r["metric"].get("job"): float(r["value"][1]) for r in res}
            for job in JOBS:
                out(f"   {job:32} up 최솟값={got.get(job, 'NA')}")
                if got.get(job) != 1.0:
                    fails.append(f"{job}: 최근 {UP_WINDOW} 안에 up이 1이 아닌 수집이 있었다 ({got.get(job, 'NA')})")
            for r in query(ctx, f"max by (job) (max_over_time(scrape_duration_seconds[{UP_WINDOW}]))"):
                out(f"   scrape 시간 구간 최대 {r['metric'].get('job')}: {float(r['value'][1]):.3f}s")
            res = query(ctx, f'max_over_time(process_resident_memory_bytes{{job="prometheus"}}[{UP_WINDOW}])')
            out(f"   Prometheus RSS 구간 최대 bytes: {res[0]['value'][1] if res else 'NA'}")

        out("-- 기록만 (판정 아님)")
        cp = query(ctx, 'count by (job) (up{job=~".*(apiserver|api-servers|etcd|scheduler|controller).*"})')
        out(f"   Control Plane 별도 job: {sorted(label_set(cp, 'job')) or '수집 안 함 (오늘 범위 밖)'}")
        for name, expr in (("TSDB head 시계열", "prometheus_tsdb_head_series"),
                           ("TSDB 블록 bytes", "prometheus_tsdb_storage_blocks_bytes"),
                           ("WAL bytes", "prometheus_tsdb_wal_storage_size_bytes"),
                           ("Prometheus RSS bytes", 'process_resident_memory_bytes{job="prometheus"}'),
                           ("수집 샘플/scrape 합", "sum(scrape_samples_scraped)")):
            res = query(ctx, expr)
            out(f"   {name}: {res[0]['value'][1] if res else 'NA'}")
        for r in query(ctx, "max by (job) (scrape_duration_seconds)"):
            out(f"   scrape 시간 최대 {r['metric'].get('job')}: {float(r['value'][1]):.3f}s")
    except (QueryError, subprocess.TimeoutExpired, json.JSONDecodeError, KeyError, IndexError) as e:
        out(f"조회 실패: {e}")
        finish(2)
    finish(1 if fails else 0, fails)


if __name__ == "__main__":
    main()
