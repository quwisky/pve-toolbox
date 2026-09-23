#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export TOOLBOX_CONF_DIR="$WORK/conf" TOOLBOX_STATE_DIR="$WORK/state"
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
source lib/common.sh
source modules/komodo-periphery/host.sh
[[ -r modules/komodo-periphery/vm.sh ]] || fail 'VM record manager missing'
source modules/komodo-periphery/vm.sh

# A VM and an LXC may share a numeric ID. Their keys must stay distinct so
# removing or updating one cannot reuse the other's protected record.
[[ $(kp_target_key lxc 101) == lxc-101 ]] || fail 'LXC target key'
[[ $(kp_target_key qemu 101) == qemu-101 ]] || fail 'VM target key'
for kind in vm '' ../qemu; do
    if kp_target_key "$kind" 101 >/dev/null; then fail 'unknown guest kind accepted'; fi
done
for id in 0 99 101x ../101 '101;touch /tmp/unsafe'; do
    if kp_target_key qemu "$id" >/dev/null; then fail 'unsafe VMID accepted'; fi
done

# Keep real config/state helpers but accept this isolated non-root test root.
kp_host_safe() { [[ $1 == "$WORK/"* && ! -L $1 ]]; }
conf_set komodo-periphery KP_IDS 101
kp_vm_save 101 2.3.3 vm-one hash-one install || fail 'VM save failed'
[[ $(conf_get komodo-periphery KP_IDS) == 101 ]] || fail 'VM save changed LXC list'
[[ $(conf_get komodo-periphery-qemu KP_VM_IDS) == 101 ]] || fail 'VM list missing'
[[ $(state_get komodo-periphery-qemu-101 version) == 2.3.3 ]] || fail 'VM state missing'
kp_vm_save 102 2.3.2 vm-two hash-two install || fail 'second VM save failed'
kp_vm_save 101 2.3.3 vm-one hash-one uninstall || fail 'VM uninstall record failed'
[[ $(conf_get komodo-periphery-qemu KP_VM_IDS) == 102 ]] || fail 'VM uninstall changed another VM'
[[ $(conf_get komodo-periphery KP_IDS) == 101 ]] || fail 'VM uninstall changed LXC list'
printf 'ok Periphery target keys separate VMs and LXCs\n'
