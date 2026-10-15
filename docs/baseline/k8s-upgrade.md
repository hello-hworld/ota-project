# K8s Upgrade Result — 1.30.14 → 1.36.5 (Calico 3.28.2 → 3.32.2)

- 진행: 2026-10-15 04:44 ~ 10:34 (KST, 보고서 작성 제외). 본문 시각은 증거 파일과 같은 UTC (2026-10-14 19:44Z ~ 10-15 01:34Z)
- 실행 문서: `K8s_1.36_업그레이드_실행.md` (실행 중 수정 반영본)
- 기준 커밋: DAY7 끝 → STEP0 `2a0e069` → 마지막 증거 커밋 ``dd37a4b``
- 증거 경로: `docs/evidence/k8s-upgrade/`, `docs/evidence/measure/*upg*`

## 1. 요약

Cluster A·B를 재구축 없이 kubeadm 공식 절차로 1.30.14에서 1.36.5까지 minor 하나씩 6단계 올렸다. Calico는 각 시점의 Kubernetes가 공식 테스트 범위 안에 있도록 3.28.2 → 3.32.2를 minor 하나씩 4번 교차해 올렸다. 모든 단계는 A를 먼저 하고 A가 PASS일 때만 B를 진행했다.

- 10개 단계(U1~U4, H1~H6) 모두 최종 `RESULT=PASS`. H1은 1차에서 내 스크립트 버그(패키지 조회 SIGPIPE)로 설치 전에 멈췄고, 수정 후 재실행해 PASS했다.
- B Production 데모 서비스는 B 쪽 10개 단계 동안 0.5초 간격 요청 8,584건 중 실패 0건(H1 1차 실패 시도 442건 포함 9,026건 중 0건).
- A는 Worker가 1대라 매 단계 drain 동안 플랫폼(Jenkins·Argo CD·Registry)이 멈췄다. Ansible 종료 후 A Pod 전체 정상까지 112~122초.
- 업그레이드 후 기능 확인: Argo CD 두 앱 Synced·Healthy, Staging 왕복(Git → Sync → 확인 → 중지) PASS, CI 1회(test·scan·push, built = pushed) SUCCESS.
- VM 재기동 후 5 Node Ready 49초, 모든 Pod 정상. U-P1(재기동 +3,442초)과 U-P0(+3,219초) 비교: Guest MemAvailable은 5대 모두 줄지 않았고(합계 +300 MiB), Host MemAvailable −361 MiB·QEMU RSS +381 MiB는 B 노드가 재기동 후 건드린 페이지다. 디스크는 Control Plane 21% → 50%(7장).
- 새로 발견: 업그레이드 중 Host swap이 3 MiB → 3,847 MiB까지 늘었다(DAY1~7 'si/so 0'과 다른 첫 사례). VM 정지로 82 MiB로 돌아왔다. Control Plane 디스크가 18% → 50%로 늘었다(이미지 누적 + kubeadm 백업 2.2~2.3 GiB). 8장.

결과는 '두 클러스터의 제자리 업그레이드와 기존 DAY4~7 기능 유지 확인'이다. 업그레이드 중 B 데모 서비스 무중단은 Worker 2대 + topology spread 조건에서의 결과이며, A 플랫폼은 매 단계 멈췄다.

## 2. 버전과 경로

