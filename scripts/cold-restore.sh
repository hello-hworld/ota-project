#!/usr/bin/env bash
# =====================================================================
# cold-restore.sh — 복구 지점의 qcow2를 VM 5대에 함께 되돌린다. 관문을 모두 통과해야만 덮어쓴다.
# 실행 위치 : [ota-host] ~/ota-project
# 사용법    : ./scripts/cold-restore.sh /var/lib/libvirt/ota/backup/R1-<YYYYmmdd-HHMM>
# 관문      : 1) 백업 해시 검산  2) 5대 모두 shut off  3) 도메인 XML의 디스크 경로 = 덮어쓸 경로
# 하나라도 실패하면 즉시 멈추고 종료 코드 1. 실행 중인 VM의 디스크는 절대 덮어쓰지 않는다
# =====================================================================
set -euo pipefail

R="${1:-}"
[[ -n "$R" ]] || { echo "사용법: $0 <백업 디렉터리>" >&2; exit 1; }
VMDIR="${VM_DIR:-/var/lib/libvirt/ota/vms}"
VMS=(cp-a worker-a1 cp-b worker-b1 worker-b2)

stop() { echo "STOP: $*" >&2; exit 1; }
disk_of() { sudo virsh domblklist "$1" --details | awk '$2=="disk" {print $4}'; }

sudo test -f "$R/SHA256SUMS" || stop "$R/SHA256SUMS 없음"
for vm in "${VMS[@]}"; do sudo test -f "$R/$vm/$vm.qcow2" || stop "$R/$vm/$vm.qcow2 없음"; done
sudo sh -c "cd '$R' && sha256sum -c --quiet SHA256SUMS" || stop "백업 해시 불일치"     # 관문 1
for vm in "${VMS[@]}"; do                                                              # 관문 2
  state="$(sudo env LC_ALL=C virsh domstate "$vm")"
  [[ "$state" == "shut off" ]] || stop "$vm 상태가 '$state' (먼저 종료할 것)"
done
for vm in "${VMS[@]}"; do                                                              # 관문 3
  want="$VMDIR/$vm/$vm.qcow2"
  disk_of "$vm" | grep -qxF "$want" || stop "$vm 디스크 경로가 $want 이(가) 아님"
done

for vm in "${VMS[@]}"; do
  sudo cp --sparse=always "$R/$vm/$vm.qcow2" "$VMDIR/$vm/$vm.qcow2"
  sudo qemu-img check "$VMDIR/$vm/$vm.qcow2"
done
echo "RESTORE_OK from $R"
