# DAY5 Result — Platform Storage · Private Registry (복구 포함)

- 원래 진행: 2026-10-07 ~ 10-08 (부분 완료로 중단)
- 복구·재수행: 2026-10-12 ~ 10-13
- 기준 커밋: 고장 상태 동결 `ab18ea9` → Registry End-to-End `7fdb951`
- 증거 경로: `docs/evidence/day5r/`, `docs/evidence/measure/*day5*`
- 시간 표기: 증거 파일과 같은 UTC (서버 시간)
- 작성: 10-13(DAY5 종료 시점). 저장소 반영 때 이후 처리 결과를 12장에 덧붙였다.

## 1. 요약

DAY5에서는 Cluster A의 worker-a1을 Platform Node로 지정하고, local-path-provisioner 기반
동적 Storage와 사설 Registry(`registry:2`)를 구성하였다.

원래 진행에서는 Storage와 Registry HTTP API까지는 정상이었으나, Cluster B 노드가
Registry에서 이미지를 받지 못하는 문제(`server gave HTTP response to HTTPS client`)로 중단되었다.

복구 과정에서 원인을 **containerd 2.2.1의 기본 `config_path` 값**으로 확정하고, Ansible로
5대 모두 수정하였다. 이후 Platform 계층을 걷어내고 VM을 재기동해 깨끗한 P0를 다시 측정한 뒤,
DAY5 범위를 처음부터 재수행하고 P1을 측정하였다.

Storage + Registry 추가의 상시 자원 비용은 작았다. worker-a1 게스트 내부 사용량은 약 +21 MiB,
CPU는 1% 미만이었다. Host 기준으로는 RAM Used가 +630.9 MiB 늘었는데, 대부분은 설치 과정에서
VM이 건드린 메모리가 Host에 남은 것이다.

마지막으로 `Push → Cluster B Pull → Pod 실행` 경로를 수동으로 검증하여 DAY6(Jenkins)의
선행 조건을 확보하였다.

## 2. 범위

| 항목 | 결과 |
| --- | --- |
| Cluster A/B Healthy | ✅ 5 Node Ready |
| DAY5 P0 Baseline | ✅ 재기동 후 2회 측정 (P0a·P0b) |
| worker-a1 Platform Label | ✅ `workload=platform` |
| Namespaces | ✅ `platform`, `monitoring`, `staging` |
| local-path-provisioner | ✅ v0.0.37, StorageClass `local-path` |
| PVC Dynamic Provisioning | ✅ 1Gi Bound, `storage-ok` 읽기 확인 |
| registry:2 | ✅ worker-a1, PVC 10Gi, NodePort 32000 |
| Cluster A → Registry | ✅ `/v2/` 200 |
| Cluster B → Registry | ✅ `/v2/` 200, kubelet Pull 성공 |
| DAY5 P1 Resource Measurement | ✅ |
| Registry End-to-End (DAY6 선행) | ✅ Push → Pull → Pod 실행 |
| Jenkins / Argo CD / Prometheus / OTA App | ❌ DAY6 이후 |

## 3. 구성 결과

### Platform 계층 (Cluster A)

| 구성요소 | 값 |
| --- | --- |
| Platform Node | worker-a1 (`workload=platform`) |
| StorageClass | `local-path` / `rancher.io/local-path` / Reclaim `Delete` / `WaitForFirstConsumer` |
| local-path-provisioner | v0.0.37, worker-a1에서 실행 |
| Local PV 경로 | worker-a1 `/opt/local-path-provisioner` |
| Registry | `registry:2`, Deployment 1 replica, nodeSelector `workload=platform` |
| Registry Storage | PVC `registry-pvc` 10Gi RWO → `/var/lib/registry` |
| Registry 접근 | NodePort `192.168.56.21:32000` (HTTP) |
| Registry requests / limits | CPU 100m / 500m, Memory 128Mi / 512Mi |
| Manifest | `k8s/platform/registry/registry.yaml` |

