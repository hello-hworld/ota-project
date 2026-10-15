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

## D13. kubelet 지표 수집의 TLS·권한 (DAY8)

### 판단
Prometheus Chart 29.37.0의 kubelet·cAdvisor 수집(`kubernetes-nodes`, `kubernetes-nodes-cadvisor`)은 kubelet(10250)에 직접 붙고
서버 인증서 검증을 생략한다(`insecure_skip_verify: true`, Chart 기본값). kubeadm의 kubelet 서빙 인증서는 클러스터 CA 서명이 아니어서 검증을 켜면 실패한다.
검증을 유지하는 대안인 API 서버 프록시(`/api/v1/nodes/<node>/proxy/metrics/...`)는 `nodes/proxy` get 권한이 필요하고,
이 권한으로 kubelet WebSocket exec가 가능하다(Kubernetes 보안팀: 의도된 동작).

### 결정
Chart 기본값을 유지한다. 검증 생략 범위는 kubelet 2개 job, 권한은 `nodes/metrics`만, 경로는 libvirt NAT 내부망이다. `nodes/proxy`는 주지 않는다.
DAY8 렌더링·설치에서 확인: Prometheus ClusterRole에 `nodes/proxy`·`secrets` 없음(`docs/evidence/day8/22-scrape-review.txt`), kubelet Target 5개 모두 up.

### 이후
kubelet 서빙 인증서를 클러스터 CA로 발급(`serverTLSBootstrap` + CSR 승인)한 뒤 검증을 켠다. 5 Node kubelet 설정 변경이라 별도 변경으로 잡는다.

## D14. 관측 구성 (DAY8)

Prometheus는 클러스터마다 하나(A: worker-a1, B: worker-b2), 각자 자기 클러스터만 수집한다. Grafana는 A에 하나이고 A·B를 별도 Data Source로 조회한다.
B는 NodePort 30909 + `externalTrafficPolicy: Local`(worker-b2만 응답)로 실습 내부망에 연다. 보존 48h·3GB, 수집 30s, job 4개(`prometheus`, kubelet, cAdvisor, service-endpoints).
설치·변경은 고정 Chart + values 파일(`helm/monitoring/`)로만 하고 Argo CD에 등록하지 않는다. Data Source·대시보드는 파일, 관리자 비밀번호는 Secret 참조.
kube-state-metrics는 secrets를 수집하지 않는다(collectors 17개). Control Plane 별도 지표는 수집하지 않는다. 컴포넌트 비용 판단은 D11을 따른다.

### 결과 (DAY8)
Target A 11개·B 14개 모두 up, Grafana 서버가 두 Data Source 조회 성공, 설치 후 CI 1회 SUCCESS.
상시 비용: memory requests A +656Mi·B +560Mi, 실사용(`crictl`) A 319MB·B 116MB, Guest MemAvailable worker-a1 −447 MiB·worker-b2 −152 MiB.
근거: `docs/baseline/day8.md`, `docs/evidence/day8/`.

### 열린 점
Grafana 실사용이 requests보다 크다. Prometheus 서버 ClusterRole의 클러스터 전체 ConfigMap 조회, B NodePort의 lifecycle API 노출은 Chart 기본값으로 남아 있다(`docs/issues.md`).