| 구성요소 | 이전 | 이후 | 경로 |
| --- | --- | --- | --- |
| Kubernetes (A/B) | v1.30.14 | v1.36.5 | 1.31.14 → 1.32.13 → 1.33.13 → 1.34.12 → 1.35.9 → 1.36.5 (각 minor 마지막 patch) |
| etcd | 3.5.15-0 | 3.6.8-0 | 3.5.24 (H1~H3) → 3.6.5 (H4) → 3.6.6 (H5) → 3.6.8 (H6) |
| CoreDNS | v1.11.3 | v1.14.2 | v1.11.3 (H1·H2) → v1.12.0 → v1.12.1 → v1.13.1 → v1.14.2 |
| Calico (manifest, kube-system) | v3.28.2 | v3.32.2 | 3.29.7 (U1, K8s 1.30) → 3.30.7 (U2, 1.31) → 3.31.7 (U3, 1.32) → 3.32.2 (U4, 1.34). 3.31부터 이미지 quay.io |
| containerd | 2.2.1 | 2.2.1 | 변경 없음 |
| kubectl (ota-host) | v1.30.14 | v1.36.5 | 단계마다 교체(±1 skew), `~/.local/bin/kubectl-v*` 보존 |
| Helm (ota-host) | v3.18.6 | v3.22.0 | STEP 5 |
| Argo CD | v3.5.5 | v3.5.5 | 변경 없음. 1.36은 Argo CD 3.5 공식 테스트 범위(v1.33~v1.36) 안 |
| kubeadm-config | v1beta3 | v1beta4 | kubeadm이 H1에서 자동 전환 |

Calico 공식 테스트 범위: 3.28 = 1.27~1.30, 3.29 = 1.29~1.32, 3.30 = 1.31~1.35, 3.31 = 1.32~1.35, 3.32 = 1.34~1.36. 모든 단계의 사전 관문이 이 범위를 확인했다(`k8s/calico/versions.md`).

## 3. 사전 상태

| 항목 | 결과 | 근거 |
| --- | --- | --- |
| DAY7 종료 상태 | Production C 2/2, Staging·Agent 0 | `01-day7-end*` |
| 전체 상태 | PASS (deprecated API 요청 없음, PDB는 calico-kube-controllers maxUnavailable 1뿐) | `02-state-before` |
| Calico 설치본 = 3.28.2 원본 manifest | A·B 모두 SAME | `03-calico-diff-a/b` |
| 복구 지점 RU | 콜드 백업 `RU-20261014-1957`, 해시 검산 OK | `04`~`07` |
| 재기동 후 상태 | PASS (데모 Pod 재생성 후) | `08-*` |
| 기준선 U-P0 | 재기동 +3213초 측정(연속 수집 끈 상태) | measure `20261014-205404/210022-upg-P0a/b` |

U1-A(Calico 3.29.7)를 U-P0·연속 수집 시작 전에 실행했다(순서 이탈, 타임라인 NOTE). U-P0는 그 뒤에 쟀으므로 A의 calico-node 재시작이 기준선에 포함돼 있다.

## 4. 단계별 결과

소요 = 스크립트 시작 → 끝(사후 관문 포함). Ansible = Ansible 구간만. B http = B Service 요청 fail/total (0.5초 간격).

| 단계 | 내용 | A 결과 · Ansible/전체 | B 결과 · Ansible/전체 | B http | 근거 |
| --- | --- | --- | --- | --- | --- |
| U1 | Calico 3.29.7 (K8s 1.30) | PASS · 173s | PASS · 313s | 0 / 945 | `10`·`11` |
| H1 1차 | 1.31.14 | STOP (설치 전, rc=141) | STOP (설치 전) | 0 / 442 | `13`·`14` |
| H1 | 1.31.14 (재실행) | PASS · 311 / 423s | PASS · 430 / 441s | 0 / 1,446 | `13-*-r2`·`14-*-r2` |
| U2 | Calico 3.30.7 (K8s 1.31) | PASS · 162s | PASS · 282s | 0 / 614 | `20`·`21` |
| H2 | 1.32.13 | PASS · 257 / 378s | PASS · 322 / 333s | 0 / 723 | `22`~`24` |
| U3 | Calico 3.31.7 (K8s 1.32) | PASS · 179s | PASS · 303s | 0 / 603 | `30`·`31` |
| H3 | 1.33.13 | PASS · 281 / 403s | PASS · 405 / 417s | 0 / 834 | `32`~`34` |
| H4 | 1.34.12 (etcd 3.6) | PASS · 350 / 471s | PASS · 453 / 464s | 0 / 941 | `42`~`44` |
| U4 | Calico 3.32.2 (K8s 1.34) | PASS · 173s | PASS · 287s | 0 / 598 | `50`·`51` |
| H5 | 1.35.9 | PASS · 380 / 502s | PASS · 475 / 487s | 0 / 966 | `52`~`54` |
| H6 | 1.36.5 | PASS · 310 / 422s | PASS · 455 / 466s | 0 / 914 | `60`~`64` |