local-path Storage는 worker-a1 로컬 디스크를 쓰는 방식이다. 제한된 단일 Physical Server에서
Storage 자동화를 검증하기 위한 구성이며, worker-a1이 사라지면 Registry 데이터도 함께 영향을 받는다.
Production 수준의 분산 Storage HA는 제공하지 않는다.

### containerd (5대 공통)

| 항목 | 변경 전 | 변경 후 |
| --- | --- | --- |
| CRI `registry.config_path` | `'/etc/containerd/certs.d:/etc/docker/certs.d'` | `'/etc/containerd/certs.d'` |
| `certs.d/192.168.56.21:32000/hosts.toml` | `server = "http://192.168.56.21:32000"`, capabilities pull·resolve·push | 동일 |
| Transfer 플러그인 `config_path` | `''` | 변경하지 않음 |

적용 방법은 `ansible/playbooks/05-containerd-registry.yml`(serial 1, `replace` + 백업, 재시작 후
`containerd config dump`로 유효값 확인)이다.

## 4. 장애 분석 — Cluster B Image Pull 실패

### 증상

```
Head "https://192.168.56.21:32000/v2/day5/busybox/manifests/1.36":
http: server gave HTTP response to HTTPS client
```

hosts.toml에 HTTP로 접속하라고 적었는데도 kubelet·crictl 경로만 HTTPS로 접속하였다.

### 진단 (worker-b1, `05-diag-worker-b1.txt`)

| 검사 | 결과 | 의미 |
| --- | --- | --- |
| A. 유효 설정 | `use_local_image_pull = false`, `config_path = '/etc/containerd/certs.d:/etc/docker/certs.d'` | CRI가 Transfer Service로 Pull하며, 두 경로가 `:`로 묶여 있음 |
| B. hosts.toml | 경로·내용 정상 | 파일 자체는 문제 없음 |
| C. HTTP 경로 | `/v2/` 200 | 네트워크·Registry 정상 |
| D. `ctr --hosts-dir`로 직접 Pull | 성공 (2.1 MiB, 0.2 s) | 같은 hosts.toml을 직접 주면 HTTP로 감 |
| E. `crictl pull` | `HTTP response to HTTPS client` | CRI 경로만 hosts.toml을 못 찾음 |
| F. containerd 로그 | 같은 시각 `fetch failed … HTTPS` | E와 같은 요청이 HTTPS로 나감 |

### 원인 확정

containerd 2.2.1의 CRI는 기본으로 Transfer Service로 이미지를 받는다. 이 경로는
`'/etc/containerd/certs.d:/etc/docker/certs.d'`를 경로 목록이 아니라 디렉터리 하나로 취급한다.
그래서 hosts.toml을 찾지 못하고 기본값인 HTTPS로 접속한다.

CRI `config_path` 하나만 단일 경로로 바꾸는 실험을 worker-b1 한 대에 먼저 적용(카나리)하였고,
같은 `crictl pull`이 성공하였다(image `sha256:b116e155…`). 바꾼 변수가 하나뿐이므로 이를 원인으로
확정하고 나머지 4대에 적용하였다. 5대 모두 단일 경로인 것은 `06-containerd-fixed.txt`에 남겼다.

카나리 `crictl pull` 성공 출력은 화면으로 확인하였다. 증거 파일 `06-canary-worker-b1.txt`에는
전체 적용 후의 5대 설정값이 들어 있다.

### Push 실패에 대한 설명

원래 DAY5에서는 `blob unknown to registry`, `content digest … not found`로 Push가 반복 실패하였다.
`busybox:1.36`은 여러 플랫폼을 묶은 image index인데, 로컬에는 amd64 내용만 있는 상태에서 index 전체를
Push한 것이 원인으로 판단된다. 복구에서는 `--all-platforms`로 모든 플랫폼을 받은 뒤 Push하였고,
index `sha256:73aaf090…`가 오류 없이 올라갔다(exit 0, 콘솔 확인).

## 5. 복구 절차

