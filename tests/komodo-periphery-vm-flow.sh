#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || { [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'VM flow fixture requires root'; printf 'skip VM flow fixture (root required)\n'; exit 0; }
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export TOOLBOX_ROOT=$PWD TOOLBOX_CONF_DIR="$WORK/conf" TOOLBOX_STATE_DIR="$WORK/state"
source lib/common.sh
source lib/report.sh
source modules/komodo-periphery/host.sh
source modules/komodo-periphery/transport-qga.sh
source modules/komodo-periphery/transport-ssh.sh
source modules/komodo-periphery/vm.sh
KP_NODE=pve1 KP_VM_TRANSPORT=qga KP_VM_IDENTITY=identity KP_VM_MACHINE=0123456789abcdef0123456789abcdef
KP_VM_FINGERPRINT=absent KP_TRANSACTION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
KP_INSPECTION_JSON='{"schema":1,"transaction":"none","fingerprint":"absent","machine_id":"0123456789abcdef0123456789abcdef"}'
kp_vm_match() { [[ ${KP_VM_FAIL_MATCH:-0} == 0 && $1 == 201 && $2 == identity && $3 == "$KP_VM_MACHINE" ]]; }
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
[[ $(state_get komodo-periphery-qemu-201 machine_id) == "$(printf '%s' "$KP_VM_MACHINE" | sha256sum | cut -d ' ' -f1)" ]] || fail 'pending VM machine identity absent'
if grep -rFq "$KP_VM_MACHINE" "$TOOLBOX_STATE_DIR"; then fail 'raw VM machine ID persisted in host state'; fi
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

# Uninstall commits before staging cleanup. A lost connection must keep the
# target discoverable, and rerunning the public flow must reconcile it safely.
KP_INSPECTION_JSON=$(jq -nc --arg txn "$KP_TRANSACTION" --arg machine "$KP_VM_MACHINE" \
    '{schema:1,transaction:"committed",transaction_id:$txn,last_action:"uninstall",owned:false,layout:"absent",version:"",fingerprint:"absent",machine_id:$machine}')
conf_set komodo-periphery-qemu-201 KP_TRANSPORT qga
kp_vm_save 201 '' identity absent uninstall || fail 'uninstall bookkeeping failed'
KP_VM_FAIL_MATCH=1
if kp_vm_cleanup 201 "/run/pve-toolbox-komodo-$KP_TRANSACTION"; then fail 'cleanup succeeded without identity proof'; fi
status=$(kp_vm_status 2>&1) && fail 'failed uninstall cleanup reported healthy'
[[ $status == *'VM 201: pending transaction'* ]] || fail 'uninstall cleanup omitted from status'
[[ $(conf_get komodo-periphery-qemu-201 KP_PENDING) == "$KP_TRANSACTION" ]] || fail 'failed uninstall cleanup lost transaction'
unset KP_VM_FAIL_MATCH
pve_qemu_inventory() { PVE_QEMU_JSON='[{"vmid":201,"name":"fixture","status":"running"}]'; }
kp_vm_inspect() { KP_TARGET_IDENTITY=identity; }
ask() { fail "unexpected reconciliation prompt $1"; }
ask_valid() {
    case $1 in
        id) "$4" 201 || fail "listed VM rejected: $ASK_REASON"; printf -v "$1" '%s' 201 ;;
        *) fail "unexpected reconciliation prompt $1" ;;
    esac
}
ask_choice() {
    case $1 in
        transport) printf -v "$1" '%s' qga ;;
        *) fail "unexpected reconciliation prompt $1" ;;
    esac
}
ask_int() { fail "unexpected reconciliation prompt $1"; }
ask_secret() { fail "unexpected reconciliation prompt $1"; }
confirm() { return 0; }
kp_vm_change uninstall || fail 'completed uninstall could not be reconciled'
[[ -z $(conf_get komodo-periphery-qemu-201 KP_PENDING) ]] || fail 'reconciled uninstall left pending marker'
[[ -z $(conf_get komodo-periphery-qemu KP_VM_IDS) ]] || fail 'cleaned uninstall still registered'
[[ $(kp_vm_status) == 'no managed VMs' ]] || fail 'cleaned uninstall reported incomplete'
printf 'ok VM transfer intent, staging failure, secret isolation and cleanup\n'