- 전체 창: U1 시작 20:13Z → H6 끝 23:45Z (3시간 32분). 이 중 약 40분은 U-P0 재측정, 약 7분은 H1 1차 실패·수정이다.
- Calico 단계는 A 162~179초, B 282~313초. Kubernetes 단계는 A 378~502초, B 333~487초.
- 모든 Calico 단계에서 IPPool 설정이 적용 전후 같았다(`*-ippools-before/after`).
- 모든 Kubernetes 단계의 사전 관문에서 `CHECK deprecated PASS`(제거 예정 API 요청 없음). 1.32의 `flowcontrol v1beta3` 제거 영향 없음.
- B drain 중 데모 Pod 1개가 잠깐 Pending(topology spread DoNotSchedule) → 다른 Worker의 Pod가 응답해 실패 요청 없음.
- T5 pods watch는 B 제어부 재시작 때마다 끊겼다. H1은 끊긴 뒤 미수집, H2부터 재연결 루프로 단계마다 6~10회 재연결.
- cp-a Guest MemAvailable 최저 401 MiB(U4-A, 22:55:58Z). 중단 기준 300 MiB 위.

## 5. 1.34·1.35 변경 확인

| 시점 | `/var/lib/kubelet/kubeadm-flags.env` | instance-config.yaml | 근거 |
| --- | --- | --- | --- |
| 이전 (1.30~1.33) | `--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --pod-infra-container-image=registry.k8s.io/pause:3.9` | 없음 | `02`, `4x` before |
| H4 (1.34) 후 | `--pod-infra-container-image=registry.k8s.io/pause:3.9` | 생김 (NodeLocalCRISocket) | `43`·`44` after |
| H5 (1.35) 후 | `""` (빈 값) | 있음 | `53`·`54` after |

- H5 사전 관문에서 5 Node 모두 `cgroup=cgroup2fs`.
- 'Flag removed in kubelet 1.35 must be gone' 확인이 kubelet 재시작 전에 5 Node 모두 `ok`.
- 인증서: kubeadm upgrade가 매 단계 갱신. 만료 357일 → 364일(H6 시각 기준). CA는 그대로(2036-10-04) → Argo CD의 B 연결(SA 토큰·CA) 유지.

## 6. 기능 확인

| 항목 | 결과 | 근거 |
| --- | --- | --- |
| 전체 상태 | PASS (1.36.5, etcd 3.6.8, Calico 3.32.2, Pod 문제 0) | `80-state-after` |
| Argo CD | server v3.5.5, `ota-b` Successful, 두 앱 Synced·Healthy | `81-argocd` |
| Staging 왕복 | C 1개 기동 → Sync PASS → 확인 PASS → 0으로 중지 → PASS, Production 확인 PASS | `82`~`86` |
| CI 1회 | `day6-ci` #9 SUCCESS, tag `3dcc09a88986-day6-ci-9`, test·scan exit 0, built = pushed `sha256:df1dd136…4540`, Registry 200 | `88-ci-run/` |
| CI Agent | Pending → Running 1초, Running 48초, Terminating 30초(DAY6과 같은 SIGTERM 무시), 종료 후 Agent·Staging 0 | `87`, `88-ci-after` |
| Helm 3.22.0 | Jenkins·Argo CD Release 모두 `deployed` 조회 | `71` |

새 이미지는 검증용이며 승격하지 않았다.