| STEP | 내용 | 시각 (UTC) | 증거 |
| --- | --- | --- | --- |
| 0 | 측정 스크립트 `scripts/measure.sh` 도입 | 10/12 | `scripts/measure.sh` |
| 1 | 고장 상태 동결 (스냅샷, Platform·Registry·containerd 상태) | 05:03 | `measure/…day5-broken`, `01`~`04` |
| 2 | Pull 실패 진단 (A~F) | 05:33 | `05-diag-worker-b1.txt` |
| 3 | containerd `config_path` 수정 — 카나리 후 전체 | 06:05 커밋 | `06-canary-worker-b1.txt`, `06-containerd-fixed.txt` |
| 4 | Platform 계층 정리 (Registry·PVC·provisioner·수동 이미지) | 06:18 | `07-cleanup-*.txt` |
| 5 | VM 5대 정상 종료 → 콜드 백업 R0 → 재기동 | 06:46~06:48 | `08-R0-backup.txt` |
| 6 | P0 재측정 2회 | 07:17, 07:23 | `measure/…day5r-P0a`, `…P0b` |
| 7 | DAY5 범위 재수행 (local-path → PVC 테스트 → registry → 5노드 API) | 07:33~08:10 | `09-storage-test.txt`, `10-registry.txt` |
| 8 | P1 측정 (Registry Running 후 5분 이상 대기) | 08:29 | `measure/…day5r-P1`, `11-crictl-stats-P1.txt` |
| 9 | Registry End-to-End | 10/13 | `12-registry-e2e.txt` |

### 복구 지점 R0

- 위치: `/var/lib/libvirt/ota/backup/R0-20261012`
- 내용: VM별 qcow2 + `seed.iso` + domain XML, `ota-net.xml`, `SHA256SUMS`
- 크기: 25G (cp-a 6.1 GB, cp-b 5.8 GB, worker-a1 4.8 GB, worker-b1 4.9 GB, worker-b2 5.0 GB)
- `/var/lib/libvirt/ota` 사용량: 26G → 51G (295G 중 18%)
- 되돌릴 때는 5대를 항상 함께 복원한다.

## 6. 자원 측정

### 측정 방법

- 모든 값은 `scripts/measure.sh`(v1)로 수집하였다. 손으로 친 명령의 값은 기록값으로 쓰지 않는다.
- Host RAM Used = `MemTotal − MemAvailable`
- CPU·Swap = `vmstat 1 6`의 2~6번째 샘플 평균 (첫 줄은 부팅 이후 평균이라 제외)
- VM Storage = `/var/lib/libvirt/ota` 사용량 (backup 디렉터리 제외)
- P0는 같은 조건에서 두 번(P0a·P0b) 재어 `|P0b − P0a|`를 측정 오차로 썼다. 차이가 오차보다 작으면
  '측정 가능한 변화 없음'으로 판정한다. (DAY6부터는 이 값을 '관측 변동폭'이라 부른다. 12장)
- P0: Kubernetes A+B만, Platform workload 없음 (재기동 후)
- P1: P0 + local-path-provisioner + registry:2 (Push/Pull 전, Idle)
- 모든 측정은 Host KSM 켜짐(run=1) 조건이다. 측정 당시에는 몰랐고 10/13에 확인하였다 (아래 'KSM 확인 결과').

### Host 비교표

| Metric | P0 (P0b) | P1 | 차이 | 오차 | 판정 |
| --- | --- | --- | --- | --- | --- |
| Host RAM Used (MiB) | 10678.4 | 11309.3 | +630.9 | 64.5 | 증가 |
| MemAvailable (MiB) | 21131.7 | 20500.8 | −630.9 | 64.5 | 감소 |
| Swap Used (MiB) | 2.5 | 2.5 | 0 | 0 | 변화 없음 (si/so 0) |
| Load 1m | 0.81 | 1.02 | +0.21 | 0.23 | 오차 내 |
| CPU User (%) | 0.0 | 0.0 | 0 | 0 | 변화 없음 |
| CPU System (%) | 1.8 | 1.2 | −0.6 | 1.6 | 오차 내 |
| CPU Idle (%) | 93.8 | 93.8 | 0 | 4.8 | 변화 없음 |
| I/O Wait (%) | 0.0 | 0.2 | +0.2 | 0.4 | 오차 내 |
| Guest CPU (vmstat `gu`, %) | 4.2 | 4.2 | 0 | 3.2 | 변화 없음 |
| Root Used | 13G / 98G | 13G / 98G | 0 | 0 | 변화 없음 |
| VM Storage Used | 26G | 26G | 0 | 0 | G 단위 변화 없음 |
| Total QEMU RSS (MiB) | 9745.5 | 10341.7 | +596.2 | 72.8 | 증가 |

