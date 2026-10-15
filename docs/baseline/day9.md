부분 완료 — 구성 적용·정상 CI 1회·STEP 7 자동 검사·P2 통과. 대시보드 직접 확인은 일부 수행이며, Grafana API 증거 추가 검토·48h 삭제 검증은 후속 항목이다.

# DAY9 결과 — Grafana 메모리 보정·물리 Host 관측·Production 초기 정책·CI 회귀

- 실행일: 2026-10-15. 본문 시각은 UTC이며 KST는 UTC+9다. P2 META 시각은 12:11:34 UTC, **21:11:34 KST**다.
- Run: `run01`; 증거: `docs/evidence/day9/run01/`, `docs/evidence/measure/*-day9-run01-*`.
- 시작 소스: `da87e9ccf3151f60e4b345ec17ecb08e4776cb2a`.
- 적용 소스: `0ca578b13643939299769fff1ff9904aacfa8003`.
- 상태 범위: STEP 4~7 서버 출력 및 P0b/P1/P2 비교 요약을 검토했다. 실행 검증 결과를 기록한 보고서이며, 직접 화면 확인과 추가 증거 검토가 남아 전체 상태는 부분 완료다. 보고서·증거 Commit/Push는 별도 절차로 진행한다.
- 기준 버전: Kubernetes v1.36.5, containerd 2.2.1, Prometheus v3.15.0, Grafana 13.2.4, node-exporter v1.12.1, kube-state-metrics v2.20.0. lint 대상 고정 패키지는 prometheus-29.37.0.tgz와 grafana-13.6.0.tgz다.

## 1. 완료 판정

| 항목 | 확인 결과 | 근거 / 남은 확인 |
|---|---|---|
| DAY8 Helm lint 3개·현재 TSDB | PASS | lint 3개 모두 실패 0; A/B 각각 블록 3개, 48h / 3GiB 설정; 실제 삭제 동작은 미검증 |
| 기존 A/B·Host 대시보드 화면 | 일부 확인 | 사용자 응답: 일부만 확인함. 미확인 화면과 기존 Grafana API 검사 증거는 후속 확인 |
| Grafana 메모리 조정 | 적용 및 CI 후 정상 상태 확인 | request 256Mi / limit 768Mi; 새 Pod `grafana-c78955987-xljg8`, CI 후 Ready·재시작 0 |
| 물리 Host 수집 | PASS | 서비스 active; Target UP; 물리 hostname·최신 샘플·Prometheus를 통한 Host 패널식 검사 PASS |
| Host 대시보드 Grafana API | 기존 증거 추가 검토 | STEP 7 Host 검사는 Prometheus 조회다. Grafana API 경로의 기존 `grafana-host-*.json`과 검사 로그는 이번 제출에 포함되지 않았다 |
| 자원 예산 | STEP 4·CI·P2 확인 | P2 Node 예약량은 STEP 4와 동일. 최종 budget JSON 저장 PASS; JSON 내부 최근 15분 수치는 추가 검토 |
| Production ResourceQuota·LimitRange | 적용·검증 PASS | `policy-source.json`, `policy-check-*.json`, `05-production.txt` |
| 변경 소스 Commit·Push | PASS | `06-source-commit.txt`; 원격 main과 일치 |
| 정상 CI 1회 | PASS, `day6-ci #11` | `ci-11/`, `SOURCE_COMMIT_MATCH=PASS` |
| CI 후 서비스 유지 | PASS | 최종 Production C 2개, HTTP 10/10, Argo 2개 Synced/Healthy, CI/Staging Pod 0, 5 Node Ready·Pressure 없음, 관측 Pod 재시작 0 |
| P0·P0b·P1·P2 | 원본 보존, P0b/P1/P2 수집 실패 0 | P2 `20261015-120522-day9-run01-P2-final.txt`; CPU 구간 샘플 12개 |
| 같은 HTTP 입력의 부하 비교 | 미수행 | 정상 CI 1회 검증과 구분. 처리량·p95 개선 결과로 확장하지 않음 |
| 최종 보고서·증거 Push | 본 보고서 작성 시점 대기 | 실행 소스 0ca578b와 보고서·증거 반영 커밋을 구분. 게시 여부는 원격 Git 상태로 확인 |

## 2. Grafana OOM과 보정

