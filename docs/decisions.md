# DAY7 Result — Argo CD GitOps 배포·승격·복귀

- 진행: 2026-10-14 17:02 ~ 23:56 (KST). 본문 시각은 증거 파일과 같은 UTC
- 실행 문서: `DAY7_실행.md` (작업문서 `DAY7_작업문서.md`를 검토·보완한 버전)
- 기준 커밋: DAY6 `972c135` → DAY7 마지막 실행 커밋 `bc5c189`
- 증거 경로: `docs/evidence/day7/`, `docs/evidence/measure/*day7*`

## 1. 요약

Cluster A에 Argo CD를 Helm으로 설치하고, DAY6 CI가 만든 데모 이미지 두 개(정상 기준 G, 후보 C)를 Git 변경 → 수동 Sync로만 배포했다. Staging(A)에서 검증한 digest를 재빌드 없이 Production(B)으로 승격했고, 실패를 일부러 넣은 뒤 Git revert로 복구했다.

- 관문 A(Staging G)와 관문 B(B 등록·Production G)를 모두 통과했다.
- C는 Staging 검증 → 승격 전 확인표 7항목 PASS → Production 승격으로 진행했다. 같은 digest가 B의 두 Worker에서 실행됐다.
- S1: Staging 실패 중 Production의 Commit·Pod가 바뀌지 않았다. S2: Production 실패 설정을 revert로 1초 만에 Healthy로 되돌렸다. S3: G로 복귀한 뒤 C를 재승격했다.
- 승격·실패·복귀 세 구간에서 Service 경유 요청 2,465건 중 실패는 0건이었다.
- Argo CD의 상시 비용은 K8s requests 768Mi·300m, 실제 컨테이너 메모리 75MB(설치 직후) → 158MB(앱 2개·B 등록 후)였다. Host MemAvailable은 P0 대비 −265 MiB였다.

실행 중 `argocd cluster add`가 B 관리자 인증서를 그대로 저장하는 것을 발견해, Production 앱 등록 전에 production 한정 SA 토큰 인증으로 바꿨다(8장).

결과는 '데모 앱의 GitOps 배포·승격·복귀 경로 검증'이다. 승격 판단과 차단은 작업자가 수행했으며, Argo CD가 Staging 결과를 읽고 Production을 자동으로 막는 기능을 구현한 것은 아니다.

## 2. 범위와 결과

| 작업 | 결과 | 근거 |
| --- | --- | --- |
| STEP 1 설치 전 상태·P0 | ✅ 5 Node Ready, 비정상 Pod 없음, `stagins` Namespace 삭제, P0a·P0b 수집 실패 0 | `01-*`, measure P0a·b |
| STEP 2 Chart·CLI 고정, 렌더링 검토 | ✅ Chart sha256 = index digest, CLI 체크섬 OK, values 키 검사 통과, 서버 dry-run 44개 | `02`~`06` |
| STEP 3 Argo CD 설치 | ✅ `helm exit=0`, 4개 Pod worker-a1 Running, 재시작 0, Redis 초기화 Job Completed | `07-*`, `09` |
| STEP 4 데모 Chart·GitOps 선언 | ✅ lint 2/2, 빈 digest 렌더링 거부, A·B 서버 dry-run, AppProject 2개 | `10-*`, `11` |
| STEP 5 관문 A (Staging G) | ✅ PASS 4/4 | `20`~`24` |
| STEP 6 B 등록·관문 B (Production G) | ✅ production 한정 SA 토큰 인증, 연결 `Successful`, G 2개 분산 | `30`~`35` |
| STEP 7 C 검증·승격 | ✅ 확인표 7/7, Production C 2/2, HTTP 실패 0 | `40`~`47` |
| STEP 8 S1·S2·S3 | ✅ 실패는 EXPECTED_FAIL, 복구·재승격 PASS | `50`~`74` |
| STEP 9 최종 상태·P2 | ✅ 두 앱 Synced·Healthy, Staging·Agent 0, P2 수집 실패 0 | `80`~`82`, measure P2 |
| `docs/baseline/day6.md` | ❌ 미작성 (DAY7 1-3에서 미룸) | — |
| 복구 지점 R2 | ➖ 만들지 않음(선택 항목). 마지막 콜드 복구 지점은 R1 | — |

