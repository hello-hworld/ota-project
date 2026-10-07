## DAY3 Result

VM 0대 상태에서 Host RAM 사용량은 975MiB였으며,
VM 5대 실행 후 약 4.4GiB로 증가하였다.

VM 5대 실행에 따라 약 3.4GiB의 추가 Host Memory가 사용되었으나,
약 26GiB의 Available Memory가 유지되었고 Swap은 사용되지 않았다.

CPU는 측정 시점 기준 Idle 100%, I/O Wait 0%였으며,
Load Average 1m 역시 0.09 수준으로 낮았다.

VM 전용 Storage는 5대 생성 후 약 5.7GiB가 사용되었다.
각 VM의 가상 Disk 합계보다 실제 물리 사용량이 훨씬 적어
qcow2 thin provisioning 특성도 확인할 수 있었다.

따라서 현재 VM 5대만 실행한 Idle 상태에서는
Physical Host가 충분한 자원 여유를 유지하고 있다고 판단하였다.

단, Kubernetes 및 CI/CD/Monitoring workload가 아직 올라가지 않은
Baseline 상태이므로 이후 단계에서 동일 지표를 계속 비교한다.