## 7. 재기동과 자원 비교

### 7-1. 재기동

| 항목 | 값 | 근거 |
| --- | --- | --- |
| VM 정지 | 00:14:26 → 00:18:04Z (218초) | `90-vm-stop` |
| VM 정지 중 Host | MemAvailable 30,749 MiB, Swap used 82 MiB (STEP 5-1 때 3,847) | `90-host-mem-vms-stopped` |
| 기동 → 5 Node Ready | 49초 (API ready +27초) | `91-vm-start` |
| 재기동 후 상태 | 1차 FAIL(ota-demo-production `Progressing`, 재기동 4분 뒤) → 데모 Pod 재생성 후 PASS | `92-*-1st`, `92` |
| Production | 이전 종료 `Unknown` 이력만으로 FAIL → Pod 2개 하나씩 재생성 → PASS | `93-*` |
| Argo CD B 버전 표시 | `ota-b` v1.36.5 `Successful` (재기동 후 클러스터 캐시 갱신) | `96` |

### 7-2. 비교표

U-P0b·U-P1b는 각 측정의 SUMMARY에서 옮겼다. 둘 다 VM 기동 완료 +3213초, 연속 수집·port-forward 없음. DAY7 P2-final은 재기동 전(KSM 4.4 GiB 병합 상태)이라 참고 열이다.

