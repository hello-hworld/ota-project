# DAY8 Result — 업그레이드 이후 관측 기반 (B Storage · A/B Prometheus · A Grafana · CI 1회)

- 진행: 2026-10-15 12:00 ~ 13:53 (KST, 보고서 작성 제외). 본문 시각은 증거 파일과 같은 UTC (03:00Z ~ 04:53Z)
- 실행 문서: `DAY8_실행.md` (작업계획 `DAY8_3시간_작업계획.md`를 검토·보완한 버전)
- 기준 커밋: 업그레이드 보고서 `8d0a14c` → STEP0 `464a9bf`(실행 비트 `69015d3`) → 마지막 증거 커밋 `9e60ed5`
- 증거 경로: `docs/evidence/day8/`, `docs/evidence/measure/*day8*`

## 1. 요약

Cluster B에 local-path 저장소를 놓고 Pod 재생성 뒤 파일이 남는 것을 확인했다. 그 위에 클러스터마다 Prometheus를 하나씩(A: worker-a1, B: worker-b2) 설치하고, A에 Grafana를 설치해 두 Prometheus를 별도 Data Source로 조회하게 했다. 설치 뒤 기존 CI를 1회 돌려 기존 경로가 그대로인지 확인했다.

| # | 완료 기준 (계획 6장) | 결과 | 근거 |
| --- | --- | --- | --- |
| 1 | B 테스트 PVC가 Pod 재생성 후 파일 보존 | ✅ Pod2가 PV NodeAffinity로 worker-b2에 배치돼 같은 값을 읽음. 정리 후 PV·Node 디렉터리 삭제 확인 | `12`, `13` |
| 2 | A/B Prometheus가 필수 Node·Pod·컨테이너 지표 수집 | ✅ `-r2` 3개 PASS. 1차 FAIL은 판정 스크립트의 기대값 오류(KSM Target 2개, 8장) | `40`~`42` |
| 3 | A Grafana에서 A/B 두 Data Source 값 조회 | ✅ Grafana 서버가 두 Data Source를 조회(health OK, 쿼리 3종 200), 대시보드 프로비저닝 확인. 화면 확인 기록은 없음 | `43` |
| 4 | 설치 후 기존 CI 1회 성공, Agent 0 | ✅ `day6-ci` #10 SUCCESS, built = pushed, 종료 후 agent=0 | `54-ci-run/`, `55` |
| 5 | Production 2, Staging 0, 기존 플랫폼 정상 | ✅ demo-check PASS 2회, CI 구간 요청 114건 실패 0, Argo CD 두 앱 Synced·Healthy, Eviction·OOM 없음 | `35`, `36`, `53`, `56`, `59` |
| 6 | P0/P1/P2·연속 수집·versions·values·보고서 | ✅ 측정 6회 수집 실패 0, 연속 수집 2구간, 이 문서 | measure, `50`, `58`, `helm/monitoring/` |

6항목을 모두 증거로 확인했으므로 **DAY8 3시간 목표 완료**로 기록한다. 다만 STEP 3의 `helm lint`는 붙여넣기 오류로 실행되지 않았다(렌더링·서버 dry-run·실제 설치는 정상). 이것과 대시보드 화면 확인 기록은 9장 남은 일 1·2번이다.

- 관측 구성의 상시 비용(P0 → P1, D11 지표): K8s memory requests A +656Mi(worker-a1 +624Mi, cp-a +32Mi), B +560Mi(worker-b2 +496Mi, cp-b·worker-b1 각 +32Mi). 실제 컨테이너 메모리는 A 319MB(Grafana 208MB가 2/3), B 116MB다. Guest MemAvailable은 worker-a1 −447 MiB, worker-b2 −152 MiB, cp-a −69 MiB, 나머지는 표본 간 차 안이다.
- Host 쪽: P0 → P1에 QEMU RSS 합이 +3,580 MiB 늘었다(worker-a1 3,294 → 6,025 MiB). 이미지 Pull·압축 해제로 Guest 페이지 캐시가 찬 것이다. 같은 시기 KSM 병합이 늘어 Host MemAvailable은 최저 18,744 MiB였고, swap-out은 없었다(7장).
- 새로 알게 된 것: kube-state-metrics는 Target이 2개(:8080 객체 지표, :8081 자체 지표)다. Grafana는 실사용(약 199 MiB)이 requests(128Mi)보다 크다. Prometheus 서버 ClusterRole에 클러스터 전체 ConfigMap 조회가 Chart 템플릿에 고정돼 있다(8장).
- 실행 중 사고: 첫 STEP1이 DAY7 증거 2개를 덮어썼고(이 보고서 커밋에서 복구), 웹 업로드한 스크립트에 실행 비트가 없어 STEP1·2를 다시 했다. 붙여넣기에서 `$` 앞 공백이 사라져 lint와 이미지 미리 받기가 실행되지 않았다.

결과는 '두 클러스터 각각의 기본 관측(Node·Pod·컨테이너 지표 수집)과 A에서의 교차 조회, B 영속 저장소 확인'이다. 알림(Alertmanager), Control Plane 지표, Host 관측, 보존 상한(48h·3GiB)의 실제 동작은 범위 밖이거나 아직 확인하지 않았다.

## 2. 버전과 구성

