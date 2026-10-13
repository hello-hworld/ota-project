# helm/jenkins/versions.md
| 구성요소 | 버전 / 태그 | digest (STEP 8·12에서 기록) |
| --- | --- | --- |
| Kubernetes (A/B) | v1.30.14 | — |
| kubectl / Helm (ota-host) | v1.30.14 / v3.18.x | — |
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
