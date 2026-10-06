# DAY 1 Baseline

## Physical Host

### OS

- OS: Ubuntu Server
- Ubuntu Version: 24.04.5 LTS (Noble Numbat)
- Kernel: 6.8.0-139-generic

---

### CPU

- Model: 12th Gen Intel(R) Core(TM) i5-12400
- Socket: 1
- Core: 6
- Thread per Core: 2
- Logical CPU: 12
- Virtualization: VT-x

### CPU Virtualization

- KVM Device: `/dev/kvm` 존재
- KVM Acceleration: 사용 가능

---

### Memory

#### KVM 설치 전

- Total: 31 GiB
- Used: 888 MiB
- Free: 29 GiB
- Available: 30 GiB
- Swap Total: 8.0 GiB
- Swap Used: 0 B

#### Raw

- MemTotal: 32573540 kB
- MemAvailable: 31664864 kB
- SwapTotal: 8388604 kB
- SwapFree: 8388604 kB

---

### Disk

#### Physical Disk

- Main Disk: `/dev/nvme0n1`
- Physical Capacity: 465.8 GiB

#### Partition

- `/dev/nvme0n1p1`: 1 GiB - `/boot/efi`
- `/dev/nvme0n1p2`: 2 GiB - `/boot`
- `/dev/nvme0n1p3`: 약 462.7 GiB - LVM

#### Root Filesystem

- LV: `ubuntu-vg/ubuntu-lv`
- LV Size: 100 GiB
- Filesystem Size: 98 GiB
- Used: 12 GiB
- Available: 82 GiB
- Usage: 12%

---

### LVM

- Physical Volume: `/dev/nvme0n1p3`
- Volume Group: `ubuntu-vg`
- VG Size: 약 462.71 GiB
- Existing LV: `ubuntu-lv`
- LV Size: 100 GiB
- VG Free: 약 362.71 GiB

> VM 저장소용 공간은 아직 최종 할당하지 않았다.
> Host Root 영역과 VM 저장 영역을 분리할지 이후 결정한다.

---

### Network

- Wi-Fi Interface: `wlx088af1327d7f`
- Physical Server IP: `192.168.200.48/22`
- Default Gateway: `192.168.200.1`
- Default Interface: `wlx088af1327d7f`
- LAN CIDR: `192.168.200.0/22`

#### Other Interfaces

- `enp2s0`
- `enp3s0`
- `wlo1`

### Network Issue

- Server → Gateway: SUCCESS
- Server → Internet: SUCCESS
- Laptop → Internet: SUCCESS
- Server → Laptop: FAIL
- Laptop → Server: FAIL
- Laptop → Server SSH: FAIL

서버의 SSH daemon과 TCP/22 Listen 상태는 정상이었으나,
동일 무선망의 Laptop과 직접 통신되지 않았다.

`ip neigh` 확인 과정에서 다른 단말과의 Neighbor Resolution이
실패하는 현상이 확인되어 학원 무선망의 Client/AP Isolation
가능성을 원인 후보로 기록하였다.

---

# State A — Ubuntu Baseline

KVM/libvirt/Ansible 설치 전 상태.

| Metric | Value |
|---|---:|
| RAM Total | 31 GiB |
| RAM Used | 888 MiB |
| MemAvailable | 30 GiB |
| Swap Used | 0 B |
| Root Disk Used | 12 GiB |
| Root Disk Available | 82 GiB |
| Load Average | 측정하지 않음 |

---

# State B — KVM/libvirt/Ansible Installed

설치 항목:

- KVM
- libvirt
- virt-install
- qemu-utils
- Ansible
- cloud-image-utils
- python3-libvirt
- python3-lxml

## Version

- Ansible Core: 2.16.3
- Python: 3.12.3
- Jinja: 3.1.2
- libyaml: True

## Resource

| Metric | Value |
|---|---:|
| RAM Total | 31 GiB |
| RAM Used | 933 MiB |
| MemAvailable | 30 GiB |
| Swap Used | 0 B |
| Root Disk Used | 13 GiB |
| Root Disk Available | 81 GiB |
| Load Average | 0.00 / 0.01 / 0.00 |

---

# State A → State B 비교

| Metric | Ubuntu Only | KVM/Ansible Installed | Difference |
|---|---:|---:|---:|
| RAM Used | 888 MiB | 933 MiB | +45 MiB |
| MemAvailable | 30 GiB | 30 GiB | 큰 변화 없음 |
| Root Disk Used | 12 GiB | 13 GiB | 약 +1 GiB |
| Swap Used | 0 B | 0 B | 변화 없음 |
| Load Average | 미측정 | 0.00 / 0.01 / 0.00 | 비교 불가 |

## Observation

KVM/libvirt와 Ansible 관련 도구를 설치한 직후에는
Physical Host의 메모리 사용량이 크게 증가하지 않았다.

다만 현재 상태는 VM이 실행되지 않는 상태이므로
가상화 환경 자체의 기본 비용만 확인한 결과이다.

실제 VM 실행 이후 QEMU RSS, Host MemAvailable,
CPU 사용량을 다시 측정해야 한다.

---

# Initial VM Resource Plan

Physical Host:

- Logical CPU: 12
- RAM: 31 GiB

VM 계획:

| VM | vCPU | RAM |
|---|---:|---:|
| cp-a | 2 | 2 GiB |
| worker-a1 | 4 | 6 GiB |
| cp-b | 2 | 3 GiB |
| worker-b1 | 4 | 7 GiB |
| worker-b2 | 4 | 7 GiB |
| Total | 16 | 25 GiB |

## CPU

Physical Logical CPU:

12

VM vCPU Allocation:

16

Initial CPU Overcommit Ratio:

16 / 12 ≈ 1.33 : 1

현재 값은 초기 설계값이며 모든 VM이 동시에 CPU를 사용할 경우
Host CPU 경쟁이 발생할 수 있다.

향후 Jenkins Build 부하와 Production 부하가 동시에 발생하는 조건에서
CPU 경쟁 및 서비스 지연을 측정한다.

## Memory

Physical Host는 32 GB급 장비이며
Linux에서는 약 31 GiB로 확인된다.

VM 메모리 초기 할당 합계는 25 GiB이다.

단순히 31 GiB - 25 GiB를 실제 Host 여유 메모리라고 해석하지 않는다.

Guest OS, QEMU overhead, Host OS, Page Cache 등의 사용량을 포함하여
VM 실행 이후 실제 `MemAvailable`과 QEMU RSS를 측정한다.

---

# DAY 1 Result

DAY 1에서 완료한 작업:

- Physical Host OS 확인
- CPU/RAM/Disk Baseline 확보
- Network Baseline 확보
- 학원 Wi-Fi 단말 간 통신 문제 확인
- CPU Virtualization 확인
- KVM/libvirt 설치
- KVM Acceleration 확인
- Ansible 설치
- cloud-init 관련 도구 준비

다음 단계:

1. Git Repository를 Server로 Clone
2. Ansible dependency 설치
3. `ota-net` 생성
4. Test VM 1대 생성
5. Test VM Network / SSH / Internet 검증
6. VM 실행 후 Physical Host 자원 재측정
7. 검증 성공 후 VM 5대로 확장