#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
export TOOLBOX_ROOT=$PWD
source lib/common.sh
source modules/komodo-periphery/host.sh
source modules/komodo-periphery/vm.sh
KP_NODE=pve1 KP_VM_TRANSPORT=qga
PVE_QEMU_CONFIG_JSON='{"agent":"enabled=1","smbios1":"uuid=11111111-2222-3333-4444-555555555555"}'
PVE_QEMU_ERROR=''
MACHINE=0123456789abcdef0123456789abcdef
pve_qemu_ready() { [[ $1 == pve1 && $2 == 201 ]]; }
kp_qga_exec() {
    [[ $1 == pve1 && $2 == 201 && $3 == '["/bin/bash","-s","--","inspect"]' && $4 == "$TOOLBOX_ROOT/modules/komodo-periphery/guest.sh" ]] || return 1
    jq -nc --arg machine "$MACHINE" '{schema:1,layout:"absent",version:"",reason:"",fingerprint:"absent",machine_id:$machine}'
}
kp_vm_inspect 201 || fail 'enabled QGA inspection rejected'
identity=$KP_TARGET_IDENTITY
[[ $KP_VM_UUID == 11111111-2222-3333-4444-555555555555 ]] || fail 'PVE UUID lost'
MACHINE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
if kp_vm_match 201 "$identity" 0123456789abcdef0123456789abcdef; then fail 'reused VM with another machine ID accepted'; fi
for agent in '1' '"1"' '"enabled=1"' '"1,fstrim_cloned_disks=1"' '"enabled=1,fstrim_cloned_disks=1"' '"type=virtio,enabled=1"'; do
    PVE_QEMU_CONFIG_JSON=$(jq -nc --argjson agent "$agent" '{agent:$agent}')
    kp_vm_inspect 201 || fail "enabled QGA configuration rejected: $agent"
done
for agent in '0' '"0"' '"enabled=0"' '"0,fstrim_cloned_disks=1"' '"fstrim_cloned_disks=1"' '"11,fstrim_cloned_disks=1"' '"disabled=1"' 'null'; do
    PVE_QEMU_CONFIG_JSON=$(jq -nc --argjson agent "$agent" '{agent:$agent}')
    if kp_vm_inspect 201; then fail "disabled or invalid QGA configuration accepted: $agent"; fi
done
KP_VM_TRANSPORT=ssh KP_VM_ADDRESS=vm.example.invalid KP_VM_PORT=22 KP_VM_KEY=/root/key KP_VM_HOSTS=/root/hosts
PVE_QEMU_CONFIG_JSON='{"agent":"enabled=0"}'
kp_ssh_inspect() { fail 'SSH called without PVE UUID'; }
if kp_vm_inspect 201; then fail 'SSH accepted VM without SMBIOS UUID'; fi
printf 'ok VM inspection binds machine identity and enforces transport prerequisites\n'