CPU User가 0%인 것은 VM이 쓰는 CPU가 `us`가 아니라 `gu`(guest) 열로 따로 집계되기 때문이다.
VM 5대의 CPU 사용은 `gu` 약 4%로 보아야 한다.

### VM별 QEMU RSS (MiB)

| VM | P0a | P0b | P1 | P0b → P1 |
| --- | --- | --- | --- | --- |
| cp-a | 2065.0 | 2065.0 | 2067.9 | +2.9 |
| worker-a1 | 1579.5 | 1614.2 | 1988.7 | **+374.5** |
| cp-b | 2571.3 | 2577.2 | 2779.1 | **+201.9** |
| worker-b1 | 1642.9 | 1675.2 | 1682.9 | +7.7 |
| worker-b2 | 1812.5 | 1812.5 | 1820.5 | +8.0 |
| 합계 | 9672.7 | 9745.5 | 10341.7 | +596.2 |

### Guest 내부 (`free -m`, MiB)

| VM | P0b used / buff·cache / available | P1 used / buff·cache / available | used 차이 |
| --- | --- | --- | --- |
| cp-a | 924 / 965 / 1043 | 944 / 1007 / 1023 | +20 |
| worker-a1 | 651 / 805 / 5273 | 672 / 1034 / 5252 | +21 |
| cp-b | 1021 / 1525 / 1886 | 1020 / 1580 / 1887 | −1 |
| worker-b1 | 626 / 839 / 6306 | 633 / 845 / 6299 | +7 |
| worker-b2 | 629 / 843 / 6303 | 629 / 909 / 6303 | 0 |

worker-a1 Root는 3.7G → 3.8G / 58G, Local PV 실제 사용량은 4.0K → 8.0K였다(Push 전).

### 컨테이너 단위 (worker-a1, P1, `crictl stats`)

Metrics Server가 아직 없으므로 `crictl stats`로 대신하였다.

| 컨테이너 | CPU % | MEM | 비고 |
| --- | --- | --- | --- |
| registry | 0.00 | 8.6 MB | requests 128Mi의 약 7% |
| local-path-provisioner | 0.63 | 11.1 MB | |
| calico-node | 1.63 | 152.6 MB | 기존 |
| kube-proxy | 0.00 | 65.5 MB | 기존 |

### 해석

1. **Storage + Registry의 상시 비용은 작다.** worker-a1 게스트 used 증가(+21 MiB)는 새 컨테이너
   두 개의 합(약 19.7 MB)과 맞는다. CPU는 provisioner 0.6% 수준이고 Host CPU 지표는 모두 오차 범위 안이다.
2. **Host 증가분 대부분은 설치 과정의 흔적이다.** worker-a1 QEMU RSS +374.5 MiB에는 이미지 Pull과
   압축 해제 중 게스트가 건드린 메모리(page cache +229 MiB 포함)가 들어 있다. 게스트가 메모리를 비워도
   Ballooning 같은 반환 장치 없이는 Host로 돌아오지 않는다.
3. **cp-b +201.9 MiB는 자연 증가로 본다.** Cluster B에는 아무 변경이 없었고, 같은 클러스터의
   worker-b1·b2는 +8 MiB 안팎이었다. Control Plane(etcd·apiserver)의 시간 경과 증가로 판단하며,
   이후 측정에서도 계속 지켜본다.
