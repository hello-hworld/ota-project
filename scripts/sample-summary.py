#!/usr/bin/env python3
"""sample-summary.py — sample.sh·sample-guests.sh 연속 수집 파일에서 최저·최고값을 뽑는다 (비교표 입력용)

실행 위치: [ota-host] ~/ota-project
사용법  : python3 scripts/sample-summary.py <측정 파일 접두어>
          예) python3 scripts/sample-summary.py docs/evidence/measure/20261014-0712
              → 그 접두어로 시작하는 -host-vmstat.txt, -domstats.csv, -worker-a1.txt, -worker-b1.txt ... 를 읽는다
출력    : 항목별 최저/최고와 그 시각. 읽지 못한 파일은 '미수집'으로 표시하고 0으로 채우지 않는다
"""
import csv
import datetime
import glob
import os
import sys


def host_vmstat(path):
    hdr, rows = None, []
    for line in open(path, encoding="utf-8", errors="replace"):
        f = line.split()
        if not f:
            continue
        if f[0] == "r" and "swpd" in f:
            hdr = f
            continue
        if hdr and f[0].isdigit() and len(f) >= len(hdr) - 1:
            rows.append(f)
    if not hdr or not rows:
        return "미수집"
    ix = {k: i for i, k in enumerate(hdr)}
    rows = rows[1:] if len(rows) > 1 else rows          # 첫 줄은 부팅 이후 평균
    busy = [(100 - int(r[ix["id"]]), " ".join(r[-2:])) for r in rows]
    si = sum(int(r[ix["si"]]) for r in rows)
    so = sum(int(r[ix["so"]]) for r in rows)
    peak = max(busy)
    s = f"samples={len(rows)} CPU busy(100-id) max={peak[0]}% at {peak[1]}; si/so 합계={si}/{so}"
    if "gu" in ix:
        gmax = max((int(r[ix["gu"]]), " ".join(r[-2:])) for r in rows)
        s += f"; gu max={gmax[0]}% at {gmax[1]}"
    return s


def utc(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%H:%M:%S")


def domstats(path):
    host, rss = {}, {}
    with open(path, encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            try:
                t = int(row["epoch"])
                host[t] = int(row["host_memavail_kib"])
                vm = row["vm"]
                r = int(row["rss_kib"])
                if r > rss.get(vm, (0, 0))[0]:
                    rss[vm] = (r, t)
            except (KeyError, ValueError):
                continue
    if not host:
        return "미수집"
    tmin = min(host, key=host.get)
    lines = [f"Host MemAvailable min={host[tmin] / 1024:.1f} MiB at {utc(tmin)}Z; "
             f"max={max(host.values()) / 1024:.1f} MiB; samples={len(host)}"]
    for vm in sorted(rss):
        lines.append(f"  {vm} RSS max={rss[vm][0] / 1024:.1f} MiB at {utc(rss[vm][1])}Z")
    return "\n".join(lines)


def guest(path):
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        f = line.split()
        if len(f) >= 3 and f[0][:2].isdigit() and ":" in f[0]:
            try:
                rows.append((f[0], float(f[1]), f))
            except ValueError:
                continue
    if not rows:
        return "미수집"
    lo = min(rows, key=lambda x: x[1])
    s = f"samples={len(rows)} MemAvailable min={lo[1]:.1f} MiB at {lo[0]}; 마지막 시각 {rows[-1][0]}"
    if len(rows[0][2]) >= 12:          # sample-guests.sh 형식: psi some avg10 = 4번째 열
        psi = [(float(r[2][3]), r[0]) for r in rows if r[2][3] not in ("NA",)]
        if psi:
            pm = max(psi)
            s += f"; PSI mem some avg10 max={pm[0]} at {pm[1]}"
    return s


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    pre = sys.argv[1]
    files = sorted(glob.glob(pre + "*"))
    if not files:
        print(f"파일 없음: {pre}*")
        sys.exit(1)
    for p in files:
        name = os.path.basename(p)
        try:
            if p.endswith("-host-vmstat.txt"):
                r = host_vmstat(p)
            elif p.endswith("-domstats.csv"):
                r = domstats(p)
            elif p.endswith(".txt"):
                r = guest(p)
            else:
                continue
        except OSError as e:
            r = f"읽기 실패: {e}"
        print(f"[{name}]\n  {r}")


if __name__ == "__main__":
    main()
