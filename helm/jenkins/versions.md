# helm/jenkins/versions.md
| 구성요소 | 버전 / 태그 | digest (STEP 8·12에서 기록) |
| --- | --- | --- |
| Kubernetes (A/B) | v1.36.5 | 2026-10 업그레이드 (이전 v1.30.14). docs/evidence/k8s-upgrade/ |
| kubectl / Helm (ota-host) | v1.36.5 / v3.22.0 | docs/evidence/k8s-upgrade/62-kubectl-1.36.5.txt, 71-helm-3.22.0.txt |
| Jenkins Chart | 5.9.68 (sha256: 07-chart-sha256.txt) | — |
| Jenkins Controller | jenkins/jenkins:2.580.1-jdk25 | |
| Config reload sidecar | kiwigrid/k8s-sidecar:2.11.2 | |
| Agent (jnlp) | jenkins/inbound-agent:3385.vf1123fb_515da_-1-jdk25 | |
| 플러그인 (Chart 기본) | kubernetes:4557.ve746270f672f, workflow-aggregator:608.v67378e9d3db_1, git:5.10.1, configuration-as-code:2133.ve570217cdb_cd | 전체 목록: 09-plugins-installed.txt |
| 플러그인 (추가) | lockable-resources:(STEP 8에서 기록) | |
| BuildKit | (STEP 12) | |
| Trivy | (STEP 12, 0.69.4~0.69.6 제외) | |
| skopeo | (STEP 12) | |
| python base | 3.12-alpine | |

## STEP 12-3 도구 이미지 (2026-10-14)
- BuildKit v0.34.0 (rootless·rootful), Trivy 0.75.0 (0.69.4~0.69.6 아님), skopeo v1.22.3 (quay stable 최신. GitHub 최신 v1.24.1은 quay 미제공)
- docker.io/moby/buildkit:v0.34.0-rootless@sha256:65eca3c01cd1180c8f64565c4e3c5983af5145818b0e6fa863385d099eb73855
- docker.io/moby/buildkit:v0.34.0@sha256:b059f8d7226d0b326bc871af489a5dddf65e36af4d20d14251b072974d9ee87c
- docker.io/aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa
- quay.io/skopeo/stable:v1.22.3@sha256:22ea3c3baf639147b07fb9f2ea28a6308edf7909e919d91a5d296af0121d7ed9
- docker.io/library/python:3.12-alpine@sha256:1b668429b3511ab407d8e00648891631b0b1a4d7e15e3ca70f38ab5b91ad4ab4
