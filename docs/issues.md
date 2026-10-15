## Issue-01
### 학원 Wi-Fi에서 Server ↔ Laptop 직접 통신 불가

### Physical Server

Interface: wlx088af1327d7f
IP: 192.168.200.48/22
Gateway: 192.168.200.1
LAN: 192.168.200.0/22

### 정상 확인

Server → Gateway: SUCCESS
Server → Internet: SUCCESS
Laptop → Internet: SUCCESS

SSH daemon:
TCP/22 Listen 확인

### 실패

Server → Laptop: FAIL
Laptop → Server: FAIL
SSH Client → Server: FAIL

### 판단

Server 자체의 IP 설정이나 Internet Routing 문제보다는
학원 Wireless Network의 Client/AP Isolation 정책 가능성이 높다고 판단.

### 프로젝트 영향

KVM 및 VM 내부망 구축에는 영향 없음.

ESP32 연결 전에는
Device → MQTT/HTTPS Endpoint 접근 경로를 반드시 확정해야 함.

## Issue — cp-a DHCP Reservation 누락

### 증상

VM 5대 생성 후 `cp-a`만 일반 DHCP Pool의
`192.168.56.100`을 할당받았다.

기대값:

`192.168.56.20`

### 원인

`03-create-vms.yml`에서 DHCP Reservation의 존재 여부를
다음과 같이 전체 XML 문자열에서 확인하고 있었다.

```yaml
when:
  - item.mac not in ota_net_xml.stdout
  - item.ip not in ota_net_xml.stdout
```

(이 Issue의 나머지 원인·조치 기록은 원본에서 코드 블록이 닫히지 않은 채 끝나 있었다. DAY7 추가 시 블록만 닫았다.)

## Issue — DAY7 argocd cluster add가 B 관리자 인증서를 저장

### 증상

`argocd cluster add ota-b --namespace production` 후 Argo CD의 B 등록 Secret을 확인하니
`bearerToken`이 없고 `certData`·`keyData`가 있었다.
B에는 production 한정 Role과 `argocd-manager` SA·토큰 Secret이 정상으로 만들어져 있었다.

### 원인

ota-b kubeconfig 사용자가 kubeadm 관리자 클라이언트 인증서다.
Argo CD v3.5.5 `cmd/util/cluster.go`의 `NewCluster`는 kubeconfig에 인증서가 있으면
SA 토큰을 넣지 않고 그 인증서를 저장한다.
그 결과 Argo CD는 B에 cluster-admin으로 접속하고, production 한정 Role은 쓰이지 않는다.

### 조치

Production Application 등록 전에 cluster Secret의 `config`를
`argocd-manager` SA 토큰 + CA(`insecure: false`)로 교체했다(DAY7 실행 문서 6-3b).
교체 후 `bearerToken=있음 certData=없음 keyData=없음`, 연결 `Successful`.
`argocd cluster get -o wide`의 인증 표시는 API가 자격 증명을 가려서 판정에 쓸 수 없다.

### 상태

해결. 이후 클러스터 등록 때마다 cluster Secret의 키 존재를 확인한다.

## Issue — DAY7 CLI 미로그인 상태에서 Sync 블록 일괄 실행

### 증상

`gitops-sync.sh`가 `Argo CD server address unspecified`로 STOP했는데,
같은 블록의 다음 줄인 Staging 중지 Commit(`5c2f890`)까지 Push됐다.
이후 admin 비밀번호 불일치로 로그인도 실패했다.

### 원인

3-5 로그인 단계가 끝나지 않은 상태에서 STEP 5 블록을 한 번에 붙여 넣었다.

### 조치

`5c2f890`을 revert(`5883c09`)한 뒤 admin 비밀번호를 bcrypt 해시로 재설정하고 로그인했다.
이후 Sync는 한 줄씩 실행하고 `RESULT=PASS`를 확인한 뒤 다음 줄로 넘어갔다.
같은 이름으로 재실행해 덮어쓴 `20-staging-G-sync.txt`는 Argo CD history로 재기록했다.

