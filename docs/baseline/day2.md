# DAY 2 Measurement Summary

## 1. libvirt Network

### ota-net

- Network Name: `ota-net`
- State: active
- Autostart: yes
- Persistent: yes
- Forward Mode: NAT
- Bridge: `virbr56`
- Gateway: `192.168.56.1/24`
- DHCP Range: `192.168.56.100 ~ 192.168.56.200`

### Observation

Test VM 생성 전에는 `virbr56`가 Linux interface 기준 `DOWN` 상태로 표시되었으나,
libvirt 기준 `ota-net`은 정상적으로 Active 상태였다.

VM이 연결된 이후 실제 Guest Network 통신도 정상적으로 확인되었다.

---

# 2. Test VM Provisioning Result

## Ansible

`02-create-test-vm.yml` 실행 결과:

- ok: 9
- changed: 8
- unreachable: 0
- failed: 0

Result: PASS

## VM Configuration

- VM Name: `test-vm`
- State: running
- vCPU: 2
- Configured RAM: 2048 MiB
- Virtual Disk: 30 GiB
- Autostart: enabled

---

# 3. State D0 — Test VM 생성 전 Physical Host

## Memory

- RAM Total: 31 GiB
- RAM Used: 985 MiB
- RAM Free: 27 GiB
- MemAvailable: 31,565,980 KiB
- Swap Total: 8 GiB
- Swap Used: 0 B

## CPU / Load

- Load Average 1m: 0.00
- Load Average 5m: 0.01
- Load Average 15m: 0.00

대표 `vmstat` 샘플:

- CPU User: 0%
- CPU System: 0%
- CPU Idle: 100%
- I/O Wait: 0%

## Disk

- Root Filesystem Size: 98 GiB
- Root Used: 13 GiB
- Root Available: 81 GiB
- Root Usage: 14%

### VM Storage

- `/var/lib/libvirt/ota`: Test VM 생성 전에는 존재하지 않음
- 별도 VM Storage LV: 아직 구성하지 않음

---

# 4. Test VM Network

## DHCP

- VM IP: `192.168.56.102`
- VM NIC: `enp1s0`
- Default Gateway: `192.168.56.1`

## Host → VM Ping

- Packet Loss: 0%
- Average RTT: 약 0.274 ms

Result: PASS

## SSH

- SSH 접속: SUCCESS

## VM → Gateway

- `192.168.56.1`: SUCCESS

## VM → Internet

- `8.8.8.8`: SUCCESS

## DNS

- `google.com`: SUCCESS

Result:

- DHCP: PASS
- Host → VM: PASS
- SSH: PASS
- VM → Gateway: PASS
- VM → Internet: PASS
- DNS: PASS

# 5. cloud-init

- cloud-init Status: `done`
- Extended Status: done
- Recoverable Errors: 없음

Result: PASS

### 확인된 자동화 흐름

Ansible
→ Ubuntu Cloud Image
→ cloud-init
→ devops User 생성
→ SSH Public Key 적용
→ VM 초기 설정

정상 동작 확인.

# 6. Guest Resource

## CPU

- vCPU: 2
- CPU Model: Intel Core Processor (Skylake, IBRS)

## Memory

- Guest RAM Total: 1.9 GiB
- Guest RAM Used: 328 MiB
- Guest RAM Free: 1.4 GiB
- Guest MemAvailable: 1.6 GiB
- Guest Swap Used: 0 B

## Disk

- Virtual Disk `/dev/vda`: 30 GiB
- Root Partition `/dev/vda1`: 29 GiB
- Root Filesystem Size: 29 GiB
- Root Used: 1.7 GiB
- Root Available: 27 GiB
- Root Usage: 6%

### Observation

Playbook에서 설정한 30 GiB Virtual Disk가 Guest 내부에서 정상적으로 인식되었고,
Root Filesystem도 약 29 GiB까지 확장되었다.

# 7. State D1 — Test VM 실행 후 Physical Host

## Memory

