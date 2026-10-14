#!/usr/bin/env python3
"""values-keycheck.py — 내가 쓴 values의 키가 고정 Chart의 기본 values에 실제로 있는지 확인한다
Helm은 모르는 키를 오류 없이 무시하므로(예: argo-cd 10.10.3에는 applicationSet.enabled가 없다) 렌더링만으로는 오타를 못 잡는다.
실행 위치: [ota-host] ~/ota-project
사용법  : python3 scripts/values-keycheck.py <내 values.yaml> <helm show values 결과 파일>
판정    : 없는 키가 하나라도 있으면 목록을 출력하고 종료 코드 1
규칙    : nodeSelector·resources처럼 값이 자유 형식인 맵은 안쪽 키를 검사하지 않는다
"""
import sys, yaml
mine = yaml.safe_load(open(sys.argv[1]))
base = yaml.safe_load(open(sys.argv[2]))
bad = []
def walk(m, b, path):
    for k, v in m.items():
        p = f"{path}.{k}" if path else k
        if not isinstance(b, dict) or k not in b:
            bad.append(p)
            continue
        sub = b[k]
        if isinstance(v, dict) and isinstance(sub, dict) and any(isinstance(x, dict) for x in sub.values()):
            walk(v, sub, p)
walk(mine, base, "")
print("Chart 기본 values에 없는 키:", ", ".join(bad) if bad else "없음")
sys.exit(1 if bad else 0)