## 3. 버전과 조건

| 구성요소 | 버전 | 비고 |
| --- | --- | --- |
| Kubernetes A/B | v1.30.14 | Argo CD 3.5 공식 테스트 범위(v1.33~v1.36) 밖. 이번 범위(설치, Sync, Health, 원격 클러스터, Helm 렌더링)에서는 호환성 문제를 관측하지 못했다 |
| Argo CD Chart | argo-cd 10.10.3 | sha256 `fa03517a…bf6b8` = argo-helm index digest |
| Argo CD | v3.5.5 | 서버 이미지 `quay.io/argoproj/argocd:v3.5.5`(222MB, 미리 받기 135초), CLI 체크섬 `c3ddfa60…1aba` |
| Redis (Argo CD 내부) | `ecr-public.aws.com/docker/library/redis:8.6.4-alpine` | 34.5MB, 미리 받기 23초 |
| Helm / kubectl (ota-host) | v3.18.6 / v1.30.14 | |
| Host 커널 / VM 커널 | 6.8.0-139 / 6.8.0-146 | 자동 업데이트 중지 상태 유지 |
| KSM | run=1 | 모든 측정 공통 조건 |

`08-login.txt`의 `argocd version`은 로그인 전에 실행돼 서버 버전 줄이 빠졌다. 서버 버전은 실행 이미지 태그(`07-install-check`, `06-image-prepull`)로 대신 확인한다.

## 4. 구성 결과

### Argo CD (Cluster A)

| 항목 | 값 |
| --- | --- |
| Release / Namespace | `argocd` / `argocd`, Helm `--atomic --wait`, 설치 완료 13:21:58Z |
| 배치 | 모든 Pod `workload=platform` → worker-a1 |
| 구성 | Controller(StatefulSet)·Server·Repo Server·Redis 각 1개. Redis HA·Dex·Notifications 끔 |
| ApplicationSet | Chart에 `enabled` 키가 없어 `applicationSet.replicas: 0` (Deployment·CRD는 남음) |
| requests / limits | Controller 100m·256Mi / 500m·1Gi, Repo 100m·256Mi / 500m·768Mi, Server 50m·128Mi / 500m·512Mi, Redis 50m·128Mi / 250m·256Mi |
| 접속 | Service ClusterIP. ota-host `127.0.0.1:18443` port-forward + 노트북 SSH 터널 |
| 기타 | Chart 기본 NetworkPolicy 4개(ingress) 생성됨. 초기 admin 비밀번호 Secret 삭제 |

### GitOps 선언

| 항목 | Staging | Production |
| --- | --- | --- |
| Application / AppProject | `ota-demo-staging` / `ota-staging` | `ota-demo-production` / `ota-production` |
| 대상 | in-cluster / `staging` | `https://192.168.56.30:6443` / `production` |
| 허용 리소스 | Deployment·Service, 클러스터 리소스 없음 | 같음 |
| Sync | 수동 (`syncPolicy` 없음) | 수동 |
| 배치 | `workload=platform` (worker-a1) | nodeAffinity worker-b1·b2 + topology spread(hostname, `matchLabelKeys: [pod-template-hash]`) |
| values | `values/staging.yaml` | `values/production.yaml` (digest는 Staging 통과 후에만 기입) |

데모 Chart(`charts/demo`)는 digest가 비었거나 `sha256:<64 hex>` 형식이 아니면 렌더링을 거부한다. 이미지에 들어 있는 `APP_VERSION`은 덮어쓰지 않는다.

### 관리 소유권

| 대상 | 관리 방식 |
| --- | --- |
| Argo CD 자체 | Helm (`helm/argocd/values.yaml`, 고정 Chart tgz) |
| 데모 앱 (A·B) | Git 변경 → `gitops-sync.sh`(Refresh → Diff → Sync → Wait). `kubectl edit/scale/set image` 사용 없음 |
| B 등록 | Argo CD cluster Secret. 인증은 B `kube-system/argocd-manager` SA 토큰, 권한은 production Role만 |

## 5. 이미지 연결표