| 계층 | 항목 | DAY7 P2-final (참고) | U-P0b (1.30.14) | U-P1b (1.36.5) | U-P1 − U-P0 |
| --- | --- | --- | --- | --- | --- |
| Host | MemAvailable (MiB) | 19,747.3 | 18,105.0 | 17,743.9 | -361.1 |
| Host | RAM Used (MiB) | 12,062.8 | 13,705.1 | 14,066.2 | +361.1 |
| Host | KSM 절약량 (MiB) | 4,397.6 | -108.6 | -114.8 | -6.2 |
| Host | KSM 보정 사용량 (MiB) | 16,460.4 | 13,596.4 | 13,951.4 | +355.0 |
| Host | Swap Used (MiB) | 2.8 | 2.8 | 80.8 | +78.0 |
| Host | Swap si/so 평균 | 0.0/0.0 | 0.0/0.0 | 0.2/0.0 |  |
| Host | CPU busy (%) | 8.2 | 9.2 | 8.9 | -0.3 |
| Host | Guest CPU gu (%) | 5.9 | 6.8 | 6.3 | -0.5 |
| VM | Total QEMU RSS (MiB) | 15,245.1 | 12,527.6 | 12,908.7 | +381.1 |
| VM | Total QEMU PSS (MiB) | 10,601.0 | 12,438.9 | 12,820.7 | +381.8 |
| VM | cp-a RSS (MiB) | 2,100.7 | 2,088.2 | 2,101.4 | +13.2 |
| VM | cp-b RSS (MiB) | 2,906.4 | 2,710.5 | 2,969.6 | +259.1 |
| VM | worker-a1 RSS (MiB) | 6,201.9 | 3,960.3 | 3,247.3 | -713.0 |
| VM | worker-b1 RSS (MiB) | 2,004.3 | 1,889.0 | 2,436.3 | +547.3 |
| VM | worker-b2 RSS (MiB) | 2,030.5 | 1,875.2 | 2,150.8 | +275.6 |
| Guest | cp-a MemAvailable (MiB) | 719.3 | 710.0 | 776.3 | +66.3 |
| Guest | cp-b MemAvailable (MiB) | 1,800.3 | 1,840.1 | 1,860.2 | +20.2 |
| Guest | worker-a1 MemAvailable (MiB) | 4,033.4 | 4,468.2 | 4,641.7 | +173.5 |
| Guest | worker-b1 MemAvailable (MiB) | 6,246.2 | 6,275.4 | 6,258.3 | -17.1 |
| Guest | worker-b2 MemAvailable (MiB) | 6,237.4 | 6,281.5 | 6,338.7 | +57.2 |
| Guest | cp-a Root Used | 4.9G (18%) | 5.8G (21%) | 14G (50%) |  |
| Guest | cp-b Root Used | 4.8G (18%) | 4.8G (18%) | 14G (48%) |  |
| Guest | worker-a1 Root Used | 9.7G (17%) | 11G (19%) | 15G (26%) |  |
| Guest | worker-b1 Root Used | 3.8G (8%) | 3.8G (8%) | 8.8G (19%) |  |
| Guest | worker-b2 Root Used | 3.8G (5%) | 3.8G (5%) | 8.8G (12%) |  |
| K8s | cp-a memory requests / limits | 240Mi / 340Mi | 240Mi / 340Mi | 240Mi / 340Mi |  |
| K8s | cp-b memory requests / limits | 240Mi / 340Mi | 240Mi / 340Mi | 170Mi / 170Mi |  |
| K8s | worker-a1 memory requests / limits | 1696Mi / 4736Mi | 1696Mi / 4736Mi | 1696Mi / 4736Mi |  |
| K8s | worker-b1 memory requests / limits | 64Mi / 128Mi | 64Mi / 128Mi | 134Mi / 298Mi |  |
| K8s | worker-b2 memory requests / limits | 64Mi / 128Mi | 64Mi / 128Mi | 64Mi / 128Mi |  |
| 측정 | 수집 실패 | 0 | 0 | 0 |  |
| K8s | cp-a kube-apiserver MEM (MB, crictl) | — | 572.8 | 541.9 | -30.9 |
| K8s | cp-a etcd MEM (MB, crictl) | — | 75.3 | 68.1 | -7.2 |
| K8s | cp-a kube-controller-manager MEM (MB, crictl) | — | 73.1 | 76.2 | +3.1 |
| K8s | cp-a kube-scheduler MEM (MB, crictl) | — | 32.6 | 39.3 | +6.7 |
| K8s | cp-a calico-node MEM (MB, crictl) | — | 138.8 | 97.1 | -41.7 |
| K8s | cp-a coredns MEM (MB, crictl) | — | 57.2 | 54.1 | -3.2 |
| K8s | cp-a kube-proxy MEM (MB, crictl) | — | 21.4 | 27.3 | +5.9 |
| K8s | cp-b kube-apiserver MEM (MB, crictl) | — | 357.6 | 444.1 | +86.5 |
| K8s | cp-b etcd MEM (MB, crictl) | — | 89.9 | 97.0 | +7.0 |
| K8s | cp-b kube-controller-manager MEM (MB, crictl) | — | 126.9 | 120.4 | -6.5 |
| K8s | cp-b kube-scheduler MEM (MB, crictl) | — | 67.5 | 66.8 | -0.8 |
| K8s | cp-b calico-node MEM (MB, crictl) | — | 150.6 | 101.5 | -49.1 |
| K8s | cp-b coredns MEM (MB, crictl) | — | 73.4 | 68.7 | -4.8 |
| K8s | cp-b kube-proxy MEM (MB, crictl) | — | 64.8 | 57.8 | -7.0 |

측정 시점과 오차:

- 측정 시각: U-P0a 20:54:04Z(기동 완료 +3,219초), U-P0b 21:00:22Z / U-P1a 01:24:36Z(+3,442초), U-P1b 01:30:40Z. U-P1이 계획(+3,213초)보다 약 4분 늦었다. 두 시점의 KSM 절약량이 −109 / −115 MiB로 같아 KSM 조건 차이는 무시할 수준이다.
- 표본 간 차(a·b): Host MemAvailable 40.5(P0) / 56.0(P1) MiB, Total RSS 23.1 / 33.3 MiB, Guest MemAvailable 최대 40.0 / 20.3 MiB. 이보다 작은 차이는 구분하지 않는다.
- U-P0에는 U1-A(Calico 3.29.7, A만)가 포함돼 있다(3장).

