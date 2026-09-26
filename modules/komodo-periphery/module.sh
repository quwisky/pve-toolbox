# shellcheck shell=bash
# Discovery must not inspect or change containers.
# shellcheck disable=SC2034
MODULE_NAME="komodo-periphery"
MODULE_TITLE="Komodo Periphery in LXC or VM"
MODULE_DESC="install or manage a systemd agent in a selected local container or VM"
MODULE_TAGS="lxc vm qemu komodo periphery agent"
MODULE_HOST_ONLY=1
MODULE_EXPLICIT_UPDATE=1

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