- RAM Total: 31 GiB
- RAM Used: 약 1.6 GiB
- RAM Free: 약 25 GiB
- MemAvailable: 30,931,428 KiB
- Swap Total: 8 GiB
- Swap Used: 0 B

## CPU / Load

- Load Average 1m: 0.18
- Load Average 5m: 0.11
- Load Average 15m: 0.04

대표 `vmstat` 샘플:

- CPU User: 0%
- CPU System: 0%
- CPU Idle: 100%
- I/O Wait: 0%

## Disk

- Root Filesystem Size: 98 GiB
- Root Used: 14 GiB
- Root Available: 80 GiB
- Root Usage: 15%

| Metric | VM 0대 (D0) | Test VM 1대 (D1) | 변화 |
|---|---:|---:|---:|
| RAM Used | 985 MiB | 약 1.6 GiB | 약 +0.6 GiB |
| MemAvailable | 31,565,980 KiB | 30,931,428 KiB | -634,552 KiB |
| MemAvailable 감소 | - | - | 약 619.7 MiB |
| Swap Used | 0 | 0 | 변화 없음 |
| Load 1m | 0.00 | 0.18 | +0.18 |
| CPU User | 0% | 0% | 대표 샘플 기준 변화 없음 |
| CPU System | 0% | 0% | 대표 샘플 기준 변화 없음 |
| CPU Idle | 100% | 100% | 대표 샘플 기준 변화 없음 |
| I/O Wait | 0% | 0% | 변화 없음 |
| Root Used | 13 GiB | 14 GiB | 약 +1 GiB |
| Root Available | 81 GiB | 80 GiB | 약 -1 GiB |

actual     2097152 KiB
unused     1884576 KiB
available  2005948 KiB
usable     1810080 KiB
rss         713156 KiB



# 9. qcow2 Disk

## test-vm.qcow2

- Format: qcow2
- Virtual Size: 30 GiB
- Virtual Size Bytes: 32,212,254,720 bytes
- Actual Disk Size: 약 653 MiB
- `du` Result: 약 653 MiB

## Test VM Directory

- `/var/lib/libvirt/ota/vms/test-vm`
- Actual Usage: 약 654 MiB

## OTA VM Storage 전체

- `/var/lib/libvirt/ota`
- Actual Usage: 약 1.3 GiB

### Observation

Guest에는 30 GiB의 Virtual Disk를 제공했지만,
Test VM 생성 직후 Physical Host에서 qcow2가 실제 차지한 공간은
약 653 MiB였다.

따라서 qcow2 Thin Provisioning으로 인해
논리적 Disk 크기와 실제 Physical Disk 사용량이 다름을 확인하였다.

# 10. DAY 2 Result

## Provisioning

- Ansible Provisioning: PASS
- libvirt ota-net: PASS
- Ubuntu Cloud Image: PASS
- cloud-init: PASS
- SSH Public Key: PASS
- Test VM Boot: PASS

## Network

- DHCP: PASS
- Host → VM: PASS
- SSH: PASS
- VM → Gateway: PASS
- VM → Internet: PASS
- DNS: PASS

## Resource

- vCPU 2 정상 인식
- RAM 2 GiB 정상 인식
- Virtual Disk 30 GiB 정상 인식
- Root Filesystem 자동 확장 정상

## Physical Resource Observation

Test VM 1대 실행 후:

- Host MemAvailable 약 620 MiB 감소
- QEMU RSS 약 696 MiB
- Root 사용량 약 1 GiB 증가
- Swap 사용 없음
- Idle 상태 CPU 압박은 확인되지 않음

## Storage Observation

- Virtual Disk: 30 GiB
- Actual qcow2 Size: 약 653 MiB
- Test VM Directory: 약 654 MiB
- OTA Storage 전체: 약 1.3 GiB

30 GiB Virtual Disk가 즉시 Physical Disk 30 GiB를 소비하지 않음을 확인하였다.

## DAY 2 판정

Test VM Validation: PASS

다음 단계 진행 가능: YES