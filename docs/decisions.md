## D05. vCPU Overcommit

### Physical Host

Intel Core i5-12400

Physical Core: 6
Logical CPU: 12

### VM 계획

총 할당 vCPU: 16

Overcommit Ratio:

16 / 12 = 약 1.33:1

### 판단

CPU는 초기 설계에서 1.33:1 수준으로 Overcommit한다.

VM에 할당한 vCPU 수가 실제 Physical CPU를 의미하는 것은 아니며,
모든 VM이 동시에 CPU를 요구할 경우 Host CPU 경쟁이 발생할 수 있다.

따라서 이후 Jenkins Build 부하 및 Production 부하를 동시에 발생시켜
CPU 사용률, Load, API 지연 등을 측정한다.

### 현재 상태

초기 실험 조건이며 성능이 검증된 값은 아니다.

## D06. Argo CD 설치 구성 고정 (DAY7)

Chart argo-cd 10.10.3 / Argo CD v3.5.5를 Cluster A worker-a1에 Helm으로 설치한다.
Controller·Server·Repo Server·Redis 각 1개, Redis HA·Dex·Notifications 끔,
ApplicationSet은 Chart에 `enabled` 키가 없어 `replicas: 0`으로 끈다.
values 키는 고정 Chart의 기본 values와 대조해 존재를 확인한다(`values-keycheck.py`).

Kubernetes 1.30.14는 Argo CD 3.5의 공식 테스트 범위 밖이며, 실습 조건으로 기록한다.

## D07. 앱 변경은 Git → 수동 Sync로만 한다 (DAY7)

values 한 줄 변경 → 그 파일만 Commit·Push → `gitops-sync.sh`(Refresh → Diff → Sync → Wait).
실패는 그 Commit만 `git revert`로 되돌린다.
`kubectl edit/scale/set image`, 앱 Release에 대한 `helm upgrade`는 쓰지 않는다.

## D08. Production digest는 Staging 검증 후에만 기입 (DAY7)

Production values의 digest는 Staging에서 실제 실행·Health·HTTP·version을 확인한 값만 넣는다.
데모 Chart는 빈 digest나 형식 오류를 렌더링 단계에서 거부한다.
승격 전 CI 결과(test·scan·digest 일치), Staging 결과, Staging·Agent 0개를 확인표로 남긴다.

## D09. 원격 클러스터 등록은 Namespace 한정 SA 토큰으로 (DAY7)

`argocd cluster add`는 kubeconfig에 클라이언트 인증서가 있으면 관리자 인증서를 저장한다.
등록 후 cluster Secret에서 `bearerToken` 있음, `certData`·`keyData` 없음을 확인하고,
아니면 SA 토큰으로 교체한다. B 권한은 production Role만 둔다.

## D10. Production 분산 조건 (DAY7)

Production은 worker-b1·b2만 대상으로 하고, hostname topology spread에
`matchLabelKeys: [pod-template-hash]`를 둔다.
롤링 업데이트 뒤에도 새 ReplicaSet Pod가 노드당 1개로 유지되는 것을 DAY7에서 확인했다.

## D11. 컴포넌트 비용 판단 지표 (DAY7)

컴포넌트 비용은 Guest MemAvailable, K8s requests/limits, 컨테이너 사용량(`crictl stats`)으로 판단한다.
Host MemAvailable·QEMU PSS/RSS는 시간 경과와 KSM 재배치가 섞이므로 보조 지표로 쓴다.

## D12. Kubernetes 1.30.14 → 1.36.5 제자리 업그레이드 (2026-10)

### 판단
1.30은 2025-07-15 지원 종료. DAY8 이후 구성요소(Metrics Server 0.8+, KEDA 2.18+, Argo Rollouts 공식 지원)가 1.30을 벗어난다.
재구축 대신 제자리 업그레이드: kubeadm init/join이 코드에 없고, Jenkins Job·Registry 이미지가 PVC에 있다.

### 방법
kubeadm 공식 절차로 minor 하나씩 6단계(각 minor 마지막 patch), A → B. Calico는 3.28.2 → 3.32.2를 minor 하나씩,
각 시점의 Kubernetes가 Calico 테스트 범위 안에 있도록 교차. 시작 전 복구 지점 RU.
Node 패키지·Static Pod·Calico는 손으로 바꾸지 않고 `k8s-hop.sh`·`calico-upgrade.sh`(사전·사후 관문)로만 바꿨다.

### 결과
10개 단계 모두 PASS(H1은 스크립트 버그 수정 후 재실행). B 데모 서비스 요청 9,026건 중 실패 0.
업그레이드 후 Argo CD·Staging 왕복·CI 1회·VM 재기동 모두 정상. 근거: `docs/baseline/k8s-upgrade.md`, `docs/evidence/k8s-upgrade/`.

### 이후 규칙
- 버전을 다시 밀리지 않게 minor 출시마다(약 4개월) 한 단계씩 올린다. 같은 스크립트로 한 단계 약 20분.
- 새 Node는 `04-base-config.yml`의 `k8s_minor`(현재 1.36)로 설치한다.
- 업그레이드 뒤 Control Plane 디스크(이미지·`/etc/kubernetes/tmp`)와 Host swap을 확인한다.