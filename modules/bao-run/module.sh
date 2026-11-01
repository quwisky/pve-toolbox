# shellcheck shell=bash
# Discovery must not inspect or change containers.
# shellcheck disable=SC2034
MODULE_NAME="bao-run"
MODULE_TITLE="OpenBao secrets for Komodo stacks"
MODULE_DESC="install and manage the bao-run compose wrapper and its AppRole credentials in selected containers"
MODULE_TAGS="lxc komodo openbao secrets"
MODULE_HOST_ONLY=1
MODULE_EXPLICIT_UPDATE=1
# BR_ADDR is public only because br_valid_addr refuses embedded credentials.
MODULE_CONFIG_PUBLIC="BR_IDS BR_ADDR BR_ROLES BR_PERIPHERY BR_CONTAINER BR_IDENTITY BR_PENDING"

# One record per saved CT. Read-only, conf_get only; the list splits on
# whitespace with globbing off, and an invalid ID names no file.
module_config_files() {
    local -
    set -f
    local IFS=$' \t\n' id
    for id in $(conf_get bao-run BR_IDS); do
        if [[ $id =~ ^[1-9][0-9]{2,8}$ ]]; then printf 'bao-run-%s\n' "$id"; fi
    done
}

_br_load() {
    # shellcheck source=modules/bao-run/host.sh
    source "$TOOLBOX_ROOT/modules/bao-run/host.sh"
}
module_install() { _br_load; br_change install; }
module_update() {
    _br_load
    if [[ ${1:-} == --check ]]; then br_check; return; fi
    if [[ ${TOOLBOX_UPDATE_EXPLICIT:-0} != 1 ]]; then
        info 'bao-run updates require explicit selection: pve-toolbox update bao-run'
        return 0
    fi
    br_change update
}
module_status() {
    if ! conf_exists bao-run; then printf 'not installed'; return 1; fi
    printf 'configured'
}
module_status_long() {
    if ! conf_exists bao-run; then printf 'not installed\n'; return 1; fi
    _br_load
    br_status
}
module_doctor() { _br_load; br_doctor; }
module_uninstall() { _br_load; br_change uninstall; }