2026-10-15 09:12:21Z 무렵 기존 Grafana Pod가 `OOMKilled`, exit 137로 종료됐다. worker-a1 커널 로그는 `CONSTRAINT_MEMCG`와 usage/limit 393216kB를 보였다. 당시 worker-a1 MemAvailable은 약 3923MiB였다. 근거는 Grafana 컨테이너의 384Mi cgroup 상한 도달이며, Node 전체 메모리 고갈로 해석하지 않는다.

`helm/monitoring/grafana.yaml`에서 memory request 128Mi→256Mi, limit 384Mi→768Mi를 적용했다. CPU·PVC·Data Source 구성은 기존 설정을 사용했다. 재검증 뒤 Host 설치 전 기준선 P0b를 별도로 남겼다.

- STEP 4 최근 15분 working-set 최대: **263.5MiB**.
- STEP 4 한 시점 사용량: 217.4MB, 약 **207.3MiB**. MB와 MiB를 구분한다.
- 263.5MiB는 request보다 7.5MiB 크다. request는 예약 기준이며 초과 자체가 OOM은 아니다. 현재 256Mi / 768Mi를 유지하고, 반복 사용·CI 결과를 바탕으로 request 적정성을 후속 검토한다.
- STEP 7 및 P2에서 새 Grafana Pod는 Ready, restart 0이다. P2 당시 Pod age는 약 147분이다. 이는 해당 검증 구간의 결과이며 장기 안정성 보장으로 확대하지 않는다.

## 3. Host 관측

- 서비스: `ota-node-exporter.service`; 설치 도구의 고정 버전은 node-exporter v1.12.1 linux-amd64.
- 대상: `192.168.56.1:19100`, A Prometheus job `ota-host`.
- Labels: `instance=ota-host`, `scope=physical-host`.
- 설정: `helm/monitoring/prometheus-host.yaml`; 대시보드: `OTA Physical Host`, uid `ota-host-overview`, Data Source `prometheus-a`.
- 기존 A/B 대시보드 ConfigMap의 기존 키를 보존하고 Host 키만 추가했다.
- STEP 7: 서비스 active, Host Target UP, 실제 물리 Host의 hostname 일치, 최신 샘플 및 모든 Host 패널식의 유효 숫자 조회 PASS다. A 활성 Target 12개, B 14개 모두 UP으로 출력됐다.
- 이 검사는 Prometheus 경로다. Grafana를 통한 Host 패널 조회 증거와 전체 직접 화면 확인은 후속 검토로 남긴다.

## 4. Production 초기 정책

대상은 B `production`이며 현재 데모의 `replicas 2 + maxSurge 1 + spare 1 = 4 slots`로 계산했다. 정책 파일은 `k8s/policies/day9-production.yaml`이다.

| 항목 | 현재 사용량 | 상한 |
|---|---:|---:|
| pods | 2 | 4 |
| requests.cpu | 100m | 200m |
| requests.memory | 128Mi | 256Mi |
| limits.cpu | 500m | 1000m |
| limits.memory | 256Mi | 512Mi |

LimitRange `ota-demo-defaults`는 컨테이너 기본 request 50m / 64Mi, 기본 limit 250m / 128Mi를 제공한다. 이번 구성에는 별도 컨테이너 min/max 제한을 설정하지 않았다. ResourceQuota `ota-demo-budget`은 Namespace 합계를 제한한다.

서버 dry-run에서 기본값 주입과 CPU Quota 초과 요청의 `exceeded quota` 거부를 확인했다. 시험 Pod는 실제 생성하지 않았다. 적용 전후 기존 Pod 2개의 이름·IP·이미지는 유지됐고 재시작은 0이었다. 다른 앱·Canary·Analysis Job 등을 추가할 때에는 예산을 다시 계산한다.

## 5. 정상 CI #11

- Job: `day6-ci`, build **11**, 결과 **SUCCESS**.
- Commit: `0ca578b13643939299769fff1ff9904aacfa8003`; Push한 소스와 일치.
- Test exit 0; Scan exit 0, severity CRITICAL.
- built = pushed digest: `sha256:5224e3f414fffa86c29067580f7536e5c4c726e15060232d6107ecb607d4b765`.
- Production은 C digest `sha256:6068b90a242e7d40415786a9b7498f81a8b3f9324f4944d163a699df231e7b8e`, version `50615d6ab9d2-day6-ci-3`를 유지했다.
- Jenkins 전체 build duration: **56096ms = 56.096초** (`ci-11/jenkins-result.json`).
- test-start 11:35:12Z → push-end 11:35:30Z: 실작업 구간 **18초**. Jenkins 전체 build duration과 구분한다.

