# DAY9 후속 판단 기록 — STEP 7 자동 검사·P2 검토 반영

기준: 2026-10-15 / run01 / 소스 `0ca578b13643939299769fff1ff9904aacfa8003`.
기존 DAY8 값은 역사적 참고로 보존하고 DAY9 결과를 분리했다. 최종 자동 검사·P2는 PASS이며 대시보드 직접 확인은 일부 수행이다. 보고서·이번 run 증거의 Git 반영은 본 기록 작성 후 별도로 확인한다.

| 항목 | DAY8 / 시작 관측 | DAY9 확인 결과 | 상태 / 다음 조치 |
|---|---|---|---|
| Helm lint | 3개 미실행 | STEP 7 고정 chart + 현재 values로 A/B Prometheus·Grafana 3개 모두 failed 0 | 보완 완료 |
| 기존 A/B·Host 화면 | DAY8 API PASS, 직접 화면 기록 없음 | 사용자 응답: 일부만 확인함. 확인한 화면의 범위와 기존 검사 파일 확인 대기 | 일부 확인; 나머지 화면 확인은 이월 |
| TSDB | 첫 검사 당시 블록 없음 | A/B 각각 3 blocks; /data A 111264KiB, B 115912KiB; 48h / 3GiB 플래그 확인 | 현재 저장 확인 완료; 실제 48h 삭제 동작은 이월 |
| Grafana | request 128Mi, limit 384Mi; DAY9 384Mi cgroup OOM | request 256Mi / limit 768Mi 적용; STEP 4 15분 최대 263.5MiB; CI 후 restart 0 | 보정 적용 완료; request 적정성 후속 검토 |
| worker-a1 예산 | DAY8 requests 2320Mi / limits 6176Mi | 현재 2448Mi / 6560Mi; CI 추가 시 계산상 3344Mi / 10144Mi; CI 포함 최소 여유 3699.9MiB | 과예약 기록; 반복 실측 후 조정 |
| Host metrics | 미연결 | 서비스 active, Target UP, 물리 hostname·최신 샘플·Prometheus를 통한 모든 Host 패널식 PASS | 수집 검증 완료; Grafana API 기존 증거 추가 검토 |
| CI memory.events | Trivy peak 1Gi 근접, events 없음 | #11에서 5개 컨테이너 events 수집, max/oom/oom_kill/oom_group_kill 모두 0; Trivy peak 35.3MiB | 수집 보완 완료; 높은 peak 경로 해결로 확대하지 않음 |
| CI 종료 | 약 30초 종료 지연 | 이번 종료 정리 약 31초, 이후 Agent 0 | 개선 이월 |
| jnlp CPU | throttle 관측 | 이번 299회, 누적 throttled_usec 약 56.1초 | CPU 변경 없이 기록; 후속 검토 |
| Production 정책 | Namespace 초기 정책 없음 | Quota·LimitRange 적용; 기본값 주입/초과 요청 거부 PASS; 기존 C 2개 유지 | 적용·검증 완료 |
| Prometheus RBAC | 전역 ConfigMap 조회 | 권한 축소 변경 없음; preflight의 nodes/proxy 조회 문법 보정 | ConfigMap 범위 축소는 이월 |
| kubelet TLS | A안, 서버 인증서 검증 생략 | D13 유지 | 인증서 교체·검증은 별도 작업 |
| Lifecycle API | 내부 NodePort 노출 | 접근 제어 변경 없음 | 별도 설계 이월 |
| HTTP 부하 비교 | 비교 실험 없음 | 정상 CI 1회 회귀만 수행 | 부하 비교 미수행으로 기록 |
| 최종 종료 | — | Production C 2개·HTTP 10/10; Argo 2개 Synced/Healthy; CI/Staging Pod 0; Node 5개 Ready·Pressure False; 관측 Pod restart 0 | 자동 검사 PASS |
| P2 | 미수행 | 수집 실패 0·CPU 샘플 12; cp-a 여유 696.0MiB; Host si/so 0 / 0; P1→P2 PSS -39.8MiB | 측정 완료; 큰 메모리 잔류 증가 미관찰 |
| 최종 budget | STEP 4 자료 확보 | resource-budget-1792066310.json 저장 PASS; P2의 Node 예약량은 STEP 4와 동일 | 최종 JSON 내부 최근 15분 수치는 추가 검토 |
| Git 게시 | 소스 0ca578b Push 완료 | 이번 보고서와 run01 증거 Commit/Push는 본 기록 작성 시점 대기 | 원격 반영 후 확인 |

이 기록에 인증정보·Secret 원문·API token·kubeconfig를 넣지 않는다.
