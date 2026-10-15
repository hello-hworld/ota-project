부분 완료 — STEP 4·CI #11·P2와 최종 Node 예약량 검토 완료. 최종 budget JSON 저장은 PASS이며, 그 안의 최근 15분 관측값 수치 검토는 후속 항목이다.

# DAY9 자원 예산

- 기준일/run: 2026-10-15 / `run01`.
- 소스: `0ca578b13643939299769fff1ff9904aacfa8003`.
- 유휴 예약량: STEP 4 `resource-budget-1792060935.json` 및 `04-nodes-a/b` 출력. P2 `20261015-120522-day9-run01-P2-final.txt`에서 5 Node의 예약량이 동일함을 확인했다.
- 실사용: STEP 4 최근 15분 지표, CI 포함 연속 수집, CI #11 cgroup 자료. 서로 다른 시간 범위와 지표를 구분한다.

## 1. Node별 유휴 예약량

메모리 단위는 MiB이며 CPU의 m은 밀리코어다.

| Node | CPU 할당 가능(m) | CPU requests / limits(m) | 메모리 할당 가능 | 메모리 requests / limits |
|---|---:|---:|---:|---:|
| cp-a | 2000 | 1120 / 100 | 1867.6 | 272 / 436 |
| worker-a1 | 4000 | 1140 / 4550 | 5825.2 | 2448 / 6560 |
| cp-b | 2000 | 1020 / 100 | 2807.9 | 202 / 266 |
| worker-b1 | 4000 | 420 / 350 | 6833.2 | 166 / 394 |
| worker-b2 | 4000 | 480 / 1150 | 6833.2 | 560 / 1184 |

예약 합계는 init·sidecar·Pod overhead를 고려하는 `kubectl describe nodes` 결과를 기준으로 했다. limits는 제한을 설정한 항목들의 합계이며, 제한 미설정 컨테이너·OS 사용량까지 포함하는 Node 전체 상한이 아니다. requests 비율은 실제 사용률이 아니다.

worker-a1의 kubectl 표시는 CPU limits 113%, memory limits 112%다. 과예약으로 기록하며 이 비율만으로 현재 메모리 부족이나 OOM이라고 판정하지 않는다.

## 2. 관측된 메모리 여유

| Node | STEP 4 최근 15분 최소 MemAvailable | CI 포함 연속 수집 최소 MemAvailable | CI 포함 구간 샘플 수 | P2 한 시점 MemAvailable |
|---|---:|---:|---:|---:|
| cp-a | 653.9 | 713.0 | 26 | 696.0 |
| worker-a1 | 3881.5 | 3699.9 | 28 | 3884.1 |
| cp-b | 1789.1 | 1768.8 | 26 | 1797.0 |
| worker-b1 | 6233.4 | 6234.0 | 26 | 6240.7 |
| worker-b2 | 6151.2 | 6131.2 | 26 | 6120.4 |

cp-a는 이번 운영 기준 300MiB 이상을 충족했다. CI 후 및 STEP 7에서 5 Node는 Ready, Memory/Disk/PID Pressure False였다. P2 열은 각 VM의 한 시점 스냅샷이며 앞의 최소값 열과 범위가 다르다. 샘플 사이의 순간 최저값을 모두 보장하는 연속 측정으로 해석하지 않는다.

## 3. Grafana 보정

| 항목 | 값 |
|---|---:|
| request / limit | 256Mi / 768Mi |
| STEP 4 시점 사용량 | 217.4MB ≈ 207.3MiB |
| STEP 4 최근 15분 working-set 최대 | 263.5MiB |
| request 초과 | 7.5MiB, 약 2.9% |
| CI 후·STEP 7·P2 새 Pod 재시작 | 0 |

현재 설정을 유지한다. request는 후속 검토 대상으로 남기고, 단일 최근 15분 값으로 확정하지 않는다. 과거 384Mi cgroup OOM은 별도 사고 기록으로 보존한다.

## 4. CI Agent 1개 추가 시 계산상 예산

기존 `ci/agent-pod.yaml` 및 Jenkins jnlp 상속 설정 유지, 추가 init/Pod overhead 없음이라는 조건의 계산이다. CI 실행 중 `describe nodes` 실측 표와 구분한다.

| worker-a1 항목 | 유휴 | Agent 1개 추가량 | 계산상 합계 | Allocatable 대비 |
|---|---:|---:|---:|---:|
| CPU requests(m) | 1140 | 1100 | 2240 | 56.0% |
| CPU limits(m) | 4550 | 4500 | 9050 | 226.3% |
| memory requests(MiB) | 2448 | 896 | 3344 | 57.4% |
| memory limits(MiB) | 6560 | 3584 | 10144 | 174.1% |

이번 CI에서는 worker-a1 최소 여유 3699.9MiB, Agent 5개 컨테이너 max/oom/oom_kill/oom_group_kill 0을 확인했다. 이 단일 실행을 모든 CI·동시 부하 조건에서의 안전 보장으로 확대하지 않는다.

| 컨테이너 | memory.peak(MiB) | 현재 limit(MiB) |
|---|---:|---:|
| jnlp | 184.6 | 512 |
| python | 26.9 | 256 |
| buildkit | 161.5 | 1536 |
| trivy | 35.3 | 1024 |
| skopeo | 32.3 | 256 |

개별 peak 합계는 Node의 동시 피크가 아니다. jnlp throttle 299회·누적 56.1초와 Agent 종료 정리 약 31초는 별도 조정 후보로 기록한다.

## 5. Production Namespace 예산

- 정상 2 + maxSurge 1 + spare 1 = 4 Pod slots.
- Quota: pods 4, requests 200m / 256Mi, limits 1000m / 512Mi.
- LimitRange 기본값: request 50m / 64Mi, limit 250m / 128Mi.
- 적용 후 현재 사용량은 위 Quota의 50%이며 기존 Pod 2개는 유지됐다.
- Namespace Quota는 실제 Node 메모리를 추가 예약하거나 성능을 보장하는 설정이 아니다. 새 워크로드를 넣기 전에 재산정한다.

## 6. P2 최종 기록

- P2 파일: `docs/evidence/measure/20261015-120522-day9-run01-P2-final.txt`.
- META 시각: 2026-10-15 12:11:34 UTC / 21:11:34 KST.
- 최종 budget: `docs/evidence/day9/run01/resource-budget-1792066310.json`; 수집 RESULT=PASS, command_exit=0 / log_exit=0.
- P2 CPU 구간 샘플 12개, 수집 실패 0; Node 5개 Ready, Memory/DiskPressure False. STEP 7 별도 상태 검사에서 PIDPressure도 False다.
- Host MemAvailable 18577.8MiB; RAM Used 13232.3MiB; QEMU PSS 합계 11756.2MiB; RSS 합계 17208.4MiB.
- Host Swap Used 64.0MiB, 현재 구간 평균 si/so 0.0 / 0.0.
- P1→P2 Host RAM Used -30.3MiB, PSS -39.8MiB, worker-a1 MemAvailable -17.0MiB. 이번 관측에서 CI 후 큰 메모리 잔류 증가는 보이지 않았다.
- 최종 JSON의 최근 15분 최소/최대와 Grafana working-set 수치는 이번 제출에 출력되지 않았다. STEP 4의 263.5MiB를 최종 시점의 수치로 바꾸어 적지 않는다.
- Helm/Quota/LimitRange의 추가 자원 변경은 하지 않았다. 현재 설정을 유지하며 반복 사용·CI 및 추가 부하 검증을 통해 후속 조정을 판단한다.