| 구성요소 | 버전 | 실제 이미지 (imageID) · 확인값 | 근거 |
| --- | --- | --- | --- |
| Prometheus Chart | prometheus 29.37.0 (app v3.15.0) | 파일 sha256 = index digest `df07dce9…e4fbe5` | `20-chart-sha256` |
| └ 하위 Chart | kube-state-metrics 8.6.0 (2.20.0), prometheus-node-exporter 4.60.0 (1.12.1) | alertmanager 2.1.1·pushgateway 3.9.1은 끔 | `20-subcharts` |
| Grafana Chart | grafana 13.6.0 (app 13.2.4, grafana-community 저장소) | 파일 sha256 = index digest `228fbe6e…51a7d6` | `20-chart-sha256` |
| Prometheus | quay.io/prometheus/prometheus:v3.15.0 | `sha256:efd719c9…753e` (A·B 같음) | `31`, `32` |
| Config reloader | quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1 | `sha256:06b52bd4…d26b` | `31`, `32` |
| kube-state-metrics | registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0 | `sha256:42cfe372…fc5b` | `31`, `32` |
| node-exporter | quay.io/prometheus/node-exporter:v1.12.1 | `sha256:1b4e4438…1be0` | `31`, `32` |
| Grafana | docker.io/grafana/grafana:13.2.4-distroless | `sha256:ae3d3add…7e35` | `34-grafana-state` |
| local-path-provisioner (B) | docker.io/rancher/local-path-provisioner:v0.0.37 | `sha256:e757967a…a86f` (A와 같은 버전·같은 원본 manifest) | `11` |
| local-path helper (B) | docker.io/library/busybox (태그 없음, 원본 그대로) | `sha256:fd7dc986…7e6e` | `12` |
| Helm / kubectl (ota-host) | v3.22.0 / v1.36.5 | — | `01` |

배치와 저장소:

| Release·구성 | 클러스터·Node | requests / limits | 저장소 (PVC → PV Node·경로) |
| --- | --- | --- | --- |
| prometheus-server + reloader | A worker-a1 (`workload=platform`) | 110m·400Mi / 600m·832Mi | 5Gi `pvc-763fc90c…` → worker-a1 `/opt/local-path-provisioner/pvc-763fc90c-2aca-48e7-84f9-1a7f7b1f199b_monitoring_prometheus-server`, Delete |
| kube-state-metrics | A worker-a1 | 50m·64Mi / 200m·128Mi | — |
| node-exporter (DaemonSet, hostNetwork 9100) | A cp-a·worker-a1 | Node당 20m·32Mi / 100m·96Mi | — |
| grafana | A worker-a1 | 50m·128Mi / 300m·384Mi | 1Gi `pvc-16ea6266…` → worker-a1 `/opt/local-path-provisioner/pvc-16ea6266-0ddb-4ec7-82d1-718965540f5d_monitoring_grafana`, Delete |
| prometheus-server + reloader | B worker-b2 (hostname 지정) | 110m·400Mi / 600m·832Mi | 5Gi `pvc-6d596ab1…` → worker-b2 `/opt/local-path-provisioner/pvc-6d596ab1-d3ac-4959-8a7b-35cb0711da72_monitoring_prometheus-server`, Delete |
| kube-state-metrics | B worker-b2 | 50m·64Mi / 200m·128Mi | — |
| node-exporter | B cp-b·worker-b1·worker-b2 | Node당 20m·32Mi / 100m·96Mi | — |
| local-path-provisioner | B worker-b2 (스케줄러 배치) | 없음 | StorageClass `local-path`, Delete, WaitForFirstConsumer |

접속 경로:

| 경로 | 방식 | 확인 |
| --- | --- | --- |
| Grafana → A Prometheus | `http://prometheus-server.monitoring.svc.cluster.local` (클러스터 안 Service), `access: proxy` | `43` health OK |
| Grafana(A Pod) → B Prometheus | `http://192.168.56.32:30909` NodePort, `externalTrafficPolicy: Local`, `access: proxy`. A Pod → Calico natOutgoing → ota-net → worker-b2 | `43` health OK, 쿼리 3종 200 |
| NodePort 응답 Node | `.30` → 000, `.31` → 000, `.32` → 200. worker-a1 Node에서 `.32` → 200 | `33` |
| ota-host → B Prometheus | NodePort 직접 (같은 판정) | `42` PASS |
| 사람 → Grafana | ota-host `127.0.0.1:13000` port-forward + 노트북 SSH 터널 | `43` (url=127.0.0.1:13000) |

결정 1(kubelet 수집 TLS)은 (a) Chart 기본값 유지로 진행했다. kubelet 2개 job만 `insecure_skip_verify: true`, Prometheus ClusterRole의 kubelet 관련 권한은 `nodes`·`nodes/metrics`이고 `nodes/proxy`·`secrets`는 없다(`22-scrape-review`). D13.

## 3. B Storage 시험

