# k8s/platform/local-path-b/versions.md — Cluster B local-path-provisioner (DAY8)

| 항목 | 값 | 출처 · 확인값 |
| --- | --- | --- |
| 버전 | v0.0.37 (A와 같은 버전, 2026-10-15 기준 최신 태그) | DAY5 A 설치값, rancher/local-path-provisioner 태그 |
| manifest | `local-path-storage.yaml` = 원본 그대로 (수정 없음) | https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.37/deploy/local-path-storage.yaml |
| sha256 | `9781b39c24f3f651bd6d6e41b561e04e4904bbdb6d4f8c7a6009df3a702dcd65` | DAY8 작성 시 원본에서 계산. STEP 2에서 다시 받아 대조 |
| Provisioner 이미지 | docker.io/rancher/local-path-provisioner:v0.0.37 | 실제 imageID `sha256:e757967a5ec338f6a9b371c5a9688bedaa8c3578ea3dd4db329ea0084be0a86f` (docs/evidence/day8/11-local-path-b-install.txt) |
| helper 이미지 | docker.io/library/busybox (태그 없음 = latest, 원본 그대로) | DAY8 시험 때 실제 digest `sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e` (docs/evidence/day8/12-b-storage-test.txt). A와 같게 두려고 고정하지 않았다 |
| StorageClass | `local-path`, provisioner `rancher.io/local-path`, reclaimPolicy Delete, WaitForFirstConsumer | manifest |
| 데이터 경로 | 각 Node `/opt/local-path-provisioner` (DEFAULT_PATH_FOR_NON_LISTED_NODES) | manifest ConfigMap |
| 권한 | ClusterRole: nodes·PVC·configmaps·pods 조회, PV 생성·삭제, events 생성. Role(local-path-storage): pods 생성·삭제(helper) | manifest |
| 배치 | Provisioner Deployment에 nodeSelector 없음 → cp-b taint 때문에 worker-b1/b2 중 하나 (DAY8: worker-b2) | manifest, docs/evidence/day8/11-local-path-b-install.txt |

제약: PVC 크기는 디스크 사용량의 상한이 아니다(hostPath). 데이터는 PV가 만들어진 Node 하나에만 있고, Node 장애 시 다른 Node로 옮겨지지 않는다.