| 컨테이너 | memory.peak (MiB) | max / oom / oom_kill / oom_group_kill |
|---|---:|---|
| jnlp | 184.6 | 모두 0 |
| python | 26.9 | 모두 0 |
| buildkit | 161.5 | 모두 0 |
| trivy | 35.3 | 모두 0 |
| skopeo | 32.3 | 모두 0 |

`memory.events`는 5개 컨테이너 모두 수집됐다. 컨테이너별 peak를 더한 값을 Node의 동시 피크로 사용하지 않는다. 이번 Trivy peak가 낮다는 이유로 과거 DB 준비 구간의 1Gi 근접 현상이 해결됐다고 판정하지 않는다.

jnlp `nr_throttled=299`, `throttled_usec=56063086`이다. 누적 throttle 시간 약 56.1초를 CI 벽시계 지연 56.1초로 환산하지 않는다.

Agent는 11:34:41Z 생성 → 11:34:42Z Running → 11:35:34Z Terminating → 11:36:04Z Error → 11:36:05Z 삭제됐다. 종료 정리는 약 **31초**다. CI 성공 후 정리 과정에서의 Error와 실제 Test/Scan 실패를 구분하고, 종료 동작 개선은 후속 항목으로 남긴다.

연속 수집은 worker-a1에서 11:36:22Z, 나머지 VM에서 11:36:37Z까지 남았다. Host domstats 마지막 시각은 11:36:25Z이며 5 VM 행이 확인됐다. 모두 Agent 삭제 이후까지의 끝부분이 확인됐다. 전체 원본은 보존한다.

## 6. 측정 기준과 비교

| 측정 | 의미 | 파일 |
|---|---|---|
| P0 | Grafana 보정 전 DAY9 시작 기준 | `20261015-090557-day9-run01-P0.txt` |
| P0b | Grafana 보정 후, Host 관측 설치 전 | `20261015-100925-day9-run01-P0b-grafana-fixed.txt` |
| P1 | Host 관측·Production 정책 적용 후 유휴 | `20261015-112927-day9-run01-P1-idle.txt` |
| P2 | CI 종료·임시 수집/터널 정리 후 최종 유휴 | `20261015-120522-day9-run01-P2-final.txt` |

P0b·P1·P2는 `vmstat 5 13`, 구간 샘플 12개로 60초를 수집했다. P1·P2는 사전 유휴 5분, Agent/Staging 0, port-forward·임시 연속 수집 없음에서 측정됐다. P2는 대기 전후 quiet_check가 모두 성공했다. 파일명 시각은 스크립트 시작 때, META 시각은 Host 원시값 수집 후 기록되므로 서로 다를 수 있다.

| 지표 | P0b | P1 | P2 |
|---|---:|---:|---:|
| Host MemAvailable (MiB) | 18439.2 | 18547.5 | 18577.8 |
| Host RAM Used (MiB) | 13370.9 | 13262.6 | 13232.3 |
| Host Swap Used (MiB) | 64.2 | 64.0 | 64.0 |
| Swap si / so 평균 | 0.1 / 0.0 | 0.0 / 0.0 | 0.0 / 0.0 |
| KSM general_profit (MiB) | 5448.7 | 5409.1 | 5425.2 |
| KSM 보정 사용량 (MiB, 보조 추정) | 18819.6 | 18671.7 | 18657.5 |
| QEMU RSS 합계 (MiB) | 17200.1 | 17199.8 | 17208.4 |
| QEMU PSS 합계 (MiB) | 11897.1 | 11796.0 | 11756.2 |
| cp-a MemAvailable (MiB) | 634.3 | 651.2 | 696.0 |
| worker-a1 MemAvailable (MiB) | 3961.1 | 3901.1 | 3884.1 |
| cp-b MemAvailable (MiB) | 1782.8 | 1786.7 | 1797.0 |
| worker-b1 MemAvailable (MiB) | 6236.5 | 6209.5 | 6240.7 |
| worker-b2 MemAvailable (MiB) | 6146.7 | 6125.5 | 6120.4 |
| CPU us / sy / id / wa (%) | 0.0 / 2.6 / 89.8 / 0.0 | 0.0 / 2.8 / 89.0 / 0.0 | 0.0 / 2.6 / 89.8 / 0.0 |
| Guest CPU gu (%) | 7.4 | 8.1 | 7.3 |
| VM Storage du (-h 표시) | 74G | 75G | 75G |
| 수집 실패 | 0 | 0 | 0 |

