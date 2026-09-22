# shellcheck shell=bash
# Discovery must not inspect or change containers.
# shellcheck disable=SC2034
MODULE_NAME="komodo-periphery"
MODULE_TITLE="Komodo Periphery in LXC"
MODULE_DESC="install, update or reconfigure a systemd agent in an existing local container"
MODULE_TAGS="lxc komodo periphery agent"
MODULE_HOST_ONLY=1
MODULE_EXPLICIT_UPDATE=1

_kp_load() {
    # shellcheck source=modules/komodo-periphery/host.sh
    source "$TOOLBOX_ROOT/modules/komodo-periphery/host.sh"
}
module_install() { _kp_load; kp_host_change install; }
module_update() {
    _kp_load
    if [[ ${1:-} == --check ]]; then kp_host_check; return; fi
    if [[ ${TOOLBOX_UPDATE_EXPLICIT:-0} != 1 ]]; then
        info 'Periphery updates require explicit selection: pve-toolbox update komodo-periphery'
        return 0
    fi
    kp_host_change update
}
module_status() {
    if ! conf_exists komodo-periphery; then printf 'not installed'; return 1; fi
    printf 'configured'
}
module_status_long() { _kp_load; kp_host_status; }
module_doctor() { _kp_load; kp_host_doctor; }
module_uninstall() { _kp_load; kp_host_change uninstall; }