### 상태

해결. 배포된 것은 없었고 Git 이력에 경위가 남아 있다.

## Issue — DAY7 데모 앱 Pod 종료 30초

### 증상

실패 Pod 종료가 Terminating 3m9s → 3m39s로 30초 걸렸다.

### 원인

python이 컨테이너 PID 1이라 SIGTERM을 무시하고, grace 30초 뒤 SIGKILL로 끝난다.

### 조치

DAY7은 관측만 했다. 서비스 응답 실패는 없었다.

### 상태

DAY8 후보: 앱 SIGTERM 처리 또는 `terminationGracePeriodSeconds` 조정, readiness 시작 대기 추가.

## Issue — DAY7 cp-a 메모리 여유 감소

### 증상

cp-a Guest MemAvailable 983 MiB(P0) → 719 MiB(P2).

### 원인 (추정)

Argo CD 컨트롤러가 Cluster A 리소스를 watch하면서 kube-apiserver 메모리가 늘었다.
cp-a 컨테이너별 측정이 없어 확정하지 않았다.

### 상태

관찰. 다음 측정부터 cp-a 컨테이너별 사용량을 함께 기록한다.

DAY8부터 기록(`docs/evidence/day8/03`·`51`·`59`): kube-apiserver 608 → 620 → 605MB. cp-a Guest MemAvailable P0 734 → P1 665 → P2 691 MiB, 설치·CI 구간 최저 645 MiB, PSI 0.0.

## Issue — K8s 업그레이드 중 Host swap 증가

### 증상

업그레이드 연속 수집(`upg-hops2`)에서 Host swap 사용량이 3 MiB(21:30Z 이전) → 2,872 MiB(H5 끝) → 3,847 MiB(STEP 5-1)로 늘었다.
swap-in 합계 약 860 MiB, swap-out 합계 약 4.4 GiB. Host MemAvailable 최저 6,654 MiB. DAY1~7의 모든 측정은 si/so 0이었다.

### 원인 (추정)

STEP 2 콜드 재기동 뒤 KSM이 거의 병합하지 않은 상태(절약량 음수)에서, 단계마다 이미지 Pull과 drain으로 게스트가 새 메모리를 건드려
VM RSS가 할당 상한 근처까지 올라갔다(worker-b1 6,845, worker-a1·b2 약 6,200 MiB). 커널이 페이지 캐시 일부와 함께
오래 쓰지 않은 VM 페이지를 swap으로 보냈다.

### 조치

B 데모 서비스 영향 없음(모든 단계 fail 0). VM 정지 상태에서 swap 82 MiB로 돌아오는 것을 확인했다(`90-host-mem-vms-stopped`).

### 상태

열림. DAY8 부하·Autoscaling 실험에서 Host swap(si/so)을 주 관찰 항목에 넣는다. 반복되면 VM 할당 합(25 GiB)·swappiness·KSM 설정을 검토한다.

DAY8 관찰: 설치·CI 연속 수집에서 si 합계 16·8, so 0, Swap Used 65.5 MiB 그대로였다. 설치 중 worker-a1 QEMU RSS가 할당 상한(6 GiB) 근처까지 올랐지만, KSM 절약량이 5,477 MiB까지 늘어 있던 상태라 swap-out은 없었다.

## Issue — K8s 업그레이드 후 Control Plane 디스크 증가

### 증상

cp-a 4.9G → 14G (18% → 50%), cp-b 4.8G → 14G (18% → 48%), 이미지 수 11 → 57·53. Worker도 이미지 7~19 → 31~44.
`/etc/kubernetes/tmp`(kubeadm 업그레이드 백업) cp-a 2.3G, cp-b 2.2G.

### 원인

