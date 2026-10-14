# helm/argocd/versions.md — DAY7 Argo CD 고정 버전

| 구성요소 | 버전 | 출처 · 확인값 |
| --- | --- | --- |
| Kubernetes A/B | v1.30.14 | Argo CD 3.5 공식 테스트 범위(v1.33~v1.36) 밖 → 이 프로젝트의 실습 검증 조건 |
| kubectl / Helm (ota-host) | v1.30.14 / v3.18.6 | docs/evidence/day6/00-tools.txt |
| Argo CD Helm Chart | argo-cd 10.10.3 (appVersion v3.5.5, kubeVersion `>=1.25.0-0`) | https://argoproj.github.io/argo-helm · 파일 sha256 = index.yaml digest `fa03517a9f8165e2f4b3b6755a7871af9dd6a36aeddc8ad948be5d45f56bf6b8` (docs/evidence/day7/02-chart-sha256.txt) |
| Argo CD 서버 이미지 | quay.io/argoproj/argocd:v3.5.5 | 실제 digest: docs/evidence/day7/06-image-prepull.txt |
| Redis (Argo CD 내부 캐시) | ecr-public.aws.com/docker/library/redis:8.6.4-alpine | Chart 기본값. 실제 digest: 06-image-prepull.txt |
| Argo CD CLI | v3.5.5 linux-amd64 | cli_checksums.txt sha256 `c3ddfa606fc3e89ab14f55bda6600b207c355b028f8eaabe69b817a4c4621aba` (03-argocd-cli.txt) |
| 데모 이미지 G | 192.168.56.21:32000/day6/demo@sha256:2db15224…0478 | DAY6 day6-ci #2, version 2f99fb73f694-day6-ci-2 |
| 데모 이미지 C | 192.168.56.21:32000/day6/demo@sha256:6068b90a…7b8e | DAY6 day6-ci #3, version 50615d6ab9d2-day6-ci-3 |

설치 구성(values.yaml): Controller·Server·Repo Server·Redis 각 1개, Redis HA·Dex·Notifications 끔,
ApplicationSet은 이 Chart에 enabled 키가 없어 `applicationSet.replicas: 0`으로 끔(Deployment·Service·CRD는 남음).
