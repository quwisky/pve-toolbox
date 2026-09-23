#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || { [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'VM flow fixture requires root'; printf 'skip VM flow fixture (root required)\n'; exit 0; }
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export TOOLBOX_ROOT=$PWD TOOLBOX_CONF_DIR="$WORK/conf" TOOLBOX_STATE_DIR="$WORK/state"
source lib/common.sh
source modules/komodo-periphery/host.sh
source modules/komodo-periphery/transport-qga.sh
source modules/komodo-periphery/transport-ssh.sh
source modules/komodo-periphery/vm.sh
KP_NODE=pve1 KP_VM_TRANSPORT=qga KP_VM_IDENTITY=identity KP_VM_MACHINE=0123456789abcdef0123456789abcdef
KP_VM_FINGERPRINT=absent KP_TRANSACTION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
KP_INSPECTION_JSON='{"schema":1,"transaction":"none","fingerprint":"absent","machine_id":"0123456789abcdef0123456789abcdef"}'
kp_vm_match() { [[ $1 == 201 && $2 == identity && $3 == "$KP_VM_MACHINE" ]]; }
kp_qga_bootstrap() { printf 'bootstrap\n' >> "$WORK/calls"; }
kp_vm_stage() {
    printf 'stage %s\n' "$2" >> "$WORK/calls"
    [[ ${KP_VM_FAIL_STAGE:-} != "$2" ]]
}
kp_vm_command() {
    printf 'command %s\n' "$2" >> "$WORK/calls"
    if [[ $2 == *'"apply"'* ]]; then
        printf '{"schema":1,"transaction_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","result":"success","reason":"","rollback":"none","fingerprint":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    fi
}
printf '{"onboarding_key":"secret;$(touch /tmp/never-run)"}\n' > "$WORK/request.json"
chmod 0600 "$WORK/request.json"
printf binary > "$WORK/binary"
: > "$WORK/calls"
kp_vm_apply 201 "$WORK/request.json" "$WORK/binary" || fail 'valid VM apply rejected'
[[ $(conf_get komodo-periphery-qemu-201 KP_PENDING) == "$KP_TRANSACTION" ]] || fail 'pending marker absent before commit bookkeeping'
[[ $(conf_get komodo-periphery-qemu KP_VM_IDS) == 201 ]] || fail 'first-install pending VM hidden from inventory'
[[ $(state_get komodo-periphery-qemu-201 machine_id) == "$KP_VM_MACHINE" ]] || fail 'pending VM machine identity absent'
kp_host_require() { :; }
kp_vm_load_connection() { KP_VM_TRANSPORT=qga; }
status=$(kp_vm_status 2>&1) && fail 'pending VM reported healthy'
[[ $status == *'pending transaction'* ]] || fail 'pending VM omitted from status'
[[ $(state_get komodo-periphery-qemu-201 result) == *incomplete* ]] || fail 'incomplete outcome not visible'
[[ $(grep -c '^stage ' "$WORK/calls") == 3 ]] || fail 'helper, binary and request not staged'
[[ $(grep -c '^command ' "$WORK/calls") == 1 ]] || fail 'guest apply was not called once'
if grep -Fq 'secret;' "$WORK/calls" "$TOOLBOX_STATE_DIR"/*.state; then fail 'secret leaked into command or state'; fi
KP_VM_FAIL_STAGE=request
: > "$WORK/calls"
if kp_vm_apply 201 "$WORK/request.json" "$WORK/binary"; then fail 'interrupted request transfer accepted'; fi
[[ $(conf_get komodo-periphery-qemu-201 KP_PENDING) == "$KP_TRANSACTION" ]] || fail 'interrupted transfer lost pending marker'
if grep -q '^command ' "$WORK/calls"; then fail 'apply ran after failed staging'; fi
unset KP_VM_FAIL_STAGE
KP_INSPECTION_JSON='{"schema":1,"transaction":"committed","fingerprint":"absent","machine_id":"0123456789abcdef0123456789abcdef"}'
kp_vm_cleanup 201 "/run/pve-toolbox-komodo-$KP_TRANSACTION" || fail 'completed staging cleanup rejected'
[[ -z $(conf_get komodo-periphery-qemu-201 KP_PENDING) ]] || fail 'cleanup left pending marker'
conf_set komodo-periphery-qemu-201 KP_PENDING "$KP_TRANSACTION"
KP_INSPECTION_JSON='{"schema":1,"transaction":"pending","fingerprint":"absent","machine_id":"0123456789abcdef0123456789abcdef"}'
if kp_vm_cleanup 201 "/run/pve-toolbox-komodo-$KP_TRANSACTION"; then fail 'pending guest journal cleaned'; fi
[[ $(conf_get komodo-periphery-qemu-201 KP_PENDING) == "$KP_TRANSACTION" ]] || fail 'pending journal lost host marker'
printf 'ok VM transfer intent, staging failure, secret isolation and cleanup\n'