해석:

1. **게스트 안의 상시 사용량은 늘지 않았다.** Guest MemAvailable은 5대 모두 −17 ~ +174 MiB로, 합계 +300 MiB(더 여유)다. 제어부 컨테이너도 cp-a kube-apiserver −31 MB, calico-node −42 ~ −49 MB(3.28 → 3.32)로 비슷하거나 작다. cp-b kube-apiserver만 +87 MB.
2. **Host 지표는 −361 MiB(MemAvailable), RSS +381 MiB.** RSS 증가는 B 노드(cp-b +259, worker-b1 +547, worker-b2 +276)다. 같은 노드의 Guest MemAvailable은 거의 그대로라, 상시 사용량이 아니라 재기동 후 이미지·캐시를 읽으며 게스트가 건드린 페이지로 본다(D11: 컴포넌트 비용은 게스트 지표로 판단). worker-a1은 RSS −713 MiB, Guest +174 MiB.
3. **B CoreDNS 1개가 worker-b1로 옮겨졌다.** H6-B의 cp-b drain 때 재배치된 뒤 그대로다. 그래서 cp-b requests 240/340 → 170/170Mi, worker-b1 64/128 → 134/298Mi. 클러스터 합계는 같다.
4. **Swap 80.8 MiB, si 평균 0.2.** VM 정지 상태에서도 82 MiB였으므로 VM이 아닌 Host 프로세스 페이지가 남은 것이다. 재기동 후 새 swap-out은 없다(so 0.0).
5. **디스크가 가장 크게 바뀌었다.** Control Plane Root 21% → 48~50%, Worker 8~19% → 12~26%. 이미지 누적과 kubeadm 백업이다(8장).

U-P1b가 DAY8의 P0 기준선이다. DAY8 비교에서는 B CoreDNS 배치(3번)와 디스크 상태(5번)를 같은 조건으로 둔다.

### 7-3. 업그레이드 구간 (연속 수집 `upg-hops2`, 21:02~23:46Z)

| 지표 | 값 |
| --- | --- |
| Host MemAvailable 최저 | 6,653.9 MiB (23:19:28Z, H5-B) |
| Host swap | 3 MiB → 2,872 (H5 끝) → 3,847 MiB (STEP 5-1). si 합계 약 860 MiB, so 합계 약 4.4 GiB. 21:30Z(H1-B)부터 증가 |
| Host CPU busy 최고 / gu 최고 | 54% / 37% (21:23:35Z, H1-A) |
| VM RSS 최고 | cp-a 2,099.6 · cp-b 3,121.4 · worker-a1 6,196.8 · worker-b1 6,845.1 · worker-b2 6,201.6 MiB |
| Guest MemAvailable 최저 | cp-a 401.3 · cp-b 1,510.5 · worker-a1 4,141.0 · worker-b1 5,872.0 · worker-b2 5,876.2 MiB |
| Guest PSI mem some avg10 최고 | cp-a 0.85 · cp-b 0.44 · worker 0.0 |

## 8. Issue · 결정

