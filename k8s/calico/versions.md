# k8s/calico/versions.md — Calico manifest 고정 버전 (K8s 1.30 → 1.36 업그레이드)

설치 방식: `calico.yaml` manifest, Kubernetes API datastore, `kube-system` (DAY4 설치. Operator 아님).
업그레이드 방법: Calico 공식 'Upgrading an installation that uses manifests and the Kubernetes API datastore'
→ `kubectl apply --server-side --force-conflicts -f calico-v<버전>.yaml` (`scripts/calico-upgrade.sh`).

| 파일 | 원본 | sha256 | 이미지 | 공식 테스트 범위 (Kubernetes) |
| --- | --- | --- | --- | --- |
| calico-v3.28.2.yaml | projectcalico/calico v3.28.2 manifests/calico.yaml | be59408bf990e96276f631d2f9285c2a0f9802194c0ad1cecdb6d9c52623a1c8 | docker.io/calico/* | 1.27 ~ 1.30 (현재 설치본, 비교 기준) |
| calico-v3.29.7.yaml | v3.29.7 | b200cb3c2c7341717abe98e4acc80a13117bcd2c9c46ad46e8c209c5753f0b2f | docker.io/calico/* | 1.29 ~ 1.32 |
| calico-v3.30.7.yaml | v3.30.7 | ed105288f27c7ba4cae143bcaa3f6425f02d84fa94a4786cc8e3d371412c1a36 | docker.io/calico/* | 1.31 ~ 1.35 |
| calico-v3.31.7.yaml | v3.31.7 | d6d8a489a4ed8e5b8efd8b339047b496ca657b55ee2e3618e791507b0a853e8d | quay.io/calico/* | 1.32 ~ 1.35 |
| calico-v3.32.2.yaml | v3.32.2 | a8c828a06a87c629a282ebbc424895b77f3a030251993e41ea400a743675bb02 | quay.io/calico/* | 1.34 ~ 1.36 (최종) |

- 원본 URL: `https://raw.githubusercontent.com/projectcalico/calico/v<버전>/manifests/calico.yaml`
- 각 minor의 최신 patch(2026-10-14 기준 태그): 3.28.5, 3.29.7, 3.30.7, 3.31.7, 3.32.2, 3.33.0
- 테스트 범위 출처: tigera/docs `calico_versioned_docs/version-<minor>/…/requirements` (3.28~3.30은 삭제 직전 커밋)
- Calico는 minor 하나씩 올린다(3.33 문서는 직전 두 릴리스에서의 업그레이드만 다룬다. 이전 버전 문서는 범위를 적지 않아 보수적으로 하나씩)
- 3.33.0은 1.35~1.37 테스트, 단일 `calico/calico` 이미지로 바뀐 첫 릴리스 → 이번 업그레이드에서는 쓰지 않는다
- 설치본이 3.28.2 manifest와 다르면(`scripts/calico-diff.py`가 DIFF) 같은 수정을 각 파일에 옮기기 전에는 적용하지 않는다
