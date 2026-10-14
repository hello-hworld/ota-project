# DAY6 Result — Helm 기반 Jenkins 구축과 CI 검증

- 진행: 2026-10-13 14:25 ~ 2026-10-14 15:26 (KST). 10-13 17:48 ~ 10-14 09:43 중단. 본문 시각은 증거 파일과 같은 UTC
- 실행 문서: `DAY6_실행` (계획서 `DAY6_Helm_기반_CI_실행계획.md`를 검토·보완한 버전. 계획 대비 변경 21개, 외부 검토 반영 13개)
- 기준 커밋: DAY6 실행 파일 `f006d37` → STEP 17 `972c135`
- 증거 경로: `docs/evidence/day6/`, `docs/evidence/measure/*day6*`

## 1. 요약

Cluster A의 worker-a1에 Jenkins를 Helm(Chart 5.9.68)으로 설치하고, Kubernetes Agent Pod 안에서 Test → Build → Scan → Push를 하는 CI를 만들었다. CI가 Push한 이미지를 digest로 Cluster B의 두 Worker에서 실행했다.

- 관문 A(Helm 설치·관리)와 관문 B(CI 경로)의 핵심 완료 기준을 통과했다. 증거 세 곳은 비거나 실패했다. STEP 1 B context와 STEP 9-3 영속성은 다른 증거로 판정했고, STEP 3-1 커널 146 원인은 미판정이다(9장).
- run01·run02 모두 SUCCESS, built digest = pushed digest, Registry manifest 200이었다. 이 두 이미지가 DAY7의 G·C다.
- 실패 3종(테스트 실패, 검사 오류, 정책 위반)은 모두 Push 전에 멈췄다. 취소한 빌드의 Agent Pod는 30초 뒤 삭제됐다. 서로 다른 Job은 lock으로 순서대로 실행됐고, 동시에 Running인 Agent Pod는 최대 1개였다.
- Jenkins의 상시 비용은 K8s requests 260m·800Mi, 컨테이너 메모리 612MB(설치 후) → 881MB(CI 후)였다. worker-a1 Guest MemAvailable은 P0 대비 −963 MiB다.
- Host MemAvailable은 P0 대비 −892 MiB였다. 같은 기간 KSM 절약량이 0에서 4.2 GiB로 늘어, 이 값만으로는 비용을 말할 수 없다. KSM 보정 사용량은 +5.2 GiB다.
- 빌드 1회(run02)의 실제 작업은 18초였다. Agent Pod가 Running이 된 뒤 Test 시작까지 24초, 작업이 끝난 뒤 Pod 삭제까지 36초가 더 걸렸다. 빌드 중 Host CPU busy 최고 25%, Swap 0이었다.

결과는 '데모 앱의 CI 경로 검증'이다. 빌드 피크는 run01·run02 각 1회 값이고, 빌드와 Production 부하를 동시에 건 시험(D05)은 하지 않았다.

## 2. 범위와 결과

| 작업 | 결과 | 근거 |
| --- | --- | --- |
| STEP 0 파일 준비 | ✅ measure.sh v3, sample.sh, cold-backup·restore, 06·07 Playbook, Helm values, CI 파일 커밋 | `f006d37`, `262b7b0` |
| STEP 1 관리 도구·A/B context | ⚠️ kubectl v1.30.14, Helm v3.18.6, Ansible core 2.16.3. 증거의 B 확인 블록이 A(192.168.56.20)를 출력 | `00-tools`, `01-contexts` |
| STEP 2 DAY5 상태·e2e 정리 | ✅ 5 Node Ready, Registry `/v2/` 200, worker-a1 e2e 이미지 0개 | `02`, `03` |
| STEP 3 자동 업데이트 중지 | ⚠️ VM 5대·Host의 APT 주기 작업 `"0"`, timer 2개 disabled/inactive, snap 없음. 커널 146 원인 로그 수집은 명령 오류로 실패 | `05*`, `c--auto-upgrade-all.log`, `04` |
| STEP 4 복구 지점 R1·재기동 | ✅ `R1_BACKUP_OK`(qemu-img check 5/5, 해시 5/5, 26G), 5 Node Ready, VM `reboot-required=no` | `06-*` |
| STEP 5 P0 | ✅ P0a·P0b 수집 실패 0 | measure |
| STEP 6 Chart 고정 | ✅ `jenkins-5.9.68.tgz` sha256 `5eba515b…c020` 커밋 | `07-*` |
| STEP 7 values·렌더링 | ✅ lint 1/1, 서버 dry-run 12개, 렌더 검토(이미지 3종, containerCap 1, PVC keep, Registry 설정 없음) | `08-*` |
| STEP 8 설치·플러그인·권한·P1-install | ✅ revision 1 → 3, 플러그인 69개, lockable-resources 버전 고정, 권한 5줄 기대값, P1-install a·b 실패 0 | `09-*` |
| STEP 9 smoke·cap·영속성 | ⚠️ smoke SUCCESS, `max_running_agents=1`. Controller 재생성 기록이 대기 줄에서 끊김 | `10-*` |
| STEP 10 upgrade·rollback | ✅ revision 4 → 5(Rollback to 3), `VALUES_MATCH`, Pod 재시작 없음 | `11` |
| STEP 11 P1-gateA | ✅ a·b 실패 0 | `12`, measure |
| STEP 12 SCM·Trivy 캐시·도구 digest | ✅ 공개 저장소 HTTPS(자격 증명 없음), `trivy-cache` Bound, 5종 digest, 빈 입력 해시 0줄 | `13-image-digests`, 콘솔 |
| STEP 13 BuildKit 점검·Jenkinsfile | ✅ rootless 동작, 전환안 A·B 미적용 | `13-buildkit-check-rootless` |
| STEP 14 CI run01·run02 | ✅ 둘 다 SUCCESS. 첫 build #1은 파라미터 미등록으로 실패(8장) | `14-*` |
| STEP 15 Cluster B 실행 | ✅ worker-b1·b2 Ready, imageID = 기대 digest, `/healthz` 버전 일치 | `15-*` |
| STEP 16 실패·취소·동시성 | ✅ 기대 결과 5/5, `max_running_agents=1`. s3~s5 태그 전후 파일은 없음(6장) | `16-*` |
| STEP 17 P2 | ✅ a·b 실패 0 | `17`, measure |
| `helm/jenkins/versions.md` | ⚠️ 표의 lockable-resources·Controller digest·도구 행 미기입(아래 STEP 12-3 절에만 기록) | — |
| 복구 지점 R2 | ➖ 만들지 않음. 마지막 콜드 복구 지점은 R1(`R1-20261013-0751`) | — |

