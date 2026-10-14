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
  - item.ip not in ota_net_xml.stdout```

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