# A first install that never commits leaves nothing to uninstall. Rerunning the
# flow must deregister the VM instead of stranding it in status and doctor.
kp_absent() { # <transaction> <transaction-id> <last-action>
    jq -nc --arg transaction "$1" --arg txn "$2" --arg action "$3" --arg machine "$KP_VM_MACHINE" \
        '{schema:1,transaction:$transaction,transaction_id:$txn,last_action:$action,owned:false,layout:"absent",version:"",fingerprint:"absent",machine_id:$machine}'
}
KP_TRANSACTION=cccccccccccccccccccccccccccccccc
KP_INSPECTION_JSON=$(kp_absent none '' '')
KP_VM_FAIL_STAGE=request
if kp_vm_apply 201 "$WORK/request.json" "$WORK/binary"; then fail 'failed first install accepted'; fi
unset KP_VM_FAIL_STAGE
[[ $(conf_get komodo-periphery-qemu KP_VM_IDS) == 201 ]] || fail 'failed first install hidden before cleanup'
kp_vm_change install || fail 'failed first install could not be cleaned up'
[[ -z $(conf_get komodo-periphery-qemu-201 KP_PENDING) ]] || fail 'failed first install left pending marker'
[[ -z $(conf_get komodo-periphery-qemu KP_VM_IDS) ]] || fail 'failed first install still registered'
[[ $(kp_vm_status) == 'no managed VMs' ]] || fail 'failed first install reported incomplete'
# A failed reinstall after an earlier committed uninstall is equally unmanaged.
kp_vm_register 201
KP_INSPECTION_JSON=$(kp_absent committed bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb uninstall)
kp_vm_cleanup 201 "/run/pve-toolbox-komodo-$KP_TRANSACTION" || fail 'failed reinstall cleanup rejected'
[[ -z $(conf_get komodo-periphery-qemu KP_VM_IDS) ]] || fail 'failed reinstall still registered'
# An owned agent stays managed: a rolled-back uninstall restores it, and a
# committed install whose files were removed out of band is drift to report.
for inspection in \
    "$(kp_absent committed "$KP_TRANSACTION" install | jq -c '.owned=true|.layout="supported"')" \
    "$(kp_absent committed "$KP_TRANSACTION" install | jq -c '.owned=true')"; do
    kp_vm_register 201
    KP_INSPECTION_JSON=$inspection
    kp_vm_cleanup 201 "/run/pve-toolbox-komodo-$KP_TRANSACTION" || fail 'owned VM cleanup rejected'
    [[ $(conf_get komodo-periphery-qemu KP_VM_IDS) == 201 ]] || fail 'owned VM deregistered'
    conf_clear komodo-periphery-qemu
done
printf 'ok failed first install deregistered; owned VMs stay managed\n'