| 시점 | 증상 | 원인 | 조치 | 상태 |
| --- | --- | --- | --- | --- |
| H1 1차 | A·B 모두 `Find the package revision`에서 rc=141, 설치 전 중단 | `awk`가 첫 결과에서 끝나 `apt-cache`가 SIGPIPE → `pipefail`이 실패로 판정 | `tasks/k8s-packages.yml` 수정(`f718233`), `-r2`로 재실행 | 해결 |
| STEP 2 | `ksm-wait`가 안정되지 않음 | KSM 스캔 약 2 MiB/s | 안정 대기 대신 재기동 +고정 시간 측정 | 해결 |
| STEP 2 | U-P0 1차가 연속 수집 중 측정 | 순서 착오 | 수집을 끄고 +3213초에 재측정, U-P1도 +3213초 | 해결 |
| STEP 2 | U1-A를 U-P0·STEP 3 전에 실행 | 순서 이탈 | 타임라인 NOTE, U-P0에 U1-A 포함으로 표시 | 기록 |
| 재기동 후 | demo-check FAIL (restarts=1, 이전 종료 Unknown) | 노드 종료로 컨테이너 강제 종료 | 이력 기록 후 Pod 하나씩 재생성 | 기록 |
| H1-B | T5 pods watch가 제어부 재시작 때 종료 | `kubectl get -w`는 재연결하지 않음 | H2부터 재연결 루프 | 해결 |
| 업그레이드 중 | Host swap 3 → 3,847 MiB, si 발생 | 콜드 재기동 뒤 KSM 미병합 상태에서 단계마다 이미지 Pull·drain으로 VM이 새 메모리를 건드려 RSS가 할당 상한 근처까지 증가. 커널이 오래 안 쓴 VM 페이지를 swap으로 보냄 | 서비스 영향 없음(fail 0). VM 정지로 82 MiB 복귀 확인 | **열림** (issues.md) |
| 업그레이드 후 | Control Plane 디스크 18% → 50%, 이미지 수 11 → 53~57 | 단계마다 새 이미지가 쌓이고 kubelet 이미지 GC는 85%부터 동작. kubeadm 백업 `/etc/kubernetes/tmp` 2.2~2.3 GiB | 지우지 않음. 정리 방법은 별도 결정 | **열림** (issues.md) |
| STEP 6-2 | `argocd cluster list`의 `ota-b` VERSION v1.35.9 | 클러스터 캐시의 서버 버전(재동기화 12시간). 컨트롤러가 H6-A drain 때 재시작, 그때 B는 1.35.9 | 재기동 후 `96`에서 확인 | 해결 |
| STEP 7 | 재기동 4분 뒤 `ota-demo-production` Progressing | Argo CD 재시작 직후 재계산 전 | 데모 Pod 재생성 후 Healthy, 92 재실행 PASS | 기록 |

결정: D12 (`docs/decisions.md`).

## 9. 증거 파일

| 범위 | 파일 |
| --- | --- |
| 준비·사전 점검 | `00-timeline`, `00-upgrade-files.sha256`, `01-day7-end*`, `02-state-before`, `03-calico-diff-a/b` |
| RU·재기동·U-P0 | `04-backup-space`, `05-vm-stop`, `06-backup-RU*`, `07-vm-start`, `08-*`, `09-crictl-stats-P0`, `09-ksm-wait-P0`, measure `*-upg-P0a/b` (비교에는 `205404`·`210022` 세트) |
| U1·H1 | `10`·`11` (`-ippools-*`, `-demo`, `-http`), `12-kubectl-1.31.14`, `13`·`14` (1차), `13-*-r2`·`14-*-r2` |
| U2·H2 | `20`·`21`, `22-kubectl-1.32.13`, `23`, `24` (`-http`, `-pods-watch`, `-demo`) |
| U3·H3·H4 | `30`·`31`, `32`~`34`, `42`~`44` |
| U4·H5·H6 | `50`·`51`, `52`~`54`, `60-host-mem-before-h6`, `62`~`64` |
| 연속 수집 | measure `20261014-201215/201237-upg-hops*` (20:12~20:47Z), `20261014-210214/210226-upg-hops2*` (21:02~23:46Z), `70-sample-summary` |
| 도구·저장소 | `71-helm-3.22.0`, 커밋 `9ea590d` (04-base-config 1.36, versions.md) |
| 기능 확인 | `80-state-after`, `81-argocd`, `82`~`86`, `87-ci-pods-watch`, `88-ci-run/`, `88-ci-after` |
| 재기동·U-P1 | `90-vm-stop`, `90-host-mem-vms-stopped`, `91-vm-start`, `92-*`, `93-*`, `95-crictl-stats-P1`, `96-argocd-cluster-after-restart`, measure `*-upg-P1a/b` |
