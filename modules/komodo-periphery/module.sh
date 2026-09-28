# shellcheck shell=bash
# Discovery must not inspect or change containers.
# shellcheck disable=SC2034
MODULE_NAME="komodo-periphery"
MODULE_TITLE="Komodo Periphery in LXC or VM"
MODULE_DESC="install or manage a systemd agent in a selected local container or VM"
MODULE_TAGS="lxc vm qemu komodo periphery agent"
MODULE_HOST_ONLY=1
MODULE_EXPLICIT_UPDATE=1
# config show may print these; the SSH private-key and known-hosts paths stay
# hidden.
MODULE_CONFIG_PUBLIC="KP_IDS KP_VM_IDS KP_VERSION KP_TRANSPORT KP_ADDRESS KP_PORT"
MODULE_CONFIG_PUBLIC+=" KP_HOST_FINGERPRINT KP_PENDING KP_IDENTITY"

# The per-guest records config show displays after komodo-periphery.conf:
# the VM index, then one record per saved container and VM ID. Read-only,
# conf_get only; an ID that is not all digits names no file. The lists split
# on whitespace with globbing off, so a saved * never matches a file name.
module_config_files() {
    local -
    set -f
    local IFS=$' \t\n' ids id
    printf '%s\n' komodo-periphery-qemu
    ids=$(conf_get komodo-periphery KP_IDS) || return 1
    for id in $ids; do
        if [[ $id =~ ^[0-9]+$ ]]; then printf 'komodo-periphery-%s\n' "$id"; fi
    done
    ids=$(conf_get komodo-periphery-qemu KP_VM_IDS) || return 1
    for id in $ids; do
        if [[ $id =~ ^[0-9]+$ ]]; then printf 'komodo-periphery-qemu-%s\n' "$id"; fi
    done
}

_kp_load() {
    # shellcheck source=modules/komodo-periphery/host.sh
    source "$TOOLBOX_ROOT/modules/komodo-periphery/host.sh"
    # shellcheck source=modules/komodo-periphery/transport-qga.sh
    source "$TOOLBOX_ROOT/modules/komodo-periphery/transport-qga.sh"
    # shellcheck source=modules/komodo-periphery/transport-ssh.sh
    source "$TOOLBOX_ROOT/modules/komodo-periphery/transport-ssh.sh"
    # shellcheck source=modules/komodo-periphery/vm.sh
    source "$TOOLBOX_ROOT/modules/komodo-periphery/vm.sh"
}
module_install() { _kp_load; kp_host_change install; }
module_update() {
    _kp_load
    if [[ ${1:-} == --check ]]; then local rc=0; kp_host_check || rc=1; kp_vm_check || rc=1; return "$rc"; fi
    if [[ ${TOOLBOX_UPDATE_EXPLICIT:-0} != 1 ]]; then
        info 'Periphery updates require explicit selection: pve-toolbox update komodo-periphery'
        return 0
    fi
    kp_host_change update
}
module_status() {
    if ! conf_exists komodo-periphery && ! conf_exists komodo-periphery-qemu; then printf 'not installed'; return 1; fi
    printf 'configured'
}
module_status_long() { _kp_load; local rc=0; kp_host_status || rc=1; kp_vm_status || rc=1; return "$rc"; }
module_doctor() { _kp_load; local output rc=0; output=$(module_status_long 2>&1) || rc=$?; if [[ $rc == 0 ]]; then doctor_result warn agents 'local service checks complete; Core connectivity unverified' "$output"; else doctor_result fail agents 'one or more managed agents require attention' "$output"; fi; }
module_uninstall() { _kp_load; kp_host_change uninstall; }