## 3. 버전과 조건

| 구성요소 | 버전 | 비고 |
| --- | --- | --- |
| Kubernetes A/B | v1.30.14, containerd 2.2.1 | |
| Jenkins Chart | jenkins 5.9.68 (appVersion 2.580.1) | `helm/jenkins/chart/jenkins-5.9.68.tgz` |
| Jenkins Controller | `jenkins/jenkins:2.580.1-jdk25` | digest `42fc298c…455f` (`09-helm-install`) |
| Config reload sidecar | `kiwigrid/k8s-sidecar:2.11.2` | digest `2912be00…a4f6` |
| Agent (jnlp) | `jenkins/inbound-agent:3385.vf1123fb_515da_-1-jdk25` | digest 미기록 |
| 플러그인 | 69개. kubernetes 4557.ve746270f672f, workflow-aggregator 608.v67378e9d3db_1, git 5.10.1, configuration-as-code 2133.ve570217cdb_cd, lockable-resources 1560.va_b_cd589f23eb_ | `09-plugins-installed` |
| BuildKit | v0.34.0-rootless | digest `65eca3c0…3855`. rootful `v0.34.0`(`b059f8d7…`)은 전환안용으로 기록만 |
| Trivy | 0.75.0 | digest `af6acf9a…5daa`. 제외 버전(0.69.4~0.69.6) 아님. DB v2, UpdatedAt 10-14 01:19Z |
| skopeo | v1.22.3 | digest `22ea3c3b…7ed9`. quay `stable`의 최신. GitHub 최신 v1.24.1은 quay에 없음 |
| 베이스 이미지 | `python:3.12-alpine` | digest `1b668429…4ab4` (Python 3.12.15, Alpine 3.24.2) |
| Helm / kubectl / Ansible (ota-host) | v3.18.6 / v1.30.14 / core 2.16.3 | `00-tools` |
| Host 커널 / VM 커널 | 6.8.0-139 / 6.8.0-146 | Host는 새 커널 설치 후 재부팅 대기(`reboot-required`) 상태로 DAY6 전 구간을 측정 |
| KSM | run=1 | 모든 측정 공통 |
| 자동 업데이트 | VM 5대·Host APT 주기 작업 `"0"`, apt-daily timer 2개 disabled/inactive | P0 이후 모든 측정 파일에서 같은 값 |
| 접근 경로 | ota-host에 Tailscale. 자체 자동 업데이트 끔, subnet route·exit node 없음 | R1·P0 전에 설치. 증거 파일 없음(작업 기록만) |

## 4. 구성 결과

### Jenkins (Cluster A)

| 항목 | 값 |
| --- | --- |
| Release / Namespace | `jenkins` / `platform`, Helm `--atomic --wait` |
| Revision | 1 설치(10-13 08:26:27Z) → 2 lockable-resources 버전 고정(08:44:44Z) → 3 `createSecret: true`(10-14 00:55:59Z) → 4 upgrade 시험(03:12:23Z) → 5 Rollback to 3(03:15:23Z) |
| 배치 | `workload=platform` → worker-a1. StatefulSet 1개(jenkins + config-reload) |
| requests / limits | Controller 250m·768Mi / 1000m·1536Mi, sidecar 10m·32Mi / 100m·128Mi. JVM `-Xms256m -Xmx768m`, executor 0 |
| 저장소 | PVC `jenkins` 10Gi local-path, `helm.sh/resource-policy: keep` |
| 관리자 계정 | 클러스터 Secret `jenkins-admin`을 `createSecret: true` + `existingSecret`으로 마운트. 값은 저장소·증거에 없음 |
| 접속 | Service ClusterIP. ota-host `127.0.0.1:18080` port-forward + 노트북 SSH 터널(Tailscale 주소) |
| 플러그인 | `initializeOnce: true`. Chart 기본 4개 + lockable-resources, 의존성 포함 69개 |

### Agent와 CI