4. **cp-a는 이미 할당량에 닿아 있다.** RSS가 2 GiB 할당량(2065 MiB)에 머물러 늘어날 여지가 없고,
   게스트 available은 약 1 GiB다. Platform workload를 cp-a에 두지 않는 설계가 맞다.
5. **registry requests는 당장 줄이지 않는다.** 실사용 8.6 MB는 requests 128Mi보다 훨씬 작지만,
   Push/Pull 부하를 재기 전이므로 DAY6 Jenkins 빌드·Push 측정 후 조정한다.

### 참고: 재기동 전 값은 비교에 쓰지 않는다

| 시점 | Host RAM Used (MiB) | Total QEMU RSS (MiB) | 비고 |
| --- | --- | --- | --- |
| 원래 DAY5 P0 (10/7) | 약 14 GiB (`free -h` used) | 15778.2 | DAY5 PDF 캡처 판독값, MemAvailable 미기록 |
| 고장 상태 (10/12 05:03) | 11186.5 | 17926.9 | cp-a 2104.1 · worker-a1 4303.3 · cp-b 3130.8 · worker-b1 4199.7 · worker-b2 4187.0 |
| 재기동 후 P0b (10/12 07:23) | 10678.4 | 9745.5 | 이번 비교 기준 |

QEMU RSS는 게스트가 부팅 후 한 번이라도 쓴 메모리를 Host가 계속 들고 있는 값에 가깝다. 그래서 재기동만으로
QEMU RSS 합계가 17926.9 → 9745.5 MiB로 줄었다. 재기동 전 값과 재기동 후 값은 같은 조건이 아니므로 섞지 않는다.

### KSM 확인 결과 (10/13)

고장 상태에서는 QEMU RSS 합계(17926.9 MiB)가 Host RAM Used(11186.5 MiB)보다 컸다. 재기동으로
RSS 합계는 약 8.0 GiB 줄었지만 Host RAM Used는 약 0.5 GiB만 줄었다. VM 간 같은 메모리 페이지를 합치는
KSM을 원인으로 의심하고 Host에서 직접 확인하였다(증거 파일 없음).

```
/sys/kernel/mm/ksm/run            1          ← KSM 켜짐
/sys/kernel/mm/ksm/pages_sharing  1355601    ← × 4 KiB ≈ 5295 MiB (약 5.2 GiB) 절약 중
```

- **KSM은 켜져 있다.** DAY3~DAY5의 모든 Host 측정은 'KSM 켜짐' 조건에서 이루어진 것이다.
  README의 KSM 켜짐/꺼짐 비교 실험은 이 상태를 기준 조건으로 삼는다.
- **QEMU RSS 합계는 Host 실제 사용량이 아니다.** RSS는 합쳐진 페이지를 VM마다 각각 세므로,
  KSM이 많이 합칠수록 RSS 합계가 Host 실사용보다 커진다.
- **Host RAM Used는 측정 시점의 KSM 진행 정도에 영향을 받는다.** KSM은 실행 중에 조금씩 페이지를 합치므로,
  같은 워크로드라도 VM을 오래 켜 둔 뒤에는 Host RAM Used가 더 작게 나올 수 있다. 따라서 측정 시점마다
  KSM 절약량을 함께 기록하고, 용량 판단에는 **Host RAM Used + KSM 절약량**(KSM이 없을 때의 수요)을 쓴다.
  (DAY6에서 주 지표를 MemAvailable로 바꾸고 이 값은 보조 추정치로 낮췄다. 12장)
- **P0b → P1 비교는 유효하다.** KSM 영향을 받지 않는 QEMU RSS 차이(+596.2 MiB)와 Host RAM Used 차이
  (+630.9 MiB)가 35 MiB 안에서 일치하므로, 두 측정 사이 KSM 절약량 변화는 작았다고 판단한다.
