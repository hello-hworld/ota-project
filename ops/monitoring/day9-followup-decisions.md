# DAY9 follow-up decision record — fill after execution

Baseline: GitHub aa907d558d8fc2d8db654bf88764ae583a274783, 2026-10-15.
This file is a plan, not an execution result.

| Item | DAY8 observation | DAY9 action | Execution result / evidence |
|---|---|---|---|
| Helm lint | Three commands were not executed | Re-run all three with pinned packages | Pending |
| Dashboard | API passed, visual record absent | Check both datasources, record six groups | Pending |
| TSDB | No blocks at DAY8 check | Record blocks and directory size; 48h deletion remains pending | Pending |
| Grafana request | About 199MiB used, request 128Mi | Record latest maximum; consider 256Mi request in a separate values change | Pending |
| worker-a1 | Memory limits 106%, CI 168%; CPU CI 226% | Record reservation and simultaneous usage; do not lower all limits automatically | Pending |
| Prometheus RBAC | Global ConfigMap read is present | Record rules; custom ClusterRole is a separate change | Deferred |
| kubelet TLS | Option (a), two jobs skip server verification | Preserve D13; certificate replacement is separate | Deferred |
| Host metrics | Not connected to Prometheus/Grafana | Add one physical-host job/dashboard | Pending |
| CI memory | Trivy peak near 1Gi, events missing | Add read-only memory.events collection; retain existing limits | Pending |
| CI termination / CPU | 30s termination, jnlp throttling | Observe this run; change separately after evidence | Pending |
| Lifecycle API | Internal NodePort exposes lifecycle endpoints | Preserve recorded exposure; evaluate configuration separately | Deferred |

No credential values belong in this record.