| 항목 | 값 |
| --- | --- |
| Namespace / 노드 | `ci` / worker-a1(`workload=platform`). watch에 기록된 Agent Pod 13개 모두 worker-a1 |
| Cloud 설정 | containerCap 1, instanceCap 1, idleMinutes 0, podRetention Never, garbageCollection 300초, WebSocket, Agent 연결 대기 100초 |
| Pod Template | 기본 jnlp + `ci/agent-pod.yaml` merge(python, buildkit, trivy, skopeo) |
| Agent Pod 합계 | requests 1100m·896Mi, limits 4500m·3584Mi |
| 배타 제어 | stage `lock(resource: 'ota-exec-slot')`을 Agent 할당 전에 잡는다 |
| 단계 | Checkout → Test(unittest 3개) → Build(buildctl → OCI tar) → Scan DB → Scan(Trivy `--ignore-unfixed --exit-code 1`, 심각도 파라미터, 기본 CRITICAL) → Push(skopeo `--preserve-digests`) → post에서 컨테이너별 cgroup 기록 |
| 이미지 식별 | 태그 `<커밋 12자>-<Job>-<빌드 번호>`, 이미지 안 `APP_VERSION` = 태그. 실행은 digest 참조. Push 뒤 manifest digest가 built digest와 다르면 실패 |
| Trivy 캐시 | PVC `ci/trivy-cache` 2Gi local-path |
| BuildKit | rootless, `--oci-worker-no-process-sandbox`, seccomp·AppArmor Unconfined, 상태 디렉터리는 emptyDir. Registry에 접근하지 않음 |
| SCM | `https://github.com/hello-hworld/ota-project.git` `*/main`. 공개 저장소라 자격 증명 없이 Checkout(`No credentials specified`) |
| Job | UI에서 생성. `day6-ci`·`day6-ci-2`는 Pipeline script from SCM(`Jenkinsfile`), smoke Job 2개(`day6-agent-smoke`, `-2`)는 스크립트 직접 입력 |

### 권한 (`09-rbac`)

| 확인 | 결과 |
| --- | --- |
| Controller: `ci`에 Pod 생성 | yes |
| Controller: `platform`에 Pod 생성 / Secret 조회 | no / no |
| Agent: `ci`에 Pod 생성 / `platform`에 Deployment 생성 | no / no |

### 관리 소유권

| 대상 | 관리 방식 |
| --- | --- |
| Jenkins 자체 | Helm (`helm/jenkins/values.yaml`, 저장소에 커밋한 Chart tgz) |
| CI 정의 | 저장소의 `Jenkinsfile`, `ci/agent-pod.yaml`, `demo/` (Jenkins가 원격 저장소에서 읽음) |
| Job 정의 | Jenkins UI. Jenkins Home(PVC)에만 있고 Git에는 없음 |
| `trivy-cache` PVC | `kubectl apply -f ci/trivy-cache-pvc.yaml` |

## 5. CI 실행 결과

### 이미지 연결표