P0b→P1은 Host 관측과 Production 정책이 추가된 전후이며, P1→P2는 CI 전후의 유휴 비교다. KSM·페이지 캐시·경과 시간 영향을 함께 기록한다. 감소한 PSS나 늘어난 여유를 Host 설치의 음수 비용 또는 성능 개선으로 단정하지 않는다.

P0b의 META git은 da87e9c이며 Grafana 보정 내용을 커밋하기 전 시점이다. P1·P2의 META git은 변경 소스가 커밋된 0ca578b다. 실행 시점의 설정과 git HEAD를 함께 기록한다.

P1→P2에서 Host RAM Used는 30.3MiB, QEMU PSS는 39.8MiB 감소했다. worker-a1 여유는 17.0MiB 줄었고 cp-a 여유는 44.8MiB 늘었다. 이번 측정에서는 CI 후 큰 메모리 잔류 증가가 관찰되지 않았다. CPU 샘플 수 12, 수집 실패 0, Node Pressure 없음, cp-a 여유 696.0MiB로 최종 자동 검사 기준을 충족했다.

## 7. 현재 TSDB와 DAY8 보완

STEP 7 lint는 A Prometheus, B Prometheus, Grafana 각각 1개 chart linted / failed 0이다. 양쪽 retention 플래그는 2d(48h) / 3GiB다.

| 항목 | A | B |
|---|---:|---:|
| 저장된 TSDB 블록 수 | 3 | 3 |
| 블록 SIZE 합계(bytes) | 23615167 | 24179669 |
| /data 사용량(du -sk, KiB) | 111264 | 115912 |
| /data 사용량(MiB 환산) | 108.7 | 113.2 |

TSDB 블록 합계와 전체 /data 크기는 서로 다른 지표다. 블록 형성과 현재 데이터 저장은 확인됐으며, 아직 48h 보존 경계에서의 실제 삭제 동작을 입증한 것은 아니다. 원본은 `day8-followup-1792065601361627378.json`과 07-day8-followup 로그에 있다.

## 8. 후속 작업

1. 최종 보고서와 이번 run의 증거를 선택해 Commit/Push하고 원격 반영을 확인한다.
2. 48h·3GiB 보존 설정과 실제 삭제 동작을 구분한다. 실제 시간 경과 보존은 2026-10-17의 설치 시각 이후 별도 확인한다.
3. Grafana request 적정성과 worker-a1 limits 과예약을 반복 실측으로 검토한다.
4. Agent 종료 약 31초와 jnlp throttle을 별도 변경으로 검토한다.
5. kubelet TLS 인증서 검증, Prometheus ConfigMap 조회 범위, lifecycle API 접근 제어를 후속 보강한다.
6. HTTP 부하 비교는 미수행으로 기록하며 성능·OTA 처리량 검증으로 대체하지 않는다.
7. 기존 A/B·Host 대시보드 직접 화면 확인을 마치고, 기존 Grafana API 검사 증거를 검토한다. 필요하면 미확인 항목만 추가 검사한다.
8. `resource-budget-1792066310.json`은 저장 PASS다. 내부의 최종 최근 15분 관측값은 이번 제출에 없으므로 STEP 4 수치와 혼합하지 않고 별도 검토한다.

## 9. 최종 확인 기록

- [x] 최종 Production·Prometheus A/B·물리 Host 검사 PASS.
- [x] 두 Argo CD 앱 Synced/Healthy, Agent/Staging 0, 5 Node Ready·Pressure 없음.
- [x] DAY8 lint 3개·현재 TSDB 블록/크기/보존 설정 기록.
- [ ] Grafana 직접 화면 확인은 일부 수행으로 기록. 미확인 화면과 API 검사 증거를 후속 확인.
- [x] P0b/P1/P2 비교표 및 P2의 Node 예약량 기록. 최종 budget JSON 저장 PASS.
- [x] quiet_check가 확인하는 서버 port-forward·sample 계열 연속 수집 없음.
- [ ] 별도 sudo 갱신 프로세스·노트북 전용 터널 종료 확인의 개별 증거는 미수집.
- [ ] 최종 보고서와 이번 run의 증거만 Commit/Push.