| 항목 | G | C |
| --- | --- | --- |
| CI | day6-ci #2, commit `2f99fb73f694` | day6-ci #3, commit `50615d6ab9d2` |
| digest | `sha256:2db15224…0478` | `sha256:6068b90a…7b8e` |
| `/healthz` version | `2f99fb73f694-day6-ci-2` | `50615d6ab9d2-day6-ci-3` |
| CI test·scan·push | exit 0 · exit 0 · built = pushed | exit 0 · exit 0 · built = pushed |
| Staging 검증 (Sync revision) | `5883c09` → PASS (`21`) | `ae5054b` → PASS (`41`) |
| Production 반영 | `3980d98` (관문 B), `2dcef9f` (S3 복귀) | `6e77f20` (승격), `fb382f3` (S3 재승격) |
| 실행 imageID | 모든 Pod에서 기대 digest와 일치 | 모든 Pod에서 기대 digest와 일치 |
| 실행 전 B 캐시 | 없음 (STEP 6이 첫 Pull) | worker-b1·b2에 있음 (DAY6 테스트) |
| 최종 | — | Production 2/2 (worker-b1·b2), Staging 0 |

## 6. 배포·승격·실패 보류·복구

| 사건 | 결과 | 근거 |
| --- | --- | --- |
| Staging G 첫 배포 (worker-a1 첫 Pull) | Sync 시작 → Healthy 3초 | `20` |
| Production G 첫 배포 (B 첫 Pull) | 4초. Pull 118·125ms (20.6MB, 내부 Registry) | `33`, `34-prod-G-pull-events` |
| Staging C 검증 | 4초, PASS | `40`, `41` |
| Production G → C 승격 (캐시 있음) | 8초. 새 Pod Ready → 이전 Pod 종료 순서로 노드당 1개씩 교체. HTTP 568건 중 실패 0 (G 37 → C 531) | `45`, `46`, `47` |
| S1 Staging readiness `/not-ready` | 새 Pod NotReady(404), 이전 C Pod 유지. 183초 뒤 Degraded → `app wait` 종료(EXPECTED_FAIL) | `52`, `53` |
| S1 중 Production | `production.yaml` 마지막 Commit `6e77f20` 그대로, Pod 이름·노드 동일, PASS | `54-*` |
| S1 revert → Healthy | 1초 (새 ReplicaSet만 0으로, 기존 Pod는 그대로) | `55`, `56` |
| S2 Production readiness `/not-ready` | 새 Pod 1개 NotReady, 기존 C Pod 2개 Ready 유지. 182초 뒤 `ProgressDeadlineExceeded` → Degraded. **Synced이지만 Healthy 아님** | `62`, `63` |
| S2 중 HTTP | 1,138건 중 실패 0 (전부 C) | `61-s2-http` |
| S2 revert → Healthy | 1초. 복구 후 Pod 이름이 S2 전과 같다 (`86699c58ff-t8z2x`, `-brftk`) | `64`, `65` |
| S3 C → G / G → C | 8초 / 7초. HTTP 759건 중 실패 0 (G 70, C 689) | `70`~`73`, `70-s3-http` |
| 실패 Pod 종료 | 30초 (Terminating 3m9s → 3m39s) | `61-s2-pods-watch` |

- 실패 판정 시간 182~183초는 Deployment `progressDeadlineSeconds: 180`과 일치한다. Argo CD는 이 조건이 지나야 Progressing을 Degraded로 바꾼다.
- revert 복구가 1초인 것은 되돌린 Pod 템플릿이 기존 ReplicaSet과 같아 새 Pod를 띄울 필요가 없었기 때문이다. 이미지 전환(7~8초)과 다른 경로다.
- HTTP는 노드에서 ClusterIP를 0.5초 간격으로 조회한 결과다. '이 간격·이 구간에서 실패 0'이며 무중단을 일반화하지 않는다.

## 7. 자원 측정

### 측정 조건

- `measure.sh` v3, KSM run=1. 각 시점 a·b 두 번 측정했고 비교에는 b를 쓴다.
- P0: 08:22Z(설치 전). P1-install: 13:45Z(Argo CD 설치 직후, 앱 없음). P2-final: 14:55Z(Production C 2개, Staging·Agent 0).
- **P0와 P1 사이가 5시간 23분이다.** 이 사이 변경이 없던 cp-b의 RSS가 +150 MiB 늘었다. Host 수준 차이에는 시간 경과와 KSM 재배치가 섞여 있다.
- P0 두 표본 차(MemAvailable)는 19.6 MiB였다. 이 값은 '표본 간 차'로만 기록한다.