| 항목 | run01 (`day6-ci` #2) | run02 (`day6-ci` #3) |
| --- | --- | --- |
| commit | `2f99fb73f694` | `50615d6ab9d2` (그 사이 증거 커밋만 추가. `demo`·`ci`·`Jenkinsfile`은 같음) |
| 태그 | `2f99fb73f694-day6-ci-2` | `50615d6ab9d2-day6-ci-3` |
| digest | `sha256:2db15224…0478` | `sha256:6068b90a…7b8e` |
| Test / Scan / Push | 3 passed / CRITICAL 0건 / built = pushed, manifest 200 | 같음 |
| 이미지 | 19.7 MiB, layer 6개(베이스 4개 공유) | 같음 |
| 이후 사용 | DAY7 G | DAY6 STEP 15, DAY7 C |

### 단계별 시간

| 구간 | run01 | run02 |
| --- | --- | --- |
| Agent Pod 생성 → Running | 1초 | 1초 |
| Running → Test 시작 | 25초 | 24초 |
| Test / Build / Scan DB / Scan / Push | 2 / 14 / 69 / 1 / 1초 | 2 / 14 / 1 / 1 / 0초 |
| Push 끝 → Pod 종료 시작 | 4초 | 5초 |
| Pod 종료 대기 | 30초 | 31초 |
| Agent Pod 수명 (생성 → 삭제) | 2분 28초 | 1분 19초 |

Jenkins의 빌드 전체 소요(Duration)는 기록하지 않았다.

캐시 범위:

- 도구 이미지 4종은 실패한 build #1에서 처음 받았다(Pod ContainerCreating 47초). run01·run02에서는 Pull이 없다.
- Trivy DB는 run01에서 처음 받았고(69초), run02는 재사용했다.
- BuildKit 상태 디렉터리가 emptyDir라 매번 비어 있다. 두 run 모두 베이스 이미지를 다시 받았다(11초). 그래서 run02는 'Trivy DB만 캐시된 빌드'다.

### 컨테이너 피크·CPU throttling (`cgroup-*.txt`)

| 컨테이너 | requests / limits | memory.peak run01 / run02 (MiB) | throttling run01 / run02 |
| --- | --- | --- | --- |
| jnlp | 200m·256Mi / 500m·512Mi | 166.6 / 161.0 | 262회·49.1초 / 236회·43.8초 |
| python | 100m·64Mi / 500m·256Mi | 24.0 / 24.3 | 11회·0.5초 / 10회·0.5초 |
| buildkit | 500m·256Mi / 2·1536Mi | 166.4 / 165.4 | 0 / 0 |
| trivy | 200m·256Mi / 1·1Gi | **1024.0 (limit 도달)** / 35.2 | 9회·0.1초 / 4회·0.1초 |
| skopeo | 100m·64Mi / 500m·256Mi | 34.7 / 31.6 | 0 / 0 |

- run01 trivy의 peak는 1,073,745,920 B로 limit(1,073,741,824 B)보다 4 KiB 컸다. 검사는 성공했다. `memory.events`를 남기지 않아 메모리 압박인지 파일 캐시인지 구분할 수 없다.
- jnlp는 CPU limit 500m에서 run마다 44~49초 throttle됐다. Running 뒤 Test 시작까지 24~25초가 걸린 구간과 겹친다.
- 컨테이너별 peak의 합은 Node 동시 피크가 아니다. Node 여유는 7장의 worker-a1 Guest MemAvailable 최저값으로 본다.

### Cluster B 실행 (STEP 15)

| 항목 | worker-b1 | worker-b2 |
| --- | --- | --- |
| 참조 | `192.168.56.21:32000/day6/demo@sha256:6068b90a…7b8e`, `imagePullPolicy: Always` | 같음 |
| Pull | 681ms, 20,634,679 B | 635ms, 같은 크기 |
| 상태 | Ready (생성 6초 안) | Ready |
| imageID | 기대 digest와 일치 | 일치 |
| `/healthz` | `{"status": "ok", "version": "50615d6ab9d2-day6-ci-3"}` | 같음 |

검증용 Namespace `day6-ci-test`는 기록 후 삭제했다. Registry API의 200(STEP 14)과 kubelet의 실제 Pull·실행(STEP 15)을 따로 확인했다.

## 6. 실패·취소·동시성 (STEP 16)

| 시나리오 | 빌드 | 결과 | Push | Agent Pod Running → 삭제 |
| --- | --- | --- | --- | --- |
| s1 테스트 실패 | `day6-ci` #4 | FAILURE. `FAILED (failures=1)`, `test-exit=1`, Build 이후 생략 | 없음 | 05:50:35 → 05:51:37 |
| s2 검사 오류 | #5 | FAILURE. 빈 캐시 + `--skip-db-update`를 Trivy가 거부(FATAL), `scan-exit=1` | 없음 | 05:51:32 → 05:52:49 |
| s3 정책 위반 | #6 | FAILURE. 전 심각도 기준 수정판 있는 취약점 7건(zlib MEDIUM 1, pip MEDIUM 5·LOW 1), `scan-exit=1` | 없음 | 05:57:23 → 05:58:39 |
| s4 빌드 중 취소 | #7 | ABORTED(`+ sleep 120` 중 중단). post 실행, cgroup 파일 5개 남음 | 없음 | 05:59:56 → 06:01:09 (중단 30초 뒤 삭제) |
| s5 다른 Job 동시 요청 | #8 → `day6-ci-2` #2 | 둘 다 SUCCESS. #2 콘솔에 `locked by build day6-ci #8`, 대기 후 `Lock acquired` → 그다음 Pod 생성 | 태그 2개(`…-day6-ci-8`, `…-day6-ci-2-2`) | 06:02:22 → 06:03:39, 06:03:12 → 06:04:33 |

- 태그 변화: s1 전(`14-run02/registry-check`에서 옮김)과 s2 후가 같아 s1·s2 모두 태그를 만들지 않았다. s3·s4·s5의 전후 파일은 없다. DAY7 STEP 1의 tags/list(`day7/01-state-before`, 10-14 08:23Z 커밋)가 정확히 4개(run01, run02, s5 2개)라 s3·s4는 태그를 만들지 않았고 s5는 2개를 만들었다.
- s3 결과는 기본 정책(수정판 있는 CRITICAL만 차단)에서는 통과하는 이미지라는 뜻이기도 하다. CRITICAL·HIGH는 0건이었다.
- `max_running_agents=1`(16-agent-max-running). 다만 종료 중인 Pod와는 겹쳤다. s5에서 06:03:12~06:03:39(27초), s1→s2에서 05:51:32~05:51:37(5초) 동안 앞 Pod가 5/5 Ready인 채 Terminating이었다.
- 모든 Agent Pod가 종료에 30~31초 걸렸다. Agent 컨테이너의 PID 1인 `cat`은 SIGTERM 처리기가 없어 신호를 무시하고, grace 30초 뒤 SIGKILL로 끝난다.
- `day6-ci-2` #1은 파라미터 등록용 실행이다(build #1과 같은 이유로 Build 단계 실패, Push 없음).

## 7. 자원 측정

### 측정 조건

- `measure.sh` v3, KSM run=1, 자동 업데이트 중지 상태. 각 시점 a·b를 약 6분 간격으로 쟀고, 비교에는 b를 쓴다.
- P0: 10-13 08:18Z(R1 재기동 뒤, Jenkins 없음). P1-install: 10-14 02:21Z(설치 18시간 뒤, 마지막 Jenkins Pod 재시작 57분 뒤). P1-gateA: 03:42Z(관문 A 끝). P2: 06:25Z(CI 끝, Agent 0).
- **P0는 재기동 직후라 KSM이 아직 페이지를 합치지 않은 상태(절약량 −41.8 MiB)였고, P1-install은 18시간 뒤라 4877 MiB를 합친 상태였다.** 이 두 시점의 Host 지표 차이는 Jenkins 비용으로 쓰지 않는다.
- 관측 변동폭(a·b 차 최대): Host MemAvailable 66.5 MiB(P2), KSM 보정 사용량 82.9 MiB(P2), worker-a1 Guest MemAvailable 17.7 MiB(P0). 아래 구간 차이는 모두 이보다 크다.

### Host

| 항목 | P0b | P1-install-b | P1-gateA-b | P2-b | P2 − P0 |
| --- | --- | --- | --- | --- | --- |
| MemAvailable (주 지표, MiB) | 21103.3 | 23170.4 | 22200.4 | 20211.5 | −891.8 |
| RAM Used (Total − Avail) | 10706.8 | 8639.7 | 9609.7 | 11598.6 | +891.8 |
| KSM 절약량 (general_profit) | −41.8 | 4876.7 | 4609.7 | 4347.8 | +4389.6 |
| KSM 보정 사용량 (보조) | 10665.0 | 13516.4 | 14219.4 | 15946.4 | +5281.4 |
| Swap Used / si·so | 2.8 / 0·0 | 2.8 / 0·0 | 2.8 / 0·0 | 2.8 / 0·0 | 0 |
| Load 1m | 1.11 | 0.64 | 0.96 | 1.13 | +0.02 |
| CPU us / sy / id / wa (%) | 0.0 / 2.1 / 91.9 / 0.0 | 0.0 / 2.0 / 92.6 / 0.0 | 0.0 / 2.2 / 91.4 / 0.0 | 0.0 / 1.8 / 92.9 / 0.0 | — |
| Guest CPU gu (%) | 5.8 | 5.4 | 6.1 | 5.1 | −0.7 |
| Root / VM Storage | 13G / 27G | 13G / 28G | 13G / 29G | 13G / 32G | VM +5G |
| Total QEMU PSS (보조, MiB) | 9666.7 | 7347.8 | 8287.1 | 10181.7 | +515.0 |
| Total QEMU RSS (보조, MiB) | 9755.6 | 12258.4 | 13132.7 | 14706.6 | +4951.0 |

### 구간별 차이 (MiB)

| 구간 | Host MemAvailable | KSM 보정 사용량 | worker-a1 QEMU RSS | worker-a1 Guest MemAvailable |
| --- | --- | --- | --- | --- |
| Jenkins 설치 (P1-install − P0) | +2067.1 | +2851.4 | +2075.3 | −651.0 |
| 관문 A 절차 (P1-gateA − P1-install) | −970.0 | +703.0 | +872.3 | +100.5 |
| CI (P2 − P1-gateA) | −1988.9 | +1727.0 | +1352.5 | −412.7 |
| 합계 (P2 − P0) | −891.8 | +5281.4 | +4300.1 | −963.2 |

### VM·Guest

| VM | QEMU PSS P0b → P2b (MiB) | QEMU RSS P0b → P2b | Guest MemAvailable P0b → P1-install → P1-gateA → P2 |
| --- | --- | --- | --- |
| cp-a | 2053.3 → 1409.7 (−643.6) | 2070.8 → 2098.7 (+27.9) | 1040.2 → 967.5 → 983.1 → 986.5 (−53.7) |
| worker-a1 | 1879.5 → 5432.3 (+3552.8) | 1897.0 → **6197.1** (+4300.1) | 5263.8 → 4612.8 → 4713.3 → **4300.6** (−963.2) |
| cp-b | 2428.7 → 1642.6 (−786.1) | 2446.2 → 2718.2 (+272.0) | 1898.4 → 1877.9 → 1847.0 → 1862.3 (−36.1) |
| worker-b1 | 1648.5 → 839.4 (−809.1) | 1666.2 → 1845.3 (+179.1) | 6284.1 → 6292.7 → 6293.5 → 6272.8 (−11.3) |
| worker-b2 | 1656.8 → 857.7 (−799.1) | 1674.4 → 1845.6 (+171.2) | 6312.2 → 6292.2 → 6277.1 → 6269.0 (−43.2) |

### worker-a1 안 (`free -m`, `crictl stats`, `du`)

| 항목 | P0b | P1-install-b | P1-gateA-b | P2-b |
| --- | --- | --- | --- | --- |
| used / buff·cache (MiB) | 661 / 904 | 1313 / 2433 | 1212 / 3235 | 1624 / 4067 |
| Root Used (/ 58G) | 3.9G | 5.2G | 5.9G | 8.5G |
| Local PV 합계 | 18M (registry만) | 237M | 237M | 1.8G (trivy-cache 1.6G, jenkins 224M, registry 39M) |
| jenkins / config-reload MEM | — | 534.2MB / 77.59MB | 395.8MB / 76.05MB | 804.5MB / 76.06MB |

### K8s 할당 (worker-a1, allocatable 5825Mi · 4 CPU)

| 상태 | requests CPU / MEM | limits CPU / MEM |
| --- | --- | --- |
| P0 (Jenkins 설치 전) | 350m / 128Mi | 500m / 512Mi |
| P1·P2 (+ Jenkins) | 610m (15%) / 928Mi (15%) | 1600m (40%) / 2176Mi (37%) |
| + Agent Pod 1개 (spec 합으로 계산) | 1710m (42.8%) / 1824Mi (31.3%) | 6100m (152.5%) / 5760Mi (98.9%) |

### 빌드 구간 (`sample.sh` 연속 수집)

| 항목 | build #1 (실패, 대기 포함 16분) | run01 | run02 |
| --- | --- | --- | --- |
| 수집 구간 (UTC) | 05:02:24 ~ 05:18:24 | 05:27:38 ~ 05:31:21 | 05:37:38 ~ 05:39:19 |
| Host MemAvailable 시작 → 최저 (MiB) | 21517.2 → 20879.1 | 20901.3 → 20339.6 (05:30:15) | 20449.9 → 20441.1 (05:37:58) |
| Host CPU busy 최고 (100 − id) | 22% (05:05:18, 빌드 전 대기 중) | 26% (05:30:14) | 25% (05:37:53) |
| Host us+sy / wa / gu 최고 (%) | 9 / 2 / 18 | 12 / 4 / 18 | 13 / 2 / 14 |
| Swap si·so 최고 | 0·0 | 0·0 | 0·0 |
| worker-a1 Guest MemAvailable 최저 (MiB) | 4364.2 | 4256.0 (05:30:16) | 4246.0 (05:38:40) |
| worker-a1 Guest us+sy 최고 | 28% | 28% | 24% |
| worker-a1 vCPU 사용 최고 (domstats, vCPU 1개 = 100%) | 112% | 139% | 151% |
| worker-a1 QEMU RSS 시작 → 끝 (MiB) | 5429.5 → 5965.3 | 5973.2 → 6185.2 | 6185.3 → 6185.7 |
| KSM 절약량 시작 → 끝 (MiB) | 4569.7 → 4563.8 | 4569.4 → 4568.0 | 4578.0 → 4579.8 |

세 구간 모두 cp-a·cp-b는 vCPU 1개 기준 평균 31%, worker-b1·b2는 11~12%로 같았다.

### 해석

1. **Jenkins 설치 비용은 Guest·K8s·컨테이너 지표로 본다.** worker-a1 Guest used +652 MiB(661 → 1313), 컨테이너 612MB, requests +260m·+800Mi가 서로 맞는다. 같은 구간 Host MemAvailable +2067 MiB는 KSM 절약량이 0에서 4877 MiB로 늘어난 결과다.
2. **관문 A 절차의 흔적은 작다.** Jenkins Pod가 다시 만들어져 컨테이너 메모리가 534 → 396MB로 줄었고(Guest used −101 MiB), Agent 이미지 등으로 buff/cache가 +802 MiB 늘었다.
3. **CI의 흔적은 JVM과 캐시다.** Jenkins 컨테이너 396 → 805MB(`-Xmx768m` 안), buff/cache +832 MiB, Root +2.6G, `trivy-cache` 1.6G, Registry Local PV 18M → 39M(`day6/demo` 태그 4개).
4. **worker-a1 QEMU RSS가 상한에 닿았다.** P2의 6197.1 MiB는 할당 6144 MiB + QEMU 오버헤드 약 53 MiB다. 게스트가 한 번 쓴 메모리는 반환 장치가 없어 Host에 남는다. 이후 worker-a1에 무엇을 올려도 Host RSS·MemAvailable에는 거의 나타나지 않는다.
5. **KSM 절약량이 4877 → 4610 → 4348 MiB로 줄고 있다.** 게스트가 메모리를 새로 쓰면서 합쳐졌던 페이지가 풀린다. KSM 보정 사용량 +5281 MiB 가운데 4348 MiB를 지금 KSM이 메우고 있다.
6. **대조군의 변화는 수십 MiB다.** 이번 작업과 무관한 cp-a·cp-b·worker-b1·b2의 Guest MemAvailable 변화는 −11 ~ −54 MiB였다. worker-a1의 −963 MiB는 이보다 훨씬 크다.
7. **빌드 1회는 Host 수준에서 거의 구분되지 않는다.** Host CPU busy 최고 25~26%는 빌드 전 대기 중에 나온 22%와 큰 차이가 없다. 게스트 수준(worker-a1 us+sy 24~28%, idle 1~2%)에서는 구분된다. 빌드 중 다른 VM의 CPU·메모리 변화는 없었다.
8. **CPU 지연은 Host 경합이 아니라 설정이 만들었다.** jnlp limit 500m에서 44~49초 throttle, Running 뒤 Test 시작까지 24~25초, 종료 대기 30초다. 실제 작업(run02)은 18초였다.
9. **위험은 실사용이 아니라 limits 합이다.** 상시 limits는 allocatable의 37%지만 Agent Pod 하나가 붙으면 98.9%가 된다. 실사용 최저 여유는 Guest MemAvailable 4246 MiB였다.
10. **Host 메모리는 overcommit이 아니다.** VM 할당 합 25,600 MiB / Host 31,810 MiB. 모든 VM이 할당량을 다 쓰고 KSM 공유가 전부 풀리는 경우에도 Host MemAvailable 약 4,520 MiB(4.4 GiB)가 남는다. 할당 합 + QEMU 오버헤드 5 × 약 55 + VM 밖 Host 사용량 1417 MiB(P2 RAM Used − PSS)로 계산한 추정이다.

## 8. 실행 중 발견·Issue

| 시점 | 내용 | 원인 | 조치 | 상태 |
| --- | --- | --- | --- | --- |
| 계획 검토 | 계획서 대비 21개 보완(필수 6개: 06 Playbook 변경 전 상태 기록, lockable-resources 첫 설치 전 추가, measure.sh 기본값, KSM·PSS 자동 기록, Trivy 사고 버전 제외, SCM 결정) + 외부 검토 13개 | 계획서 누락·오류 | 실행 문서 반영 | 반영 |
| STEP 1 | 노트북 → ota-host SSH 불가 | Issue-01(학원 Wi-Fi Client Isolation 추정) | ota-host에 Tailscale 설치(R1·P0 전, 자동 업데이트 끔, subnet route 없음). SSH·Jenkins UI 터널을 Tailscale 주소로 | 우회 |
| STEP 1 | `01-contexts`의 B 확인 블록이 A를 출력 | 확인 명령 오류 | B 연결은 모든 측정의 `[K8s] ota-b`와 STEP 15로 확인 | 증거 보완 필요 |
| STEP 2 | `02-day5-state`에 `a resource cannot be retrieved by name across all namespaces`. `stagins` Namespace 남아 있음 | 확인 명령 인자 오류. `stagins`는 DAY5 오타 | Node·Registry 확인은 유효, 비정상 Pod 없음은 `06-restart`로 확인. `stagins`는 DAY7 STEP 1에서 삭제 | 기록 |
| STEP 3-1 | 커널 146 원인 로그 수집 실패 | ad-hoc 명령의 따옴표 짝 오류, `histroy.log` 철자 | 원인 미판정(unattended-upgrades 추정 유지) | 미해결 |
| STEP 3 | 로그 파일 이름 혼선. 05a~05d가 재실행으로 덮여 모두 `changed=0`, 실제 변경 기록은 `c--auto-upgrade-all.log`(VM 4대 `changed=2`), worker-b2 카나리 변경 기록 없음, `c--auto-upgrade-rerun.log`는 인자 오류 출력 | 파일 이름 오타, 같은 이름으로 재실행 | 최종 상태는 이후 모든 측정의 자동 업데이트 항목으로 확인. 원래 상태(Ubuntu 기본값 `"1"`, timer enabled/active)는 `c--auto-upgrade-all.log`의 before 기록 | 기록 |
| STEP 3-4 | Host 적용 첫 시도 `no hosts matched` | `-e target_hosts=ota_hosts=ota_host` 중복 입력 | 재실행 → `changed=2`, assert ok | 해결 |
| STEP 3 | Host `reboot-required=yes`(커널 6.8.0-139 실행 중) | 자동 업데이트 중지 전에 새 커널이 설치됨 | 측정 조건 유지를 위해 DAY6 동안 재부팅 보류 | 보류 |
| STEP 7-1 | 관리자 Secret의 비밀번호를 빈 값으로 생성 | 입력 누락, 빈 값 확인 절차 없음 | 빈 값을 거부하는 확인을 넣어 재생성, Pod 재시작 | 해결 |
| STEP 8 | 로그인 대신 '첫 관리자 생성' 화면, `/run/secrets/additional` 없음 | values `admin.createSecret: false`. Chart 5.9.68은 `createSecret: true`일 때만 `existingSecret`을 마운트 | `createSecret: true`(revision 3). rollback 기준을 revision 3으로 변경 | 해결 |
| STEP 8-3 | `helm upgrade` 템플릿 오류 `range can't iterate over -lockable-resources…` | sed 치환에서 `-` 뒤 공백 누락 → 목록이 문자열이 됨 | 공백 복구 → revision 2, `PLUGINS_UNCHANGED` | 해결 |
| STEP 9 | 첫 smoke Agent가 Running 전에 삭제되고 다시 생성 | jnlp 이미지 첫 Pull이 Agent 연결 대기 100초를 넘음(02:32:10 생성 → 02:33:51 종료) | 다시 만든 Pod로 SUCCESS | 관찰 |
| STEP 9-3 | `10-persistence.txt`가 rollout 대기 줄에서 끝남. smoke 콘솔 저장 파일 없음 | 기록 중단 | 재생성 시각 02:53:40Z(`11`의 Pod 기록), 같은 PVC(P2 시점 Age 21h)로 간접 확인 | 증거 보완 필요 |
| STEP 12-3 | digest 조회 Pod 시간 초과 | 태그 `v` 누락(`1.24.1`), quay `stable`에 v1.24 없음 | skopeo v1.22.3 선택 | 해결 |
| STEP 12~15 | 붙여 넣은 명령에서 `$`·`\` 앞 공백이 사라져 반복 실패(`--contextota-a`, `echo\$r`, `-$LR`, 시각 열 붙음) | 실행 문서의 코드 블록을 복사할 때 공백 손실 | 블록을 대화로 다시 받아 실행, 붙여 넣은 뒤 `$` 앞 공백 확인 | 운영 주의 |
| STEP 14 | build #1 FAILURE `sleep: invalid number ''` | Jenkinsfile 파라미터는 첫 빌드가 끝나야 Job에 등록됨 → 첫 Build Now에서 값이 빔 | 등록용 실행으로 처리(`14-build1-failed-*`). `day6-ci-2` #1도 등록용 | 해결 (Jenkinsfile 기본값 보강은 후보) |
| STEP 14 | run01 trivy `memory.peak` = limit 1Gi | Trivy DB 첫 다운로드 | 검사 성공, run02 35 MiB. `memory.events` 미수집 | 조정 후보 |
| STEP 14 | jnlp throttle 262회·49초(run01) | CPU limit 500m | 관측만 | 조정 후보 |
| STEP 14·16 | 모든 Agent Pod 종료 30초, 종료 중 Pod와 최대 27초 겹침 | Agent 컨테이너 PID 1 `cat`이 SIGTERM 무시 → grace 30초 후 SIGKILL | Running 기준 최대 1개는 유지 | 후보 |
| STEP 16 | s1·s2를 연달아 실행해 중간 태그 기록 없음. s1 전 태그는 `14-run02/registry-check`에서 옮김. s3~s5 태그 파일 없음 | 작업 순서·기록 누락 | lock으로 순차 실행 확인. 태그는 s1 전 = s2 후, DAY7 STEP 1 tags/list로 확인 | 기록 |

## 9. 미측정·미완료

| 항목 | 상태 | 대신 쓴 근거 |
| --- | --- | --- |
| STEP 1 B context 확인 출력 | 증거 오류 | 측정 파일 `[K8s] ota-b`, STEP 15 |
| STEP 3-1 커널 146 원인 | 미판정 | — |
| STEP 9-3 Controller 재생성 후 상태·Job 유지 | 기록 끊김 | `11`의 Pod 시작 시각, PVC 동일 |
| STEP 9 smoke 콘솔(`10-smoke-*`) | 저장 안 함 | `10-agent-pods-watch`, `10-agent-max-running` |
| Jenkins 빌드 Duration | 미기록 | Agent Pod 수명, `build-info.txt` 단계 시각 |
| 회차별 Registry 저장 증가 | 미측정 | 누적 Local PV 18M → 39M |
| `memory.events`·`memory.stat`(Agent 컨테이너) | 미수집 | `memory.peak`만 |
| 빌드 반복 | run01·run02 각 1회 | — |
| s3~s5 태그 전후 파일 | 없음 | DAY7 STEP 1 tags/list |
| `versions.md` 표의 lockable-resources·Controller·sidecar digest·도구 행 | 미기입 | `09-helm-install`, `09-plugins-installed`, 같은 파일의 STEP 12-3 절 |
| jnlp 이미지 digest | 미기록 | 태그만 |
| R1 백업 소요 시간 | 미기록 | — |
| Tailscale 설치·설정 | 증거 파일 없음 | 작업 기록 |
| 빌드 + Production 부하 동시 시험(D05) | 범위 밖 | — |

## 10. 결정 사항

| 결정 | 내용 | 근거 |
| --- | --- | --- |
| Jenkins 고정 | Chart 5.9.68 / 2.580.1-jdk25, Chart tgz를 저장소에 커밋, `initializeOnce`, 기본 플러그인 4개 + lockable-resources 버전 고정, 설치 후 전체 목록 기록 | 2·3장 |
| 관리자 Secret | 클러스터 Secret `jenkins-admin`을 `createSecret: true` + `existingSecret`으로 마운트. 값은 Git·증거에 넣지 않음 | 8장 |
| 접근 | Service ClusterIP + port-forward(127.0.0.1) + SSH 터널. 외부 노출 없음. 노트북 경로는 Tailscale | 4장 |
| Agent 배치·권한 | `ci` Namespace, worker-a1, cap 1, idleMinutes 0, podRetention Never, GC 300초. Agent SA는 K8s 권한 없음, Controller는 `ci`에만 Pod 생성 | `09-rbac` |
| 배타 제어 | stage `lock(ota-exec-slot)`을 Agent 할당 전에 잡고 cap 1을 함께 둔다 | 6장 s5 |
| 이미지 경로 | rootless BuildKit → OCI tar → Trivy(수정판 있는 CRITICAL 차단, exit 1) → skopeo `--preserve-digests`. BuildKit은 Registry에 접근하지 않음 | 5·6장 |
| 이미지 식별 | 태그 `<커밋 12자>-<Job>-<번호>`, 실행은 digest 참조, built = pushed 강제 | 5장 |
| 도구 이미지 | 모두 digest 고정, Trivy 0.69.4~0.69.6 제외 | 3장 |
| SCM | 공개 GitHub 저장소 HTTPS, 자격 증명 없음. 비공개로 바꾸면 읽기 전용 토큰을 Jenkins Credentials에 둔다 | 4장 |
| 측정 조건 | VM 5대·Host 자동 업데이트 중지, `measure.sh` v3(수집 실패 시 exit 1), 시점마다 a·b 2회, 관측 변동폭보다 작은 차이는 '구분 불가' | 7장 |
| 복구 지점 | R1 콜드 백업, 보관 최대 2개(R0, R1) | `06-R1-backup` |

## 11. 다음 단계 후보

- Agent 조정: jnlp CPU limit 상향 검토, trivy limit과 `memory.events` 기록, 종료 대기 30초 단축(신호 처리 또는 `terminationGracePeriodSeconds`)
- Jenkinsfile 파라미터 기본값 보강(첫 빌드 실패 방지)
- Job 정의를 Git으로 옮기기(JCasC 또는 Job DSL). 지금 Job은 Jenkins Home에만 있다
- BuildKit 캐시 또는 베이스 이미지 미러(매 빌드 베이스 이미지 다시 받기 11초, Docker Hub 의존)
- 같은 빌드 3회 이상 반복해 피크를 범위로 기록, 빌드 + Production 부하 동시 시험(D05)
- 증거 보완: `01-contexts` B 블록, `10-persistence`, 커널 146 원인, `versions.md`
- Host 재부팅과 자동 업데이트 복구 시점 계획
- (DAY7에서 진행) Argo CD 설치, run01·run02 이미지를 G·C로 Staging → Production 승격

## 12. 증거 파일

| 범위 | 파일 |
| --- | --- |
| 준비·상태 | `00-tools`, `01-contexts`, `02-day5-state`, `03-e2e-cleanup`, `04-kernel-146-origin`(실패 기록) |
| 자동 업데이트 | `05a`~`05f`, `c--auto-upgrade-all.log`(VM 실제 변경 기록), `c-auto-upgrade-all.log`, `c--auto-upgrade-rerun.log`, `d-auto-upgrade-rerun.log` |
| R1·재기동 | `06-R1-backup`, `06-restart` |
| Chart·렌더링 | `07-chart-sha256`, `07-chart-metadata`, `07-chart-default-values`, `08-helm-lint`, `08-dry-run`, `08-render-review`, `08-jenkins-rendered` |
| 설치 | `09-helm-install`, `09-plugins-installed`, `09-rbac`, `09-crictl-stats-P1-install` |
| 관문 A | `10-agent-pods-watch`, `10-agent-max-running`, `10-persistence`, `11-helm-upgrade-rollback`, `12-crictl-stats-P1-gateA` |
| CI 준비 | `13-image-digests`, `13-buildkit-check-rootless` |
| CI 실행 | `14-build1-failed-pods-watch`, `14-run01/`, `14-run02/`, `14-run01-pods-watch`, `14-run02-pods-watch` |
| Cluster B | `15-cluster-b`, `15-cluster-b-pods.yaml` |
| 시나리오 | `16-pods-watch`, `16-agent-max-running`, `16-s1-tags-before`, `16-s2-tags-after`, `16-s1/`~`16-s4/`, `16-s5-ci/`, `16-s5-ci2/` |
| P2 | `17-worker-a1-P2` |
| 측정 | `measure/20261013-081137-day6-P0a`, `-081751-day6-P0b`, `20261014-021222-day6-P1-install-a`, `-022013-day6-P1-install-b`, `-032844-day6-P1-gateA-a`, `-034157-day6-P1-gateA-b`, `-061715-day6-P2-a`, `-062400-day6-P2-b`, 빌드 구간 `-050222-day6-build-build1-failed-*`, `-052738-day6-build-run01-*`, `-053738-day6-build-run02-*` |