- **KSM 절약분은 '빌린 여유'다.** 부하가 걸려 VM 메모리 내용이 달라지면 합쳐졌던 페이지가 다시 풀리고
  Host 사용량이 늘어난다. 빌드나 부하 실험 중의 피크는 이 점을 감안해 해석한다.

P0a·P0b·P1 측정 시점의 KSM 절약량은 기록되지 않았다. DAY6부터는 개정한 `measure.sh`(v3)가 KSM 상태,
절약량(`general_profit`), ksmd CPU 사용률을 함께 기록한다.

## 7. Registry End-to-End 검증

| 단계 | 내용 | 결과 |
| --- | --- | --- |
| 9-1 Push | worker-a1에서 `busybox:1.36` 전체 플랫폼 Pull → 재태그 → `--hosts-dir`로 Push | 성공 (exit 0), index `sha256:73aaf090…` (콘솔 확인) |
| 9-2 Registry 확인 | catalog · tags/list · manifest | `{"name":"day5/busybox","tags":["1.36"]}` |
| 9-3 CRI Pull | worker-b1 `crictl pull` | 9-4의 worker-b1 kubelet Pull 성공으로 함께 확인 |
| 9-4 Pod 실행 | Cluster B worker-b1·b2에 `imagePullPolicy: Always` Pod | 2개 모두 Completed, 로그 `registry-e2e-ok` |
| 9-5 영속성 | Registry Pod 재시작 후 태그 유지 | tags/list `1.36` 유지 (증거 파일에는 마지막 tags/list만 있음) |

worker-b2는 해당 이미지 캐시가 없는 상태에서 kubelet이 직접 받았다.

```
Pulling image "192.168.56.21:32000/day5/busybox:1.36"
Successfully pulled image "192.168.56.21:32000/day5/busybox:1.36" in 144ms
  (144ms including waiting). Image size: 2217006 bytes.
```

원래 DAY5에서 막혔던 'Cluster B → 사설 HTTP Registry' 경로가 실제 워크로드 기준으로 동작한다.
DAY6에서 Jenkins Push가 실패하면 인프라가 아니라 Pipeline 설정부터 보면 된다.

## 8. 결정 사항

| 결정 | 내용 | 근거 |
| --- | --- | --- |
| containerd Registry 설정 | CRI `config_path`를 `'/etc/containerd/certs.d'` 단일 경로로 고정, Ansible로만 변경 | 4장 원인 확정 |
| Storage | local-path(노드 로컬 디스크) 사용, HA 아님을 명시 | 단일 Physical Server 제약 |
| 측정 방식 | `measure.sh`만 사용, 재기동 후 P0 재측정, P0 2회로 오차 산정 | 재기동 전후 RSS 비교 불가 |
| 메모리 지표 | Host RAM Used(Total − Available)와 KSM 절약량을 함께 기록. 용량 판단은 Used + KSM 절약량. QEMU RSS 합계는 보조 | 6장 KSM 확인 결과 (DAY6에서 수정, 12장) |
| KSM | 현재 상태(켜짐)를 기준 조건으로 유지. 켜짐/꺼짐 비교는 별도 실험으로 수행 | README 9장 |
| 자동 업데이트 | 실험 기간 동안 VM 자동 업데이트 중지 (`06-disable-auto-upgrade.yml`) | 커널 자동 변경으로 측정 조건이 바뀜 |
| registry 자원 | requests 100m/128Mi, limits 500m/512Mi 유지 | Push/Pull 부하 측정 전 |
| 복구 지점 | 되돌리기 어려운 변경 전 콜드 백업. 보관 개수는 최대 2개를 제안, DAY6 전 확정 | R0 25G, VM LV 여유 230G |
| Registry 보안 | HTTP(비암호화)는 내부망 192.168.56.0/24 한정으로 허용 | 실습 범위 |

## 9. Issue 정리