### Host

| 항목 | P0b | P1-install-b | P2-final-b | P2 − P0 |
| --- | --- | --- | --- | --- |
| MemAvailable (주 지표, MiB) | 20012.5 | 19813.2 | 19747.3 | −265.2 |
| RAM Used (Total − Avail) | 11797.6 | 11996.8 | 12062.8 | +265.2 |
| KSM 절약량 (general_profit) | 4485.8 | 4611.0 | 4397.6 | −88.2 |
| KSM 보정 사용량 (보조) | 16283.4 | 16607.8 | 16460.4 | +177.0 |
| Swap Used / si·so | 2.8 / 0·0 | 2.8 / 0·0 | 2.8 / 0·0 | 0 |
| Load 1m | 0.94 | 0.97 | 1.13 | +0.19 |
| CPU us / sy / id / wa (%) | 0.0 / 2.2 / 91.2 / 0.0 | 0.0 / 1.9 / 92.1 / 0.0 | 0.0 / 2.0 / 91.8 / 0.0 | — |
| Guest CPU gu (%) | 6.4 | 6.1 | 5.9 | −0.5 |
| Root / VM Storage | 13G / 32G | 13G / 33G | 13G / 33G | VM +1G (G 단위) |
| Total QEMU PSS (보조, MiB) | 10398.3 | 10555.0 | 10601.0 | +202.7 |
| Total QEMU RSS (보조, MiB) | 15085.0 | 15242.4 | 15245.1 | +160.1 |

### VM·Guest

| VM | QEMU PSS P0b → P2b (MiB) | QEMU RSS P0b → P2b | Guest MemAvailable P0b → P1b → P2b |
| --- | --- | --- | --- |
| cp-a | 1433.3 → 1540.7 (+107.4) | 2100.7 → 2100.7 | 983.4 → 814.1 → **719.3** (−264.1) |
| worker-a1 | 5252.7 → 5330.5 (+77.8) | 6197.2 → 6201.9 | 4308.7 → 4130.5 → 4033.4 (−275.3) |
| cp-b | 1703.0 → 1841.1 (+138.1) | 2754.3 → 2906.4 | 1824.9 → 1841.1 → 1800.3 (−24.6) |
| worker-b1 | 996.2 → 935.7 (−60.5) | 2003.7 → 2004.3 | 6279.4 → 6256.0 → 6246.2 (−33.2) |
| worker-b2 | 1013.2 → 953.0 (−60.2) | 2028.0 → 2030.5 | 6251.1 → 6267.0 → 6237.4 (−13.7) |

### K8s 할당 (worker-a1, allocatable 5825Mi · 4 CPU)

| 항목 | P0b | P1·P2 | 차이 |
| --- | --- | --- | --- |
| requests CPU / Memory | 610m / 928Mi | 910m / 1696Mi | +300m / +768Mi (Argo CD 예산과 일치) |
| limits CPU / Memory | 1600m / 2176Mi | 3350m / 4736Mi (81%) | +1750m / +2560Mi |

worker-b1·b2는 P2에 데모 Pod 1개씩 더해져 requests 300m·64Mi, limits 250m·128Mi다.

### 컨테이너 (`crictl stats`, MEM)

| 컨테이너 | P1-install | P2-final |
| --- | --- | --- |
| argocd application-controller | 24.8MB | 99.9MB |
| argocd server | 24.9MB | 28.0MB |
| argocd repo-server | 20.2MB | 25.1MB |
| argocd redis | 5.2MB | 5.3MB |
| **Argo CD 합계** | **75.1MB** | **158.3MB** (requests 768Mi의 약 20%) |
| jenkins (참고) | 890.4MB | 918.6MB |
| demo (worker-b1 / b2) | — | 11.6MB / 11.6MB (requests 64Mi) |

### 배포 구간 (13:47~14:40Z 연속 수집)