단계마다 제어부·kube-proxy·Calico·CoreDNS 새 이미지를 받았고 이전 이미지가 남았다. kubelet 이미지 GC는 디스크 85%부터 동작한다.
kubeadm은 업그레이드마다 etcd 데이터와 manifest 백업을 `/etc/kubernetes/tmp`에 남긴다.

### 조치

지우지 않았다(되돌리기 근거 보존).

### 상태

열림. 정리 방법을 결정한다: 사용하지 않는 이미지 정리(`crictl rmi --prune`), `/etc/kubernetes/tmp`는 마지막 단계만 남기기.
cp 디스크는 29G라 다음 업그레이드 전에 정리한다.

DAY8 관찰: cp-a 50 → 51%, worker-a1 26 → 30%(관측 이미지·PV), worker-b2 12 → 13%.

## Issue — DAY8 붙여넣은 명령에서 `$` 앞 공백이 사라짐

### 증상

STEP 3의 lint·template 반복문이 경로가 깨진 채 실행돼 `helm lint`가 한 번도 실행되지 않았다(`docs/evidence/day8/22-helm-lint.txt`).
이미지 미리 받기는 5 Node 모두 `syntax error near unexpected token`으로 실패했다(`25-image-prepull.txt`). `01-state-before.txt`의 소제목도 `## nodesota-a`처럼 붙었다.

### 원인

붙여 넣은 명령에서 `$` 바로 앞의 공백이 사라졌다: `for i in $IMGS` → `for i in$IMGS`, `## lint $v` → `## lint$v`, `"... $PROM_CHART"` → 앞 단어와 붙음.
복사한 화면이 `$…$` 사이를 수식으로 처리한 것으로 추정한다. 오류 없이 다른 값으로 실행되는 경우가 있어 결과만으로는 알아차리기 어렵다.

### 조치

렌더링은 따로 실행돼 `22-*-rendered.yaml`·렌더링 검토·서버 dry-run·실제 설치가 정상이었다. 이미지는 설치 중에 받았다(Grafana 약 196초).
lint는 실행되지 않은 것으로 남긴다.

### 상태

열림. `helm lint` 3개를 다시 실행해 `22-helm-lint-r2`로 남긴다. 명령은 원본 텍스트(GitHub Raw, 편집기, `less`)에서 복사하고, 변수가 들어간 줄은 붙여 넣은 뒤 공백을 눈으로 확인한다.

## Issue — DAY8 STEP1이 DAY7 증거 파일을 덮어씀

### 증상

커밋 `66f1a77`(DAY8 STEP1)이 `docs/evidence/day7/00-timeline.txt`에 `2026-10-15T03:00:06Z STEP1 start`를 더하고 `docs/evidence/day7/01-state-before.txt`를 DAY8 시작 상태로 덮어썼다.

### 원인

`EV`가 day7인 셸에서 1-1을 실행했다(`day8-session.env` 적용 전으로 추정). `mark`와 증거 경로의 기본값이 day7이다.

### 조치

DAY8 보고서 커밋과 함께 두 파일을 `66f1a77^` 내용으로 복구했다. 잘못 들어간 03:00Z 상태는 Git 이력(`66f1a77`)에 남아 있다.

### 상태

해결. 새 세션 첫 명령 전에 `echo "$EV"`로 증거 경로를 확인한다. 다음 세션 env 파일은 이전 세션 증거 디렉터리를 가리키면 멈추게 한다.

## Issue — DAY8 GitHub 웹 업로드 스크립트의 실행 비트 없음

### 증상

STEP 2 1차에서 `./scripts/storage-test.sh`가 Permission denied로 실행되지 않았다.

### 원인

새 스크립트 4개(`storage-test.sh`, `chart-defaults.py`, `prom-check.py`, `grafana-check.py`)를 GitHub 웹으로 올려 Git 모드가 100644였다.

### 조치

