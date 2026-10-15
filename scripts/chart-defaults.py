#!/usr/bin/env python3
"""chart-defaults.py — 고정 Chart 패키지(.tgz)의 기본 values를 하위 Chart까지 합쳐 한 파일로 만든다 (values-keycheck.py 입력용)

`helm show values`는 상위 Chart의 values.yaml만 보여 준다. prometheus Chart처럼 kube-state-metrics·node-exporter를
하위 Chart로 넣은 경우, 그 아래 키(예: kube-state-metrics.collectors)는 키 검사에서 모두 '없는 키'로 나온다.
이 스크립트는 하위 Chart의 values.yaml을 그 이름 아래에 넣고, 상위 values에 같은 키가 있으면 상위 값을 우선한다(Helm과 같은 순서).

실행 위치: [ota-host] ~/ota-project
사용법  : python3 scripts/chart-defaults.py <chart.tgz> > <출력.yaml>
          예) python3 scripts/chart-defaults.py helm/monitoring/chart/prometheus-29.37.0.tgz > "$EV/20-prometheus-defaults.yaml"
판정    : 읽은 하위 Chart 이름·버전을 stderr로 출력한다. 패키지를 읽지 못하면 종료 코드 2
"""
import io
import sys
import tarfile

import yaml


def merge(base, over):
    """over가 우선. dict끼리만 재귀로 합친다 (리스트·값은 over로 바꾼다)"""
    if not isinstance(base, dict) or not isinstance(over, dict):
        return over
    out = dict(base)
    for k, v in over.items():
        out[k] = merge(base.get(k), v) if k in base else v
    return out


def chart_values(tf, prefix):
    """prefix(예: 'prometheus/')의 values.yaml과 하위 Chart를 합친 dict"""
    names = tf.getnames()
    vals = {}
    vpath = prefix + "values.yaml"
    if vpath in names:
        vals = yaml.safe_load(tf.extractfile(vpath)) or {}
    subs = {}
    # 디렉터리로 들어 있는 하위 Chart: <prefix>charts/<sub>/Chart.yaml
    for n in names:
        rest = n[len(prefix):] if n.startswith(prefix) else None
        if rest and rest.startswith("charts/") and rest.count("/") == 2 and rest.endswith("/Chart.yaml"):
            sub = rest.split("/")[1]
            meta = yaml.safe_load(tf.extractfile(n)) or {}
            subs[sub] = chart_values(tf, f"{prefix}charts/{sub}/")
            print(f"subchart {sub} {meta.get('version')} (app {meta.get('appVersion')})", file=sys.stderr)
    # .tgz로 들어 있는 하위 Chart: <prefix>charts/<sub>-<ver>.tgz
    for n in names:
        rest = n[len(prefix):] if n.startswith(prefix) else None
        if rest and rest.startswith("charts/") and rest.count("/") == 1 and rest.endswith(".tgz"):
            inner = tarfile.open(fileobj=io.BytesIO(tf.extractfile(n).read()), mode="r:gz")
            top = inner.getnames()[0].split("/")[0]
            subs[top] = chart_values(inner, top + "/")
            print(f"subchart {top} (tgz {rest})", file=sys.stderr)
    for sub, sv in subs.items():
        vals[sub] = merge(sv, vals.get(sub, {}) or {})
    return vals


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    try:
        tf = tarfile.open(sys.argv[1], mode="r:gz")
        top = tf.getnames()[0].split("/")[0]
        vals = chart_values(tf, top + "/")
    except (OSError, tarfile.TarError, yaml.YAMLError) as e:
        print(f"읽기 실패: {e}", file=sys.stderr)
        sys.exit(2)
    yaml.safe_dump(vals, sys.stdout, sort_keys=False, allow_unicode=True)


if __name__ == "__main__":
    main()