| 항목 | 결과 | 근거 |
| --- | --- | --- |
| 시작 상태 | B에 StorageClass·`local-path-storage` Namespace 없음, worker-b1·b2에 `/opt/local-path-provisioner` 없음 | `10` 1차 기록(커밋 `acae344`) |
| manifest | v0.0.37 원본 sha256 OK, A 설치본 ConfigMap 4개 키(config.json·helperPod.yaml·setup·teardown)와 SAME, 이미지 같음 | `10` |
| 설치 | 03:13:58Z apply → Provisioner Running(worker-b2) 약 16초. 03:30:37Z 재적용은 모두 unchanged | `11` |
| PVC | 소비 Pod 전 Pending(WaitForFirstConsumer 정상) | `12` |
| Pod1 (worker-b2 지정) | 12초 뒤 Running, 식별 문자열 기록. PV nodeAffinity `worker-b2`, 실제 디렉터리 `drwxrwxrwx` | `12` |
| Pod1 삭제 후 | PVC·PV 모두 Bound 유지 | `12` |
| Pod2 (Node 지정 없음) | PV NodeAffinity로 worker-b2에 배치, 3초 뒤 Running, 같은 문자열 읽음 | `12` PASS (전체 24초) |
| 정리 | Pod·PVC 삭제 → PV 자동 삭제(Delete) → Node 디렉터리 없음 → Namespace 삭제 | `13` PASS (13초) |
| 이후 사용 | B Prometheus PVC 5Gi가 같은 StorageClass로 worker-b2에 Bound | `32` |

서버 dry-run의 Namespace 관련 NotFound 5줄(1차)은 문서 판정 기준의 오류다(8장). 설치 후 다시 한 dry-run은 9개 객체 모두 unchanged다(`11-local-path-b-dryrun-recheck`).

## 4. 수집 결과

| job | A (Target·up) | B (Target·up) | 비고 |
| --- | --- | --- | --- |
| `prometheus` | 1 / 1 | 1 / 1 | localhost:9090 |
| `kubernetes-nodes` (kubelet) | 2 / 2 (cp-a, worker-a1) | 3 / 3 | 10250, TLS 검증 생략(D13) |
| `kubernetes-nodes-cadvisor` | 2 / 2 | 3 / 3 | 같음 |
| `kubernetes-service-endpoints` | 6 / 6: node-exporter 2, KSM 2(:8080·:8081), kube-dns 2 | 7 / 7: node-exporter 3, KSM 2, kube-dns 2 | kube-dns(CoreDNS 9153)는 예상 밖 Service로 기록 |
| 합계 | 11 / 11 | 14 / 14 | `40-r2`, `41-r2`, `42-r2` |

| 항목 | A | B | 근거 |
| --- | --- | --- | --- |
| Node 식별 (node-exporter·kubelet·cAdvisor) | cp-a, worker-a1 | cp-b, worker-b1, worker-b2 | `40`·`41` |
| 최신 샘플 나이 (node-exporter·cAdvisor·KSM) | 0초 | 0초 | 같음 |
| KSM `kube_node_info` Node / `kube_pod_info` Pod / Node 조건 시계열 | 2 / 23 / 6 | 3 / 21 / 9 | 같음 |
| scrape 시간 최대 | service-endpoints 0.405s, kubelet 0.046s | service-endpoints 0.279s, kubelet 0.030s | 같음 |
| TSDB head 시계열 · 샘플/scrape 합 | 14,356 · 14,278 | 15,879 · 15,803 | 04:32Z |
| WAL · 블록 | 3.78 MB · 0 | 3.26 MB · 0 | 첫 블록 전 |
| Prometheus 프로세스 RSS | 126.5 MiB | 127.1 MiB | |
| 보존 설정 | time 2d, size 3GiB | 같음 | `--storage.tsdb.retention.size=3GB` (Prometheus는 2의 거듭제곱 단위) |
| CI 뒤 (04:49:54Z) | head 14,962, WAL 6.77 MB, RSS 128.8 MiB(30분 최대 131.8 MiB). 30분 동안 4개 job up 최솟값 1 | — | `57` |

- 설치 시간(helm 시작 → 마지막 Pod Ready): A 114초, B 108초. 서버 컨테이너 생성 대기 77·73초가 대부분이다(이미지 미리 받기 실패, 8장). node-exporter·KSM은 18~26초(`30-install-watch-a/b`).
- Control Plane 별도 지표(API 서버·etcd·scheduler·controller-manager)는 수집하지 않는다(`kubernetes-api-servers` job 끔).
- 두 클러스터 모두 Pod 안 `promtool check config`가 SUCCESS다(SA 토큰 파일까지 확인, `33`).
- 첫 확인(04:29:42Z, A 설치 15분 뒤)에서 이미 모든 Target이 up이었다. 첫 up 시각 자체는 기록하지 않았다.

## 5. Grafana

| 항목 | 결과 | 근거 |
| --- | --- | --- |
| 서버 | http 200, database ok, version 13.2.4 | `43` |
| Data Source | `prometheus-a`(기본, proxy, readOnly) → 클러스터 Service. `prometheus-b`(proxy, readOnly) → `http://192.168.56.32:30909` | `43` |
| 서버 측 조회 | 두 Data Source 모두 health OK. node-exporter·cAdvisor·KSM 쿼리가 각각 200이고 Node 목록이 클러스터와 일치 | `43` |
| 대시보드 | `OTA Infra Overview`, 폴더 OTA, provisioned=True, 패널 18개. 화면 확인 기록·캡처(`44`)는 없음 | `43` |
| 관리자 계정 | Secret `grafana-admin`(키 2개). 증거에는 키 이름만 있다 | `34-grafana-state` |
| 저장·배포 방식 | PVC 1Gi(worker-a1), Recreate, init container 없음, SA 토큰 마운트 끔, `GOMEMLIMIT` 345MiB | `34`, `22-grafana-rendered` |
| 시작 | helm 시작 → Ready 232초(이미지 Pull 약 196초 포함). 프로비저닝 완료 04:26:35Z. 시작 중 SQLite `database is locked` info 로그가 재시도 후 사라짐 | `30-install-watch-a`, `34` |