| 항목 | 값 |
| --- | --- |
| Host MemAvailable 최저 | 19630.5 MiB (14:20:20Z, S1 중) — P0b 대비 −382 MiB |
| Host CPU busy 최고 / gu 최고 | 27% (14:05:32Z, Production G 배포) / 18% (14:34:58Z, S3) |
| Swap si·so 합계 | 0 / 0 |
| worker-a1 MemAvailable 최저 | 3938.9 MiB (14:20:28Z, S1 Staging) |
| worker-b1 / b2 MemAvailable 최저 | 6238.9 / 6240.8 MiB, 메모리 PSI some avg10 최고 0.0 |
| VM별 QEMU RSS 최고 | worker-a1 6202.4 MiB, cp-b 2906.2 MiB |
| 수집 유지 | domstats 마지막 14:39:58Z(STEP 8 끝까지, sudo 갱신 유지) |

### 해석

1. **Argo CD의 비용은 Guest·K8s 지표로 본다.** worker-a1의 requests는 정확히 +768Mi·+300m이고, 실제 컨테이너 메모리는 75MB → 158MB다. worker-a1 Guest MemAvailable 감소(−275 MiB)는 컨테이너 사용량과 이미지·페이지 캐시를 합친 값과 맞는다.
2. **Host 차이(−265 MiB)는 Argo CD만의 비용이 아니다.** worker-a1의 QEMU RSS는 DAY6 빌드 때 이미 할당량(6GiB) 가까이 차 있어 거의 늘지 않았다(+4.7 MiB). Host RAM Used +265 MiB는 cp-a·cp-b의 PSS 증가(+245 MiB)와 KSM 절약량 감소(−88 MiB)가 대부분이고, P0→P1 5시간 동안의 자연 증가(cp-b RSS +150 MiB, B 변경 없음)가 섞여 있다.
3. **cp-a 여유가 줄었다.** cp-a Guest MemAvailable이 983 → 719 MiB(−264)로 줄어, 5대 중 남은 여유가 가장 작다. Argo CD 컨트롤러가 A의 리소스를 watch하면서 kube-apiserver 메모리가 늘어난 것으로 **추정**한다(cp-a 컨테이너별 측정 없음). cp-a 할당은 2GiB다.
4. **requests는 실사용보다 크다.** Argo CD 실사용은 requests의 약 20%, 데모 앱은 약 17%다. 다만 Controller는 관리 대상이 늘면서 4배가 됐으므로 실제 OTA 앱을 연결한 뒤 다시 잰다.
5. **limits 합계는 이미 높다.** worker-a1 limits 메모리는 4736Mi(81%)이고, CI Agent(limits 3584Mi)가 돌면 8320Mi(143%)가 된다. 실제 사용량은 낮아 지금 문제는 아니지만, limits는 동시 피크가 겹칠 때의 위험 지표로 계속 기록한다.

## 8. 실행 중 발견·Issue

| 시점 | 내용 | 원인 | 조치 | 상태 |
| --- | --- | --- | --- | --- |
| 계획 검토 | `applicationSet.enabled`가 Chart에 없음 | Chart 10.10.3 구조 | `replicas: 0` + `values-keycheck.py` | 해결 |
| 계획 검토 | 서버 dry-run 실패 예상 (applicationsets CRD 약 368KiB) | client-side apply의 last-applied 주석 한도 | `--server-side` dry-run (44개 통과) | 해결 |
| STEP 3-2 | `get pods,jobs -w` 오류 | watch는 리소스 종류 하나만 | `get pods -w` | 해결 |
| STEP 5 | Sync가 `Argo CD server address unspecified`로 STOP, 그 사이 stop Commit(`5c2f890`)까지 Push | CLI 로그인 누락 + 블록 일괄 붙여넣기 | `5883c09`로 revert, admin 비밀번호 재설정 후 로그인, 한 줄씩 실행 | 해결 |
| STEP 5 | `20-staging-G-sync.txt` PASS 기록 덮어씀 | 같은 증거 이름으로 재실행 | Argo CD history·operationState로 재기록 | 해결 (재기록 표시) |
| **STEP 6-3** | **B 등록 Secret에 관리자 클라이언트 인증서·키 저장, SA 토큰 없음** | `argocd cluster add`는 kubeconfig에 인증서가 있으면 SA 토큰 대신 그 인증서를 저장(v3.5.5 `cmd/util/cluster.go`) → Argo CD가 B에 cluster-admin으로 접속 | Production 앱 등록 전에 cluster Secret `config`를 SA 토큰 + CA로 교체. `bearerToken=있음 certData=없음 keyData=없음` 확인 | 해결 |
| STEP 8 | 실패 Pod 종료 30초 | python이 PID 1이라 SIGTERM 무시 → grace 30초 후 SIGKILL | 관측만 | DAY8 후보 |
| STEP 5~8 | Pod 시작 직후 readiness `connection refused` 경고 | readiness probe에 시작 대기 없음 | 결과 영향 없음 | DAY8 후보 |
| STEP 3 | `08-login`에 서버 버전 없음 | 로그인 전에 `argocd version` 실행 | 이미지 태그로 대체 | 기록 |
| STEP 9 | cp-a Guest MemAvailable 719 MiB | Argo CD watch로 apiserver 메모리 증가 추정 | 다음 측정부터 cp-a 컨테이너별 사용량 추가 | 관찰 |

