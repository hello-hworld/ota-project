#!/usr/bin/env bash
# =====================================================================
# cold-backup.sh — VM 5대 콜드 백업(복구 지점). 관문을 모두 통과해야만 디스크를 복사한다.
# 실행 위치 : [ota-host] ~/ota-project
# 사용법    : ./scripts/cold-backup.sh R1     → /var/lib/libvirt/ota/backup/R1-<YYYYmmdd-HHMM>
# 관문      : 1) 5대 모두 shut off  2) 도메인 XML의 디스크 경로 = 복사할 경로
#             3) 같은 이름의 백업 디렉터리가 없음  4) 여유 공간 ≥ 복사량 × 2
#             끝난 뒤 5) 해시 검산  6) 백업 중 VM이 켜지지 않았음
# 하나라도 실패하면 즉시 멈추고 종료 코드 1 (VM 기동·다음 단계로 넘어가지 않는다)
# =====================================================================
set -euo pipefail

NAME="${1:-}"
[[ -n "$NAME" ]] || { echo "사용법: $0 <복구지점 이름, 예 R1>" >&2; exit 1; }
BASE="${BACKUP_BASE:-/var/lib/libvirt/ota/backup}"
VMDIR="${VM_DIR:-/var/lib/libvirt/ota/vms}"
VMS=(cp-a worker-a1 cp-b worker-b1 worker-b2)
R="$BASE/$NAME-$(date +%Y%m%d-%H%M)"

stop() { echo "STOP: $*" >&2; exit 1; }
all_shut_off() {
  local vm state
  for vm in "${VMS[@]}"; do
    state="$(sudo env LC_ALL=C virsh domstate "$vm")"
    [[ "$state" == "shut off" ]] || stop "$vm 상태가 '$state' ($1)"
  done
}
disk_of() { sudo virsh domblklist "$1" --details | awk '$2=="disk" {print $4}'; }

all_shut_off "먼저 종료할 것"                                          # 관문 1
for vm in "${VMS[@]}"; do                                              # 관문 2
  want="$VMDIR/$vm/$vm.qcow2"
  disk_of "$vm" | grep -qxF "$want" || stop "$vm 디스크 경로가 $want 이(가) 아님: $(disk_of "$vm" | xargs)"
done
[[ ! -e "$R" ]] || stop "$R 이(가) 이미 있음 (덮어쓰지 않는다)"        # 관문 3
sudo mkdir -p "$BASE"
need=$(sudo du -sk "$VMDIR" | cut -f1)                                 # 관문 4
avail=$(df -k --output=avail "$BASE" | tail -1 | tr -d ' ')
(( avail > need * 2 )) || stop "여유 공간 부족: 필요 ${need}K×2, 남은 ${avail}K"

sudo mkdir "$R"
for vm in "${VMS[@]}"; do
  sudo mkdir "$R/$vm"
  sudo virsh dumpxml "$vm" | sudo tee "$R/$vm/$vm.xml" > /dev/null
  sudo cp --sparse=always "$VMDIR/$vm/$vm.qcow2" "$R/$vm/"
  sudo cp "$VMDIR/$vm/seed.iso" "$R/$vm/"
  sudo qemu-img check "$R/$vm/$vm.qcow2"
done
sudo virsh net-dumpxml ota-net | sudo tee "$R/ota-net.xml" > /dev/null
sudo sh -c "cd '$R' && sha256sum */*.qcow2 > SHA256SUMS && sha256sum -c SHA256SUMS"   # 5
all_shut_off "백업 중 켜짐 → $R 사용 금지"                              # 6

echo "BACKUP=$R"
echo "${NAME}_BACKUP_OK"