## 6. CI 1회

| 항목 | 값 | 근거 |
| --- | --- | --- |
| 빌드 | `day6-ci` #10 SUCCESS, 133.6초(04:41:49 → 04:44:03Z), commit `d3db903`(DAY8 STEP5) | `54-ci-run/build.json`, `build-info.txt` |
| tag · digest | `d3db903c51de-day6-ci-10`, built = pushed = manifest `sha256:2b00cfce…3b45` | `build-info.txt`, `pushed-digest.txt` |
| test | 3개 OK, exit 0 (04:42:32Z, 3초) | `test.log` |
| build | 04:42:35 → 04:42:46Z (11초), BuildKit v0.34.0 | `build-info.txt` |
| scan | DB 준비 69초(04:42:47 → 04:43:56Z, DB 갱신 다운로드), 검사 1초, exit 0. CRITICAL 0건(alpine 3.24.2·Python) | `trivy-version.txt`, `trivy-report.json` |
| push | 1초 (04:43:57 → 04:43:58Z) | `build-info.txt` |
| Agent | worker-a1, Pending → Running 1초, Running 117초, Terminating 30초 → Error(SIGKILL) | `52` |
| Agent 컨테이너 memory.peak | jnlp 258.9 MiB, buildkit 256.3 MiB, **trivy 1,024.0 MiB(limit 1Gi + 4 KiB)**, skopeo 63.2 MiB, python 41.4 MiB | `cgroup-*.txt` |
| jnlp CPU throttle | 263회 · 45.9초 (limit 500m) | `cgroup-jnlp.txt` |
| 종료 후 | agent=0 staging=0 | `55` |
| Production | 04:40:53 ~ 04:50:25Z 5초 간격 114건 모두 200(버전 C). CI 뒤 demo-check PASS | `53-ci-http`, `56` |
| 수집 | 30분 창(04:19:54 ~ 04:49:54Z)에서 A 4개 job up 최솟값 1 | `57` |

업그레이드 후 CI #9(00:07Z)와 비교하면 Agent Running이 48초 → 117초로 늘었다. 차이 69초는 Trivy DB 갱신 다운로드(#9는 DB 준비 1초, trivy peak 138.7 MiB)이고 나머지 단계 시간은 비슷하다. 결과는 '관측 도구 추가 후 기존 CI 경로가 1회 정상'이며, 반복 부하·성능으로 넓혀 해석하지 않는다. 새 이미지는 승격하지 않았다.

## 7. 자원 측정

### 7-1. 측정 조건