## 9. 결정 사항

| 결정 | 내용 | 근거 |
| --- | --- | --- |
| Argo CD 고정 | Chart 10.10.3 / v3.5.5, 단일 Replica, ApplicationSet 0, Dex·Notifications 끔 | 2·4장 |
| 앱 변경 경로 | values 한 줄 변경 → 그 파일만 Commit·Push → 수동 Sync. 실패는 그 Commit만 revert | 6장 |
| Production digest | Staging 검증 PASS 후에만 기입. 빈 digest는 렌더링 거부 | 5장 |
| B 등록 인증 | production 한정 SA 토큰만 허용. 등록 후 cluster Secret의 `certData`·`keyData` 부재를 확인 | 8장 |
| Production 분산 | topology spread에 `matchLabelKeys: [pod-template-hash]` | 롤링 후에도 노드당 1개 유지 (`45`, `65`) |
| 비용 판단 지표 | 컴포넌트 비용은 Guest MemAvailable·K8s requests·컨테이너 사용량으로, Host 값은 보조 | 7장 해석 1·2 |

## 10. 다음 단계 후보

- 데모 앱 SIGTERM 처리 또는 `terminationGracePeriodSeconds` 조정, readiness 시작 대기 추가 (변경 시 새 이미지 → 같은 승격 경로로 반영)
- cp-a 메모리 여유 추적 (컨테이너별 측정 추가)
- `helm/argocd/versions.md`의 이미지 digest 칸 채우기, `argocd version` 서버 버전 기록
- `docs/baseline/day6.md` 작성
- 실제 OTA 서비스를 이 GitOps 경로(Staging 검증 → digest 승격 → Git 복구)에 연결
- Kubernetes 업그레이드는 별도 변경 계획으로 다룬다

## 11. 증거 파일

| 범위 | 파일 |
| --- | --- |
| 준비·설치 | `00-timeline`, `00-day7-files.sha256`, `01-state-before`, `01-leftovers`, `02-chart-*`, `03-argocd-cli`, `04-values-keycheck`, `05-*`, `06-image-prepull`, `07-*`, `08-login`, `09-crictl-stats-P1-install` |
| 데모 선언 | `10-demo-*`, `11-appprojects` |
| 관문 A | `20`~`24` (`20`은 재기록본) |
| B 등록·관문 B | `30-cluster-b-add`, `31-cluster-b-rbac`(SA 토큰 교체 후), `32-cluster-b-connection`, `33`~`35` |
| 승격 | `40`~`47` (`44-promotion-checklist`, `45-prod-C-http`) |
| S1·S2·S3 | `50`~`57`, `60`~`65` (`61-s2-http`), `70`~`74` (`70-s3-http`) |
| 최종 | `80-sample-summary`, `81-final-*`, `82-crictl-stats-P2` |
| 측정 | `measure/20261014-081540-day7-P0a`, `-082156-day7-P0b`, `-133817-day7-P1-install-a`, `-134422-day7-P1-install-b`, `-134744-day7-deploy-*`, `-134750-day7-deploy-b-*`, `-144815-day7-P2-final-a`, `-145442-day7-P2-final-b` |