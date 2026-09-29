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
# Pause one real registry write after its snapshot. A second VM operation may
# run concurrently, but its registration must not be lost when the first resumes.
eval "$(declare -f conf_set | sed '1s/conf_set/conf_set_real/')"
conf_set() {
    if [[ $1 == komodo-periphery-qemu && ${REGISTRY_WORKER:-} == first ]]; then
        touch "$WORK/first-writing"
        for ((attempt=0; attempt<250; attempt++)); do
            [[ ! -e $WORK/release-first ]] || break
            sleep 0.02
        done
        [[ -e $WORK/release-first ]] || return 1
    fi
    conf_set_real "$@"
}
conf_set komodo-periphery KP_IDS 101
KP_VM_MACHINE=0123456789abcdef0123456789abcdef
kp_vm_save 101 2.3.3 vm-one hash-one install || fail 'VM save failed'
[[ $(conf_get komodo-periphery KP_IDS) == 101 ]] || fail 'VM save changed LXC list'
[[ $(conf_get komodo-periphery-qemu KP_VM_IDS) == 101 ]] || fail 'VM list missing'
[[ $(state_get komodo-periphery-qemu-101 version) == 2.3.3 ]] || fail 'VM state missing'
kp_vm_save 102 2.3.2 vm-two hash-two install || fail 'second VM save failed'
kp_vm_save 101 2.3.3 vm-one hash-one uninstall || fail 'VM uninstall record failed'
[[ $(conf_get komodo-periphery-qemu KP_VM_IDS) == '101 102' ]] || fail 'VM uninstall hidden before cleanup'
[[ $(conf_get komodo-periphery KP_IDS) == 101 ]] || fail 'VM uninstall changed LXC list'

(
    REGISTRY_WORKER=first
    kp_vm_lock 201 && kp_vm_register 201
) & first=$!
for ((attempt=0; attempt<250; attempt++)); do
    [[ ! -e $WORK/first-writing ]] || break
    sleep 0.02
done
[[ -e $WORK/first-writing ]] || fail 'first writer did not reach registry'
(
    kp_vm_lock 202 && kp_vm_save 202 2.3.3 vm-two hash-two install
) & second=$!
# Allow the second operation to attempt its write while the first is paused.
sleep 1
touch "$WORK/release-first"
wait "$first" || fail 'first concurrent registration failed'
wait "$second" || fail 'second concurrent registration failed'
kp_vm_ids || fail 'concurrent writes corrupted registry'
[[ " ${KP_VM_IDS[*]} " == *' 201 '* && " ${KP_VM_IDS[*]} " == *' 202 '* ]] || fail 'concurrent registration lost a VM'

# machine-id(5) is confidential; world-readable host state keeps only its
# SHA-256. Legacy raw records must still match and are rewritten on save.
raw=0123456789abcdef0123456789abcdef other=fedcba9876543210fedcba9876543210
hashed=$(printf '%s' "$raw" | sha256sum | cut -d ' ' -f1)
if grep -rFq "$raw" "$TOOLBOX_STATE_DIR"; then fail 'raw VM machine ID persisted in host state'; fi
[[ $(state_get komodo-periphery-qemu-101 machine_id) == "$hashed" ]] || fail 'VM machine ID hash not recorded'
guest_machine=$raw
kp_vm_inspect() { KP_TARGET_IDENTITY=vm-one KP_INSPECTION_JSON=$(jq -nc --arg m "$guest_machine" '{machine_id:$m}'); }
kp_vm_match 101 vm-one "$hashed" >/dev/null 2>&1 || fail 'hashed VM machine ID rejected'
kp_vm_match 101 vm-one "$raw" >/dev/null 2>&1 || fail 'legacy raw VM machine ID rejected'
for stored in '' "$other" "$(printf '%s' "$other" | sha256sum | cut -d ' ' -f1)" "$hashed$hashed"; do
    if kp_vm_match 101 vm-one "$stored" >/dev/null 2>&1; then fail 'different VM machine ID accepted'; fi
done
if kp_vm_match 101 vm-two "$hashed" >/dev/null 2>&1; then fail 'different VM identity accepted'; fi
guest_machine=$other
if kp_vm_match 101 vm-one "$hashed" >/dev/null 2>&1 || kp_vm_match 101 vm-one "$raw" >/dev/null 2>&1; then
    fail 'replaced VM guest matched recorded machine ID'
fi
state_set komodo-periphery-qemu-101 machine_id "$raw"
kp_vm_save 101 2.3.3 vm-one hash-one install || fail 'legacy VM record save failed'
[[ $(state_get komodo-periphery-qemu-101 machine_id) == "$hashed" ]] || fail 'legacy raw VM machine ID not upgraded'
if grep -rFq "$raw" "$TOOLBOX_STATE_DIR"; then fail 'legacy raw VM machine ID left in host state'; fi
KP_VM_MACHINE=''
if kp_vm_save 101 2.3.3 vm-one hash-one install; then fail 'VM record saved without a machine ID'; fi
printf 'ok Periphery target keys separate VMs and LXCs\n'