- `measure.sh`, KSM run=1. 시각은 측정 시작, 괄호는 VM 기동 완료(00:27:14Z) 후 경과.
- P0는 3번 측정했다: #1 03:02:45Z(+9,331초), #2 03:08:35Z(+9,681초), #3 03:26:32Z(+10,758초). 비교 기준은 실행 비트 수정 뒤 다시 한 **#3**이며, 03:13:58Z에 적용한 B local-path Provisioner(컨테이너 약 11MB)가 포함돼 있다.
- P1-idle 04:36:38Z(+14,964초, Targets 확인 뒤 유휴), P2-final 04:51:33Z(+15,859초, CI 7분 뒤).
- **Host MemAvailable·RAM Used의 P0 → P1 차이는 판단에 쓰지 않는다.** KSM 절약량이 P0 #1 643 → #3 1,888 → 설치 수집 시작(04:10:45Z) 4,941 → P1 5,477 MiB로 콜드 재기동 뒤 계속 늘었다. Host 쪽 증가는 QEMU RSS(KSM 병합과 무관)와 같은 연속 수집 안의 처음·끝(7-3)으로 본다(D11).
- 표본 간 차(P0 #1~#3의 Guest MemAvailable 최대 − 최소): cp-a 14.8, cp-b 13.1, worker-a1 45.7, worker-b1 20.4, worker-b2 36.2 MiB. 약 50 MiB보다 작은 차이는 구분하지 않는다.

### 7-2. 비교표

| 계층 | 항목 | U-P1b (참고) | P0 #3 | P1-idle | P2-final | P1 − P0 | P2 − P1 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 조건 | 측정 시작 | 01:30:40Z | 03:26:32Z | 04:36:38Z | 04:51:33Z | | |
| 조건 | KSM 절약량 (MiB) | −114.8 | 1,888.2 | 5,477.4 | 5,462.2 | +3,589.2 | −15.2 |
| Host | MemAvailable (MiB) | 17,743.9 | 19,518.0 | 19,259.6 | 18,847.6 | −258.4 | −412.0 |
| Host | RAM Used (MiB) | 14,066.2 | 12,292.1 | 12,550.5 | 12,962.5 | +258.4 | +412.0 |
| Host | KSM 보정 사용량 (MiB) | 13,951.4 | 14,180.3 | 18,027.9 | 18,424.7 | +3,847.6 | +396.8 |
| Host | Swap Used (MiB) · si/so 평균 | 80.8 · 0.2/0.0 | 65.5 · 0.0/0.0 | 65.5 · 0.0/0.0 | 65.5 · 0.0/0.0 | 0 | 0 |
| Host | CPU busy · gu (%) | 8.9 · 6.3 | 9.5 · 6.9 | 10.5 · 7.8 | 12.0 · 8.9 | +1.0 · +0.9 | +1.5 · +1.1 |
| VM | Total QEMU RSS (MiB) | 12,908.7 | 13,033.0 | 16,613.2 | 16,799.2 | +3,580.2 | +186.0 |
| VM | Total QEMU PSS (MiB) | 12,820.7 | 10,964.2 | 11,163.7 | 11,559.0 | +199.5 | +395.3 |
| VM | cp-a RSS (MiB) | 2,101.4 | 2,101.4 | 2,101.6 | 2,102.1 | +0.2 | +0.5 |
| VM | cp-b RSS (MiB) | 2,969.6 | 2,994.6 | 3,096.9 | 3,101.0 | +102.3 | +4.1 |
| VM | worker-a1 RSS (MiB) | 3,247.3 | 3,294.0 | 6,025.3 | 6,184.1 | +2,731.3 | +158.8 |
| VM | worker-b1 RSS (MiB) | 2,436.3 | 2,439.0 | 2,507.5 | 2,513.5 | +68.5 | +6.0 |
| VM | worker-b2 RSS (MiB) | 2,150.8 | 2,201.9 | 2,880.4 | 2,896.3 | +678.5 | +15.9 |
| Guest | cp-a MemAvailable (MiB) | 776.3 | 734.2 | 664.9 | 691.3 | −69.3 | +26.4 |
| Guest | cp-b MemAvailable (MiB) | 1,860.2 | 1,832.5 | 1,801.0 | 1,814.6 | −31.5 | +13.6 |
| Guest | worker-a1 MemAvailable (MiB) | 4,641.7 | 4,575.5 | 4,128.8 | 4,018.0 | −446.7 | −110.8 |
| Guest | worker-b1 MemAvailable (MiB) | 6,258.3 | 6,277.3 | 6,244.7 | 6,237.7 | −32.6 | −7.0 |
| Guest | worker-b2 MemAvailable (MiB) | 6,338.7 | 6,304.8 | 6,153.3 | 6,173.0 | −151.5 | +19.7 |
| Guest | worker-a1 used / buff·cache (`free -m`) | — | 1,351 / 1,622 | 1,796 / 4,152 | 1,907 / 3,810 | +445 / +2,530 | +111 / −342 |
| Guest | worker-b2 used / buff·cache (`free -m`) | — | 628 / 1,183 | 780 / 1,763 | 760 / 1,767 | +152 / +580 | −20 / +4 |
| Guest | Root Used cp-a · cp-b · a1 · b1 · b2 | 14G · 14G · 15G · 8.8G · 8.8G | 14G(50%) · 14G(48%) · 15G(26%) · 8.8G(19%) · 8.9G(12%) | 15G(51%) · 14G(48%) · 17G(30%) · 8.9G(19%) · 9.4G(13%) | P1과 같음 | a1 +2G, b2 +0.5G | 0 |
| K8s | cp-a memory requests / limits | 240Mi / 340Mi | 240Mi / 340Mi | 272Mi / 436Mi | 같음 | +32 / +96 | 0 |
| K8s | worker-a1 memory requests / limits | 1,696Mi / 4,736Mi | 1,696Mi (29%) / 4,736Mi (81%) | 2,320Mi (39%) / 6,176Mi (106%) | 같음 | +624 / +1,440 | 0 |
| K8s | worker-a1 CPU requests / limits | 910m / 3,350m | 910m / 3,350m (83%) | 1,140m / 4,550m (113%) | 같음 | +230 / +1,200 | 0 |
| K8s | cp-b memory requests / limits | 170Mi / 170Mi | 170Mi / 170Mi | 202Mi / 266Mi | 같음 | +32 / +96 | 0 |
| K8s | worker-b1 memory requests / limits | 134Mi / 298Mi | 134Mi / 298Mi | 166Mi / 394Mi | 같음 | +32 / +96 | 0 |
| K8s | worker-b2 memory requests / limits | 64Mi / 128Mi | 64Mi / 128Mi | 560Mi / 1,184Mi | 같음 | +496 / +1,056 | 0 |
| 측정 | 수집 실패 | 0 | 0 | 0 | 0 | | |

worker-a1 allocatable은 5,825Mi · 4 CPU다. CI Agent 1개(requests 1,100m·896Mi, limits 4,500m·3,584Mi)가 붙으면 worker-a1은 memory requests 3,216Mi(55%) / limits 9,760Mi(168%), CPU limits 9,050m(226%)가 된다.

### 7-3. 연속 수집 구간

| 지표 | 설치 구간 04:10:45 ~ 04:35:45Z | CI 구간 04:39:27 ~ 04:50:43Z |
| --- | --- | --- |
| Host MemAvailable | 최고 22,390.1 / 최저 19,090.5 MiB (04:27:46Z) | 최고 19,246.5 / 최저 18,744.2 MiB (04:49:56Z) |
| KSM 절약량 처음 → 끝 | 4,941 → 5,477 MiB | 5,475 → 5,462 MiB |
| Host MemAvailable − KSM 절약량, 처음 → 끝 | 17,415 → 13,784 MiB (−3,631) | 13,771 → 13,367 MiB (−404), 최저 13,282 (04:49:56Z) |
| QEMU RSS 합 처음 → 끝 | 13,097.5 → 16,612.4 MiB (+3,514.9) | 16,628.3 → 16,797.0 MiB (+168.7) |
| VM RSS 최고 | cp-a 2,102.5 · cp-b 3,097.4 · worker-a1 6,024.1 · worker-b1 2,507.8 · worker-b2 2,881.3 | cp-a 2,102.1 · cp-b 3,101.0 · worker-a1 6,184.1 · worker-b1 2,513.5 · worker-b2 2,896.5 |
| Host CPU busy 최고 · gu 최고 | 32% · 22% (04:16:41Z, B Prometheus 설치 시작) | 27% · 22% (04:41:58Z, CI 시작 직후) |
| Swap si·so 합계 | 16 / 0 | 8 / 0. 끝에서 Swap Used 65.5 MiB (`58`) |
| Guest MemAvailable 최저 | cp-a 646.3 (04:15:04Z) · cp-b 1,795.5 · worker-a1 4,113.1 (04:28:56Z) · worker-b1 6,248.4 · worker-b2 6,161.8 | cp-a 645.3 (04:49:07Z) · cp-b 1,792.5 · worker-a1 3,830.8 (04:43:59Z) · worker-b1 6,238.3 · worker-b2 6,163.7 |
| Guest PSI mem some avg10 최고 | 0.0 (cp-a·cp-b·worker-b1·worker-b2. worker-a1은 수집 항목 없음) | 0.0 (같음) |
| 표본 수 | Host vmstat 1,494 · Guest 245~249 | 664 · 111 |

### 7-4. 컨테이너 (`crictl stats` MEM, MB)

| 컨테이너 | P0 (`03`) | P1 (`51`) | P2 (`59`) |
| --- | --- | --- | --- |
| A prometheus-server · reloader | — | 68.7 · 7.5 | 71.8 · 7.6 |
| A kube-state-metrics | — | 16.4 | 15.9 |
| A node-exporter cp-a · worker-a1 | — | 9.1 · 8.9 | 9.3 · 9.2 |
| A grafana | — | 208.2 | 210.0 |
| **A 관측 합계** | — | **318.8** | **323.6** |
| B prometheus-server · reloader | — | 67.8 · 7.5 | 68.0 · 7.5 |
| B kube-state-metrics | — | 15.1 | 16.3 |
| B node-exporter cp-b · worker-b1 · worker-b2 | — | 8.4 · 8.6 · 8.4 | 8.4 · 9.1 · 8.4 |
| **B 관측 합계** | — | **115.7** | **117.8** |
| B local-path-provisioner | 10.6 | 11.1 | 11.4 |
| cp-a kube-apiserver · etcd | 608.1 · 69.5 | 619.7 · 71.6 | 605.1 · 71.0 |
| cp-a kube-scheduler · kube-controller-manager | 35.4 · 80.8 | 44.9 · 84.1 | 45.0 · 84.3 |
| cp-b kube-apiserver · etcd | 460.4 · 96.3 | 466.1 · 99.1 | 459.4 · 97.8 |
| jenkins (참고) | 468.1 | 487.3 | 690.8 |
| argocd application-controller (참고) | 162.3 | 158.5 | 121.7 |

`crictl`의 MEM은 working set이다. prom-check의 Prometheus 프로세스 RSS(약 127 MiB)는 매핑된 파일 페이지를 포함해 이 값(약 68MB)보다 크다. 비교는 `crictl` 값으로 한다.

### 7-5. 해석

1. **관측 구성의 상시 비용은 requests가 실사용보다 크고, Grafana만 반대다.** requests는 A 656Mi·B 560Mi, 실사용은 A 319MB(requests의 약 46%)·B 116MB(약 20%)다. Prometheus 서버 Pod는 400Mi 예산에 약 76MB(서버 69 + reloader 7.5)를 쓴다. Grafana는 약 199 MiB로 requests 128Mi의 155%(limit 384Mi의 52%)다.
2. **Guest 여유 감소는 관측 Pod가 놓인 Node에 모였다.** worker-a1 −447 MiB(used +445 MiB: 새 컨테이너 약 310MB + 컨테이너 런타임·kubelet 몫), worker-b2 −152 MiB(새 컨테이너 약 99MB). cp-a −69 MiB는 표본 간 차보다 약간 크다(node-exporter 9MB, kube-scheduler +9.5MB, kube-apiserver +11.6MB). cp-b·worker-b1 −32·−33 MiB는 구분하지 않는다.
3. **Host 증가는 페이지 캐시가 VM 메모리를 채운 것이다.** 이미지 미리 받기가 실패해(8장) 설치 중에 이미지를 받았고, worker-a1의 Guest buff/cache가 +2,530 MiB, Root가 +2G 늘었다. 그 결과 worker-a1 QEMU RSS가 3,294 → 6,025 MiB로 할당 상한(6 GiB) 가까이 갔다(worker-b2 +679 MiB). 같은 시기 KSM 절약량이 늘어 Host MemAvailable은 두 구간을 통틀어 최저 18,744 MiB였고, KSM 절약량을 빼고 보면 설치 구간에만 3,631 MiB가 줄었다. swap-out 0, Swap Used 그대로다. worker-a1은 이미 상한 근처라 같은 원인으로 더 커질 여지는 작다.
4. **CI 중 worker-a1 최저 여유는 3,831 MiB다.** DAY6 CI 때 최저 4,246 MiB, DAY7 배포 구간 3,939 MiB보다 낮다. 실사용 여유는 아직 크지만, limits 합은 CI 중 168%로 동시 피크가 겹칠 때의 위험 지표다. 계획대로 자원 예산 세션에서 다룬다.
5. **cp-a는 300 MiB 중단선과 거리가 있다.** 두 구간 최저 645 MiB, PSI 0.0. 관측 구성은 API 서버를 수집하지 않고(job 끔) watch만 더해 kube-apiserver 메모리가 P0 대비 +11.6MB(P1), −3.0MB(P2)로 거의 그대로다.
6. **CPU는 Host busy +1.0, gu +0.9 포인트(P0 → P1)다.** P0 세 표본(busy 8.9~9.5%)의 차보다 약간 크다. 30초마다 25개 Target을 수집하는 비용으로 보지만 크기가 작아 단정하지 않는다. P2의 추가 +1.5 포인트는 CI 7분 뒤 값이라 원인을 나누지 않는다.
7. **보존 상한은 아직 확인하지 않았다.** B Prometheus 데이터 디렉터리는 4.2M(04:38Z) → 6.8M(04:52Z)이고 블록이 아직 없다. 48h·3GiB 동작과 실제 디스크 사용량은 블록이 생긴 뒤 다시 잰다.

## 8. Issue · 결정

| 시점 | 증상 | 원인 | 조치 | 상태 |
| --- | --- | --- | --- | --- |
| 계획 검토 | kubelet·cAdvisor 수집이 Chart 기본값부터 TLS 검증 생략 | kubeadm kubelet 서빙 인증서가 클러스터 CA 서명이 아님. 대안(API 서버 프록시)은 `nodes/proxy`가 필요 | 결정 1 (a), D13 | 결정 |
| STEP 1 | 첫 STEP1(03:00Z)이 `docs/evidence/day7/00-timeline.txt`·`01-state-before.txt`를 덮어씀(`66f1a77`) | `EV`가 day7인 셸에서 1-1을 실행(`day8-session.env` 적용 전으로 추정) | 이 보고서 커밋과 함께 `66f1a77^` 내용으로 복구. 잘못 들어간 03:00Z 상태는 Git 이력에 남음 | 해결 |
| STEP 1 | P0를 3번 측정 | STEP1 1차·2차, 실행 비트 수정 뒤 재실행 | 비교는 #3, #1·#2는 표본 간 차로 사용 | 기록 |
| STEP 2 1차 | `storage-test.sh` Permission denied | GitHub 웹 업로드로 새 스크립트 4개에 실행 비트 없음 | `69015d3`(`git update-index --chmod=+x`), STEP1·2 재실행 | 해결 |
| STEP 2 1차 | local-path 서버 dry-run에서 Namespace NotFound 5줄 | 서버 dry-run은 Namespace를 실제로 만들지 않아 같은 파일의 namespaced 객체가 실패한다. 실행 문서의 판정 기준(오류 없음)이 잘못 | 그대로 apply(성공). 설치 후 재확인은 모두 unchanged | 해결 (문서 기준 오류) |
| STEP 3 | `22-helm-lint`: lint·template 3번 모두 경로가 깨져 실행 안 됨. `25-image-prepull`: 5 Node 모두 syntax error. `01`의 소제목도 붙어서 기록(`## nodesota-a`) | 붙여 넣은 명령에서 `$` 앞 공백이 사라짐(`in $IMGS` → `in$IMGS`, `lint $v` → `lint$v`). 복사한 화면이 `$…$`를 수식으로 처리한 것으로 추정 | 렌더링은 따로 실행돼 `22-*-rendered`(종류 15·15·7)·검토·서버 dry-run 정상. 이미지는 설치 중 Pull(Grafana 약 196초). lint는 미실행으로 남김 | **열림** (lint 재실행) |
| STEP 4 | 설치 구간 수집 1차(03:51:55Z, 11초) 파일 3개가 커밋됨 | 시작 직후 취소, 타임라인 NOTE는 '삭제 후 다시 시작'이지만 파일이 남음 | 분석에서 제외(7-3은 `041045`·`041113` 세트) | 기록 |
| STEP 5 | `40`·`41`·`42` 1차 FAIL: KSM Target 2개 (기대 1) | KSM Service가 8080(객체 지표)·8081(KSM 자체 지표) 두 포트를 노출하고 endpointslice SD는 포트마다 Target을 만든다. 수집은 정상, `prom-check.py` 기대값 오류 | `4c5d0cd`: `:8080` 기준 판정, `-r2` 3개 PASS | 해결 |
| STEP 6 | Jenkins API `curl` 401 (3회 × 2) | 원인 기록 없음 | 다시 시도해 API로 수집(`54-ci-run/build.json`) | 기록 |
| STEP 6 | trivy `memory.peak` = limit 1Gi + 4 KiB, DB 준비 69초 | Trivy DB 갱신 다운로드(DownloadedAt 04:43:52Z). DAY6 run01과 같은 형태 | scan exit 0. `memory.events` 미수집 | **열림** (DAY6부터 조정 후보) |
| STEP 6 | Agent Terminating 30초 → Error | Agent 컨테이너가 SIGTERM에 끝나지 않아 grace 30초 뒤 SIGKILL (DAY6·업그레이드 CI와 같음) | 관측만 | 기존 후보 |
| 설치 후 | worker-a1 limits 합 memory 106%, CPU 113% (CI 중 168%·226%) | 관측 Pod limits +1,440Mi·+1,200m | 실사용(최저 3,831 MiB)으로 판단, 그대로 둠 | **열림** (자원 예산) |
| 설치 후 | Grafana 실사용 약 199 MiB > requests 128Mi | values의 예산이 실사용보다 작음 | 기록 | **열림** (조정 후보) |
| 보고서 검토 | Prometheus 서버 ClusterRole에 클러스터 전체 `configmaps` get/list/watch | Chart 29.37.0 `templates/clusterrole.yaml`에 고정된 규칙(values로 뺄 수 없음). 수집 job 4개에는 필요 없음. 실행 문서의 권한 검토는 `nodes/proxy`·`secrets`만 봤다 | 기록. 줄이려면 직접 만든 ClusterRole + `server.useExistingClusterRoleName` | **열림** |
| 설치 후 | B NodePort 30909로 lifecycle API(`/-/reload`, `/-/quit`)가 인증 없이 열림 | Chart 기본 플래그 `--web.enable-lifecycle`(config reloader가 사용) | 내부망(libvirt NAT, Host·VM만 접근) 확인, 기록만 | **열림** (기록) |
| 보고서 작성 | `helm/monitoring/versions.md`의 imageID 근거 파일 이름이 틀림(`33-install-check`) | 실행 문서 작성 오류 | 실제 파일(`31`·`32`·`34`)과 digest로 고침. B local-path `versions.md`에도 digest 기록 | 해결 |

결정: D13(kubelet 지표 수집의 TLS·권한), D14(관측 구성) — `docs/decisions.md`. 열린 Issue는 `docs/issues.md`.

## 9. 남은 일

1. `helm lint` 3개 재실행·기록(`22-helm-lint-r2`). 명령은 원본 텍스트에서 복사한다(GitHub Raw·편집기·`less`). 수식 처리하는 화면에서 복사하지 않는다.
2. 대시보드 화면 확인 기록: A·B Data Source로 바꿔 가며 6묶음 확인, 필요하면 캡처 `44-dashboard-a/b.png`(비밀번호·토큰이 없는 화면).
3. Prometheus 첫 블록 이후 TSDB 블록 bytes·데이터 디렉터리 크기 측정, 48시간 뒤 보존 동작 확인.
4. Grafana requests 조정 검토(실사용 약 199 MiB, 현재 128Mi).
5. worker-a1 자원 예산: limits 합 106%(CI 중 168%) — 자원 예산·Quota/LimitRange 세션.
6. Prometheus 서버 ClusterRole의 `configmaps` 권한을 줄일지 결정.
7. kubelet 서빙 인증서를 클러스터 CA로 발급한 뒤 TLS 검증 켜기(D13 이후, 5 Node kubelet 변경).
8. 계획 6장의 보강: Host node-exporter·Grafana 연결, 선택적 Control Plane 지표.
9. CI Agent 조정(DAY6부터): trivy limit·`memory.events` 기록, 종료 대기 30초, jnlp CPU throttle.

## 10. 증거 파일

| 범위 | 파일 |
| --- | --- |
| 준비·시작 상태 | `00-timeline`, `00-day8-files.sha256`, `01-state-before`, `02-prod-before`, `03-crictl-stats-P0`, measure `20261015-030245/030835/032632-day8-P0` (비교에는 `032632`) |
| B Storage | `10-b-storage-before`, `11-local-path-b-install`, `11-local-path-b-dryrun-recheck`, `12-b-storage-test`, `13-b-storage-cleanup` |
| Chart·렌더링 | `20-chart-sha256`, `20-*-chart.yaml`, `20-*-defaults.yaml`, `20-subcharts`, `21-values-keycheck`, `22-*-rendered.yaml`, `22-render-review`, `22-scrape-review`, `22-helm-lint`(실행 안 됨), `23-dry-run`, `25-image-prepull`(실패) |
| 설치 | `30-install-watch-a/b`, `31-*`, `32-*`, `33-config-nodeport-check`, `34-*`, `35-platform-after-install`, `36-prod-after-install` |
| 수집·Grafana | `40`·`41`·`42` (1차 FAIL·`-r2` PASS), `43-grafana-check` |
| 연속 수집 | measure `20261015-041045-day8-install-*`·`041113-day8-install-*`, `50-install-sample-summary` / measure `043927-day8-ci-*`·`043939-day8-ci-*`, `58-ci-sample-summary`. `035155-day8-install-*`은 취소분(분석 제외) |
| P1·CI·P2 | measure `043638-day8-P1-idle`, `51-crictl-stats-P1`, `52-ci-pods-watch`, `53-ci-before`, `53-ci-http`, `54-ci-run/`, `55-ci-after`, `56-prod-after-ci`, `57-prom-a-after-ci`, measure `045133-day8-P2-final`, `59-crictl-stats-P2`, `59-final-state` |
| 저장소 | `helm/monitoring/`(Chart tgz 2개, values 3개, 대시보드 JSON, versions.md), `k8s/platform/local-path-b/`, `scripts/day8-session.env`·`storage-test.sh`·`chart-defaults.py`·`prom-check.py`·`grafana-check.py`·`render-review.py` |