| 증상 | 원인 | 조치 | 상태 |
| --- | --- | --- | --- |
| Cluster B `crictl pull` → `HTTP response to HTTPS client` | containerd 2.2.1 기본 `config_path`(`:` 묶음)를 CRI Transfer Pull이 디렉터리 하나로 취급 | 단일 경로로 변경, 카나리 → 전체 | 해결 (원인 확정) |
| Push `blob unknown to registry`, `content digest not found` | 일부 플랫폼만 있는 index를 Push | `--all-platforms`로 받은 뒤 Push | 해결 |
| `storage-ok` 읽기 기록 누락 | 기록 누락 | PVC 테스트 재수행 | 해결 |
| Registry에 `day5/buxybox` 저장소 잔존 | 재태그 시 이름 오타 | 올바른 이름으로 재Push. registry:2 기본 설정은 삭제가 꺼져 있어 남겨 둠 (blob 공유로 용량 영향 미미) | 기록만 |
| `stagins` Namespace 생성 | 재수행 중 Namespace 이름 오타 | DAY7 STEP 1에서 삭제 | 해결 (DAY7) |
| worker-b1 containerd `diag` namespace 삭제 실패 | 진단용 Pull의 blob·snapshot이 남아 있음 (`07-cleanup-worker-b1`) | 이미지만 삭제, namespace는 남김 | 기록만 |
| `03-containerd-config.txt`에 수정 전 `config_path` 값 없음 | 확인 명령의 grep 인자 오류 | 수정 전 유효값은 `05-diag-worker-b1`(worker-b1)으로만 남음 | 기록만 |
| worker-b1이 `virsh shutdown`(ACPI)에 응답하지 않음 | 미확인 | 게스트 안에서 `systemctl poweroff` | 우회 (DAY6 R1 종료 때 재발 기록 없음) |
| R0 재기동 후 VM 커널 6.8.0-142 → 6.8.0-146 | unattended-upgrades 자동 업데이트로 추정 | `06-disable-auto-upgrade.yml`로 자동 업데이트 중지 | 조치 완료 (DAY6 STEP 3), 원인 로그는 미확보 |
| QEMU RSS 합계 > Host RAM Used | KSM 켜짐(run=1). 10/13 기준 약 5.2 GiB를 VM 간 공유 | KSM 절약량을 측정 항목에 추가, 용량 판단은 Used + 절약량 | 원인 확정 |

## 10. DAY6 진입 조건

- [x] Cluster A 2대 · Cluster B 3대 Ready, 비정상 Pod 없음
- [x] 5대 모두 CRI `config_path = '/etc/containerd/certs.d'`
- [x] Pull 실패 원인 확정
- [x] R0 백업과 `SHA256SUMS`
- [x] P0a · P0b · P1 측정 파일 커밋, 비교표 작성
- [x] `storage-ok` 읽기 확인
- [x] registry on worker-a1, `registry-pvc` 10Gi Bound, NodePort 32000
- [x] 다섯 노드 → `/v2/` 200
- [x] tags/list `1.36`, worker-b1 · b2 Pod `registry-e2e-ok`
- [x] worker-a1 `e2e` namespace 검증 이미지 정리 (DAY6 STEP 2에서 완료)
- [x] (선택) 복구 지점 R1 — Jenkins 설치 전 (DAY6 STEP 4에서 완료)

P1은 DAY5의 결과값으로 남긴다. DAY6는 시작 직전에 개정한 `measure.sh`로 **day6-P0**를 새로 측정해 기준선으로 쓴다.
P1 이후 시간이 지나 KSM 절약량이 달라졌으므로 P1 값을 그대로 복사하지 않는다. 측정 순서는
Jenkins Idle → Build Agent → 빌드 중 Peak이며, 매번 `measure.sh`로 잰다.

## 11. 증거 파일