# A rotated SSH host key: only interactive consent re-pins it, and the guest
# identity must still match. Restore the real orchestration and prompts first.
source modules/komodo-periphery/vm.sh
unset _TOOLBOX_COMMON_LOADED
source lib/common.sh
fixture_uuid=11111111-2222-3333-4444-555555555555 old_pin=SHA256:oldpin new_pin=SHA256:newpin
guest_machine=$KP_VM_MACHINE
pve_qemu_ready() { PVE_QEMU_CONFIG_JSON=$(jq -nc --arg u "$fixture_uuid" '{smbios1:("uuid="+$u)}'); }
kp_ssh_prepare() { KP_SSH_HOST_FINGERPRINT=$new_pin KP_SSH_PORT=22; }
kp_ssh_inspect() {
    printf 'inspect\n' >> "$WORK/calls"
    [[ $6 == "$fixture_uuid" ]] || return 1
    KP_SSH_INSPECTION_JSON=$(jq -nc --arg machine "$guest_machine" '{schema:1,layout:"supported",owned:true,version:"2.3.3",
        binary:"/usr/local/bin/periphery",service_user:"root",unit:"periphery.service",config_paths:["/etc/komodo/periphery.config.toml"],
        transaction:"none",fingerprint:("c"*64),reason:"",machine_id:$machine}')
}
kp_vm_apply() { printf 'apply\n' >> "$WORK/calls"; KP_OUTCOME_JSON='{"fingerprint":"absent"}'; }
kp_vm_cleanup() { :; }
ask_valid() {
    case $1 in
        id) printf -v "$1" '%s' 201 ;;
        address) printf -v "$1" '%s' vm.example.invalid ;;
        key_file|hosts) printf -v "$1" '%s' "$WORK/ssh-$1" ;;
        *) fail "unexpected host-key prompt $1" ;;
    esac
}
ask_int() { printf -v "$1" '%s' 22; }
ask_choice() { [[ $1 == transport ]] || fail "unexpected host-key prompt $1"; printf -v "$1" '%s' ssh; }
record=komodo-periphery-qemu-201
for pair in KP_TRANSPORT=ssh KP_ADDRESS=vm.example.invalid KP_PORT=22 "KP_KEY_FILE=$WORK/ssh-key_file" \
    "KP_KNOWN_HOSTS=$WORK/ssh-hosts" "KP_HOST_FINGERPRINT=$old_pin" \
    "KP_IDENTITY=$(printf '%s\n' pve1 qemu 201 "$fixture_uuid" "$guest_machine" | sha256sum | cut -d ' ' -f1)"; do
    conf_set "$record" "${pair%%=*}" "${pair#*=}"
done
state_set "$record" machine_id "$guest_machine"
state_set "$record" fingerprint "$(printf 'c%.0s' {1..64})"
kp_vm_registry add 201
pin() { conf_get "$record" KP_HOST_FINGERPRINT; }

: > "$WORK/calls"
out=$(kp_vm_change update 2>&1 <<<n) && fail 'declined host-key rotation accepted'
[[ $out == *"$old_pin"* && $out == *"$new_pin"* ]] || fail "rotation prompt omits the fingerprints: $out"
[[ $out == *man-in-the-middle* ]] || fail "rotation prompt omits the interception warning: $out"
[[ $(pin) == "$old_pin" ]] || fail 'declined rotation replaced the pin'
[[ ! -s $WORK/calls ]] || fail 'guest contacted after declined rotation'
out=$(ASSUME_YES=1 kp_vm_change update 2>&1 </dev/null) && fail 'host-key rotation accepted under -y'
[[ $out == *interactive* ]] || fail "-y refusal does not point to the interactive command: $out"
[[ $(pin) == "$old_pin" ]] || fail '-y replaced the pin'
out=$(kp_vm_change update 2>&1 </dev/null) && fail 'host-key rotation accepted at end of input'
[[ $(pin) == "$old_pin" ]] || fail 'end of input replaced the pin'
out=$(kp_vm_status 2>&1) && fail 'status accepted a rotated host key'
[[ $out == *interactive* ]] || fail "status does not point to the interactive command: $out"
[[ $(pin) == "$old_pin" ]] || fail 'status replaced the pin'
guest_machine=fedcba9876543210fedcba9876543210
out=$(kp_vm_change uninstall 2>&1 <<<$'y\ny') && fail 're-pin bypassed guest identity verification'
[[ $(pin) == "$old_pin" ]] || fail 'pin replaced for a different guest'
guest_machine=$KP_VM_MACHINE
: > "$WORK/calls"
out=$(kp_vm_change uninstall 2>&1 <<<$'y\ny') || fail "accepted host-key rotation stopped the operation: $out"
[[ $(pin) == "$new_pin" ]] || fail 'accepted rotation not re-pinned'
grep -qx apply "$WORK/calls" || fail 'operation did not continue after re-pin'
printf 'ok rotated SSH host key re-pins only with interactive consent and a matching guest\n'
