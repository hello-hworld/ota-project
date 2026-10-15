#!/usr/bin/env python3
"""grafana-check.py — Grafana 서버가 두 Data Source를 실제로 조회하는지, 대시보드가 프로비저닝됐는지 판정한다

로그인 성공이나 브라우저에서 주소가 열리는 것은 판정에 쓰지 않는다. Data Source 'access: proxy'는 Grafana 서버(A의 Pod)가
조회하므로, 이 스크립트가 Grafana API로 시키는 조회가 곧 'A의 Grafana Pod → B Prometheus' 경로 확인이다.

실행 위치: [ota-host] ~/ota-project, T2에서 Grafana port-forward(127.0.0.1:13000)가 열린 상태
사용법  : python3 scripts/grafana-check.py [증거 이름]
          예) python3 scripts/grafana-check.py 44-grafana-check
          admin 비밀번호는 프롬프트로만 받는다(명령 인자·환경 변수·파일에 쓰지 않는다)
판정    : RESULT=PASS(0) / RESULT=FAIL(1) / RESULT=ERROR(2, Grafana에 닿지 못함·인증 실패)
  - /api/health database=ok
  - Data Source prometheus-a, prometheus-b: health OK, Grafana 서버를 통한 조회에서 기대 Node가 모두 나온다
  - 대시보드 uid ota-infra-overview가 있고 provisioned
"""
import base64
import getpass
import json
import os
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get("GRAFANA_URL", "http://127.0.0.1:13000").rstrip("/")
REPO = os.environ.get("REPO", os.path.expanduser("~/ota-project"))
EV = os.environ.get("EV", os.path.join(REPO, "docs/evidence/day8"))
USER = os.environ.get("GRAFANA_USER", "admin")
EXPECT = {
    "prometheus-a": {"cp-a", "worker-a1"},
    "prometheus-b": {"cp-b", "worker-b1", "worker-b2"},
}
DASH_UID = "ota-infra-overview"
LINES = []
AUTH = {}


def out(msg=""):
    print(msg, flush=True)
    LINES.append(msg)


def finish(code, fails=()):
    out({0: "RESULT=PASS", 1: "RESULT=FAIL"}.get(code, "RESULT=ERROR"))
    for f in fails:
        out(f"  - {f}")
    if len(sys.argv) > 1:
        os.makedirs(EV, exist_ok=True)
        path = os.path.join(EV, sys.argv[1] + ".txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(LINES) + "\n")
        print(f"저장 → {path}")
    sys.exit(code)


def call(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method="POST" if data else "GET")
    req.add_header("Authorization", AUTH["h"])
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except ValueError:
            return e.code, {}


def frame_labels(result, key):
    """/api/ds/query 결과(Data Frame)의 필드 라벨에서 key 값들을 모은다"""
    got = set()
    for fr in result.get("frames", []) or []:
        for fld in fr.get("schema", {}).get("fields", []) or []:
            lab = fld.get("labels") or {}
            if key in lab:
                got.add(lab[key])
    return got


def main():
    if len(sys.argv) > 2:
        print(__doc__)
        sys.exit(2)
    try:
        pw = getpass.getpass(f"Grafana {USER} 비밀번호: ")
    except (EOFError, KeyboardInterrupt):
        print("\n비밀번호 입력 없음")
        sys.exit(2)
    AUTH["h"] = "Basic " + base64.b64encode(f"{USER}:{pw}".encode()).decode()
    del pw
    fails = []
    out(f"== grafana-check url={URL} at={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    try:
        st, h = call("/api/health")
        out(f"-- health: http={st} database={h.get('database')} version={h.get('version')}")
        if st != 200 or h.get("database") != "ok":
            fails.append("Grafana /api/health 이상")
        st, me = call("/api/user")
        if st != 200:
            out(f"인증 실패 (http={st})")
            finish(2)
        st, dss = call("/api/datasources")
        out("-- datasources")
        for d in dss if isinstance(dss, list) else []:
            out(f"   {d.get('name')} uid={d.get('uid')} type={d.get('type')} access={d.get('access')} url={d.get('url')} "
                f"default={d.get('isDefault')} readOnly={d.get('readOnly')}")
        for uid, want in EXPECT.items():
            st, hc = call(f"/api/datasources/uid/{uid}/health")
            out(f"-- {uid} health: http={st} status={hc.get('status')} message={hc.get('message')}")
            if st != 200 or hc.get("status") != "OK":
                fails.append(f"{uid} health {st} {hc.get('status')} {hc.get('message')}")
                continue
            body = {"from": "now-5m", "to": "now", "queries": [
                {"refId": "N", "datasource": {"type": "prometheus", "uid": uid}, "instant": True, "range": False,
                 "expr": 'count by (node) (node_uname_info{job="kubernetes-service-endpoints"})'},
                {"refId": "C", "datasource": {"type": "prometheus", "uid": uid}, "instant": True, "range": False,
                 "expr": 'count by (kubernetes_io_hostname) (container_memory_working_set_bytes{container!="", container!="POD"})'},
                {"refId": "K", "datasource": {"type": "prometheus", "uid": uid}, "instant": True, "range": False,
                 "expr": "count by (node) (kube_node_info)"},
            ]}
            st, res = call("/api/ds/query", body)
            r = res.get("results", {}) if isinstance(res, dict) else {}
            for ref, key, name in (("N", "node", "node-exporter"), ("C", "kubernetes_io_hostname", "cAdvisor"),
                                   ("K", "node", "kube-state-metrics")):
                rr = r.get(ref, {})
                got = frame_labels(rr, key)
                err = rr.get("error")
                out(f"   {uid} {name:18} http={st} status={rr.get('status')} Node={sorted(got)} {('error=' + err) if err else ''}")
                if st != 200 or err or got != want:
                    fails.append(f"{uid} {name}: Node {sorted(got)} != 기대 {sorted(want)} {err or ''}")
        st, db = call(f"/api/dashboards/uid/{DASH_UID}")
        meta, dash = db.get("meta", {}), db.get("dashboard", {})
        out(f"-- dashboard {DASH_UID}: http={st} title={dash.get('title')} folder={meta.get('folderTitle')} "
            f"provisioned={meta.get('provisioned')} panels={len(dash.get('panels', []))}")
        if st != 200 or not meta.get("provisioned"):
            fails.append(f"대시보드 {DASH_UID} 없음 또는 파일 프로비저닝 아님 (http={st})")
    except (urllib.error.URLError, OSError, ValueError) as e:
        out(f"Grafana 조회 실패: {e} (T2 port-forward 확인)")
        finish(2)
    finish(1 if fails else 0, fails)


if __name__ == "__main__":
    main()