| 파일 | 내용 |
| --- | --- |
| `measure/20261012-050316-day5-broken.txt` | 고장 상태 스냅샷 (비교값 아님) |
| `measure/20261012-071745-day5r-P0a.txt` | P0 1차 |
| `measure/20261012-072323-day5r-P0b.txt` | P0 2차 (비교 기준) |
| `measure/20261012-082952-day5r-P1.txt` | P1 |
| `day5r/01-cluster-a-platform.txt` | 고장 상태 Cluster A Platform 리소스 |
| `day5r/02-registry-state.txt` | 고장 상태 Registry catalog·tags |
| `day5r/03-containerd-config.txt` | 5대 hosts.toml (`config_path` 출력은 명령 오류로 없음) |
| `day5r/04-worker-a1-ctr-images.txt` | worker-a1 수동 태그 이미지 |
| `day5r/05-diag-worker-b1.txt` | Pull 실패 진단 A~F |
| `day5r/06-canary-worker-b1.txt`, `06-containerd-fixed.txt` | 수정 후 5대 유효 설정 |
| `day5r/07-cleanup-*.txt` | Platform 계층·이미지 정리 (worker-b1 `diag` namespace 삭제 실패 포함) |
| `day5r/08-R0-backup.txt` | R0 SHA256·파일 목록 |
| `day5r/09-storage-test.txt` | PVC 동적 생성 + `storage-ok` |
| `day5r/10-registry.txt` | Registry 배포, 5노드 `/v2/` 200, Local PV 사용량 |
| `day5r/11-crictl-stats-P1.txt` | P1 컨테이너별 CPU·MEM |
| `day5r/12-registry-e2e.txt` | End-to-End (앞 3줄은 이름 오타 시점의 결과) |

## 12. 이후 처리 (DAY6·DAY7)

DAY5 종료 시점에 남았던 항목과 결정이 이후 어떻게 처리됐는지 적는다. 자세한 내용은 `day6.md`, `day7.md`에 있다.

| 항목 | 처리 | 근거 |
| --- | --- | --- |
| worker-a1 `e2e` 검증 이미지 | DAY6 STEP 2에서 정리, 남은 이미지 0개 | `day6/03-e2e-cleanup` |
| 복구 지점 보관 정책 | DAY6 STEP 4에서 R1(`R1-20261013-0751`, 26G) 생성. R0·R1 2개 보관으로 확정 | `day6/06-R1-backup` |
| 자동 업데이트 중지 | DAY6 STEP 3에서 VM 5대와 Host 모두 적용(APT 주기 작업 `"0"`, timer disabled). 커널 146 원인 로그 수집은 명령 오류로 실패해 원인은 추정으로 남음 | `day6/c--auto-upgrade-all.log`, `05f`, `04` |
| 측정 스크립트 | DAY6에서 v3 사용. KSM `general_profit`·QEMU PSS·Node 할당량 기록, 수집 실패 시 종료 코드 1 | `scripts/measure.sh` |
| 메모리 지표 | DAY6에서 주 지표를 Host MemAvailable로 바꾸고, 'Used + KSM 절약량'은 시점 비교용 보조 추정치(KSM 보정 사용량)로 낮춤. DAY6 P0(재기동 직후, KSM 0)와 P1(18시간 뒤, KSM 절약량 4877 MiB)에서 Host 지표 부호가 뒤집혀, KSM 상태가 다른 구간의 Host 차이는 비용으로 쓰지 않는다 | `day6.md` 7장 |
| 오차 표현 | P0a·P0b 차이를 '관측 변동폭'으로 부름. 단기 잡음만 담는 값이라 측정 불확도로 쓰지 않음 | `day6.md` 7장 |
| registry 자원 | 변경 없이 유지. DAY6 실사용 25.4~29.5MB(`crictl stats`), Local PV 18M → 39M(`day6/demo` 태그 4개). CI Push 4회와 Cluster B digest Pull(DAY6 STEP 15, DAY7) 모두 성공 | `day6/12`, `day6/17`, `day7.md` 5장 |
| containerd 수정 유지 | DAY6 STEP 15·DAY7에서 Cluster B 두 Worker가 digest 참조로 Pull·실행 | `day6/15-cluster-b` |
| `stagins` Namespace | DAY7 STEP 1에서 삭제 | `day7/01-leftovers` |
| `day5/buxybox` 저장소 | 그대로 남음(DAY6 STEP 2 catalog 확인) | `day6/02-day5-state` |