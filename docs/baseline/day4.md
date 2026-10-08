## DAY4 Result

DAY4에서는 동일 Physical Host 위에 Kubernetes Cluster A와
Cluster B를 구축하였다.

초기 Cluster A 구축 과정에서 Pod CIDR이 설계값인
`10.10.0.0/16`이 아니라 `10.0.0.0/16`으로 구성된 문제를 발견하였다.

Node PodCIDR, kube-controller-manager의 cluster-cidr,
Calico IPPool을 확인한 결과 Kubernetes 초기화 단계부터
잘못된 CIDR이 적용된 것을 확인하였다.

Cluster B는 정상 상태였으므로 변경하지 않고,
Cluster A의 cp-a와 worker-a1만 kubeadm reset 후
`--pod-network-cidr=10.10.0.0/16`으로 재구축하였다.

재구축 후 Cluster A의 Pod가 `10.10.x.x` 대역을 할당받고
cp-a와 worker-a1이 모두 Ready 상태임을 확인하였다.

최종 Kubernetes 네트워크는 다음과 같다.

- Cluster A Pod CIDR: `10.10.0.0/16`
- Cluster B Pod CIDR: `10.20.0.0/16`

Kubernetes 설치 전 VM 5대 상태에서는 Host RAM 사용량이
약 4.2GiB였으며, Cluster A+B 구축 완료 후 약 14GiB로 증가하였다.

동시에 MemAvailable은 약 26GiB에서 16GiB로 감소하였으나,
여전히 전체 Physical Host 메모리의 상당한 여유가 남아 있다.

Total QEMU RSS는 약 6325MiB에서 15775MiB로 증가하였다.

VM Storage 사용량은 5.7GiB에서 19GiB로 증가했으나,
Host Root 사용량은 13GiB로 유지되었다.

따라서 DAY3에서 구성한 VM 전용 Storage 분리가 정상적으로
작동하고 있으며 Kubernetes 관련 Disk 증가량이 VM Storage
영역에 격리되어 있음을 확인하였다.

현재 상태에서는 Swap 사용량이 약 1MiB로 매우 작고,
I/O Wait는 0%, Load Average 1m은 0.76으로 확인되었다.

따라서 Kubernetes System Component만 실행하는 Idle 상태에서는
Physical Host에 다음 Platform Workload를 배치할 수 있는
자원 여유가 존재한다고 판단한다.

이후 Jenkins, Registry, Argo CD, Prometheus 등의 구성요소를
추가할 때 동일한 지표를 반복 측정하여 각 구성요소의
자원 비용을 비교한다.