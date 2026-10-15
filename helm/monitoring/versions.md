# helm/monitoring/versions.md — DAY8 관측 구성 고정 버전

| 구성요소 | 버전 | 출처 · 확인값 |
| --- | --- | --- |
| Kubernetes A/B | v1.36.5 | 2026-10 업그레이드. docs/baseline/k8s-upgrade.md |
| kubectl / Helm (ota-host) | v1.36.5 / v3.22.0 | docs/evidence/k8s-upgrade/62-kubectl-1.36.5.txt, 71-helm-3.22.0.txt |
| Prometheus Chart | prometheus 29.37.0 (appVersion v3.15.0, kubeVersion `>=1.19.0-0`) | https://prometheus-community.github.io/helm-charts · 파일 sha256 = index.yaml digest `df07dce99f49ea300c5bb8dadb167a09141bb7dbdc6609727157677434e4fbe5` (docs/evidence/day8/20-chart-sha256.txt) |
| └ 하위 Chart | kube-state-metrics 8.6.0 (app 2.20.0, client-go 1.36), prometheus-node-exporter 4.60.0 (app 1.12.1) | Chart.lock, 패키지 안 charts/. alertmanager 2.1.1·pushgateway 3.9.1은 끔 |
| Grafana Chart | grafana 13.6.0 (appVersion 13.2.4, kubeVersion `^1.25.0-0`) | https://grafana-community.github.io/helm-charts (Grafana 공식 Helm 문서가 안내하는 저장소) · 파일 sha256 = index.yaml digest `228fbe6e28f1eabd634ec7b7baa71665477a1adc8d37b80bef59d60ca251a7d6` |
| Prometheus | quay.io/prometheus/prometheus:v3.15.0 | 실제 imageID `sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e` (A·B 같음, docs/evidence/day8/31-prom-a-state.txt, 32-prom-b-state.txt) |
| Config reloader | quay.io/prometheus-operator/prometheus-config-reloader:v0.94.1 | `sha256:06b52bd4dbe3ed6dd5905aadaf8b9987d9da4c31d37bb86deaadae68cee2d26b` (〃) |
| kube-state-metrics | registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.20.0 | `sha256:42cfe3723a5f058171c627537fb57a3ea0f26e4380fa18555a95cb1a1b4cfc5b` (〃) |
| node-exporter | quay.io/prometheus/node-exporter:v1.12.1 | `sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0` (〃) |
| Grafana | docker.io/grafana/grafana:13.2.4-distroless | `sha256:ae3d3add290adbe6a88412229f5d76fd7bb82743050881698642d3d62f277e35` (docs/evidence/day8/34-grafana-state.txt). 셸 없음 → 확인은 Grafana API로 |

## 설치 구성

| Release (Namespace monitoring) | 클러스터 | values | 배치 | 저장소 | 접근 |
| --- | --- | --- | --- | --- | --- |
| `prometheus` | A | prometheus-a.yaml | server·KSM: worker-a1(`workload=platform`), node-exporter: 2 Node | PVC 5Gi local-path (worker-a1) | ClusterIP. A의 Grafana가 클러스터 안에서 조회 |
| `prometheus` | B | prometheus-b.yaml | server·KSM: worker-b2(hostname), node-exporter: 3 Node | PVC 5Gi local-path (worker-b2) | NodePort 30909, externalTrafficPolicy Local → `http://192.168.56.32:30909` |
| `grafana` | A | grafana.yaml | worker-a1 | PVC 1Gi local-path (worker-a1) | ClusterIP, ota-host `127.0.0.1:13000` port-forward + SSH 터널 |

- 수집 간격 30초, 보존 48시간·3GB. Alertmanager·Pushgateway·Operator·ServiceMonitor 없음.
- 수집 job: `prometheus`, `kubernetes-nodes`(kubelet), `kubernetes-nodes-cadvisor`, `kubernetes-service-endpoints`(node-exporter·kube-state-metrics·CoreDNS). 나머지 기본 job은 끔(`kubernetes-api-servers` 포함).
- kubelet 두 job은 Chart 기본값대로 `insecure_skip_verify: true`(kubeadm kubelet 서빙 인증서가 클러스터 CA 서명이 아님). 권한은 `nodes/metrics`만. API 서버 프록시 방식은 `nodes/proxy`가 필요해 쓰지 않는다(D13).
- kube-state-metrics collectors에서 secrets·configmaps 등을 뺐다(클러스터 전체 Secret 조회 권한을 만들지 않는다).
- Grafana Data Source: `prometheus-a`(uid 같음, 기본) → `http://prometheus-server.monitoring.svc.cluster.local`, `prometheus-b` → `http://192.168.56.32:30909`. 둘 다 `access: proxy`.
- 대시보드: `dashboards/ota-infra-overview.json` → ConfigMap `monitoring/grafana-dashboards-ota`(kubectl로 생성·갱신) → 파일 프로비저닝(폴더 OTA, UI 저장 불가).
- 관리자 비밀번호: Secret `monitoring/grafana-admin`(설치 전 프롬프트로 생성). 저장소·증거에 없음.