`git update-index --chmod=+x`로 고쳐 커밋(`69015d3`)하고 STEP1·2를 다시 했다.

### 상태

해결. 웹으로 올린 뒤에는 `git ls-files -s scripts/`에서 실행 파일이 `100755`인지 확인한다.

## Issue — DAY8 kube-state-metrics Target 2개로 prom-check FAIL

### 증상

`40`·`41`·`42` 1차가 `kube-state-metrics Target 2개 (기대 1)`로 FAIL. 다른 항목은 모두 정상이었다.

### 원인

KSM Service가 8080(객체 지표)·8081(KSM 자체 지표) 두 포트를 노출하고, `kubernetes-service-endpoints`의 endpointslice SD는 포트마다 Target을 만든다. 수집은 정상이었고 `prom-check.py`의 기대값이 틀렸다.

### 조치

`4c5d0cd`: `:8080` Target이 1개인지로 판정하고 Target 목록을 기록. `-r2` 3개 PASS.

### 상태

해결.

## Issue — DAY8 worker-a1 limits 합이 allocatable을 넘음

### 증상

Prometheus·Grafana 설치 후 worker-a1 limits 합이 memory 6,176Mi(106%)·CPU 4,550m(113%)다. CI Agent가 붙으면 9,760Mi(168%)·9,050m(226%)다.

### 원인

limits는 예약이 아니고 스케줄은 requests(설치 후 39%, CI 중 55%)로 한다. 플랫폼·관측·CI가 모두 worker-a1 한 대에 있다.

### 조치

그대로 두고 실사용으로 판단했다. CI 중 worker-a1 Guest MemAvailable 최저 3,831 MiB, OOM·Eviction 없음.

### 상태

열림. 자원 예산·Quota/LimitRange 세션에서 다룬다.

## Issue — DAY8 Grafana 실사용이 requests보다 큼

### 증상

Grafana 컨테이너 working set 208MB(약 199 MiB, `crictl`), requests 128Mi의 155%다(limit 384Mi의 52%).

### 원인

values의 예산이 실사용보다 작다. 나머지 관측 컴포넌트는 requests의 20% 안팎이다.

### 상태

열림. requests 조정 후보(실사용을 몇 번 더 잰 뒤 정한다).

## Issue — DAY8 관측 구성의 권한·노출 (Chart 기본값)

### 증상

1. Prometheus 서버 ClusterRole에 클러스터 전체 `configmaps` get/list/watch가 있다.
2. B Prometheus NodePort 30909로 lifecycle API(`/-/reload`, `/-/quit`)가 인증 없이 열린다.

### 원인

1. Chart 29.37.0 `templates/clusterrole.yaml`에 고정된 규칙이다(values로 뺄 수 없음). 오늘 수집 job 4개에는 필요 없다. 실행 문서의 권한 검토는 `nodes/proxy`·`secrets`만 봤다.
2. Chart 기본 플래그 `--web.enable-lifecycle`(config reloader가 사용).

### 조치

기록만 했다. 2는 libvirt NAT 내부망이라 Host·VM만 닿는다.

### 상태

열림. 1은 직접 만든 ClusterRole + `server.useExistingClusterRoleName`으로 줄일지 결정한다. 2는 B를 내부망 밖에 열 일이 생기면 먼저 다룬다.

## Issue — DAY8 CI trivy memory.peak가 limit에 닿음

### 증상

`day6-ci` #10에서 trivy 컨테이너 `memory.peak` 1,073,745,920 B = limit 1Gi + 4 KiB. DB 준비 69초. 검사는 성공했다.

### 원인

Trivy DB 갱신 다운로드(DownloadedAt 04:43:52Z). DAY6 run01(첫 다운로드)과 같은 형태이고, DB가 있던 #9(00:07Z)는 138.7 MiB였다.

### 상태

열림 (DAY6부터 조정 후보). trivy limit과 `memory.events` 기록을 함께 정한다.
