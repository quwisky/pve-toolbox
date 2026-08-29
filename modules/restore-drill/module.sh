# shellcheck shell=bash
# Configure the explicitly invoked isolated restore-drill helper.
# shellcheck disable=SC2034
MODULE_NAME="restore-drill"
MODULE_TITLE="Restore drill"
MODULE_DESC="guarded, isolated VM and container backup restore validation"
MODULE_TAGS="backup restore audit isolation notify"
MODULE_HOST_ONLY=1

RD_BIN="pve-toolbox-restore-drill"
RD_CONF_KEYS=(RD_STORAGE RD_VMID_START RD_BOOT_PROBE RD_BOOT_TIMEOUT RD_ALLOW_UNATTENDED)
RD_ERROR=""

_rd_dir() { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}" "$MODULE_NAME"; }
_rd_src() { printf '%s/%s' "$(_rd_dir)" "$RD_BIN"; }
_rd_run_state() { printf '%s/restore-drill-run.state' "$TOOLBOX_STATE_DIR"; }
_rd_last_report() { printf '%s/restore-drill-last.state' "$TOOLBOX_STATE_DIR"; }

_rd_defaults() {
    : "${RD_STORAGE:=local-lvm}"
    : "${RD_VMID_START:=900000}"
    : "${RD_BOOT_PROBE:=1}"
    : "${RD_BOOT_TIMEOUT:=60}"
    : "${RD_ALLOW_UNATTENDED:=0}"
}

_rd_validate() {
    RD_ERROR=""
    [[ $RD_STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
        || { RD_ERROR="target storage name is invalid"; return 1; }
    [[ $RD_VMID_START =~ ^[1-9][0-9]*$ && $RD_VMID_START -le 999999999 ]] \
        || { RD_ERROR="VMID start must be between 1 and 999999999"; return 1; }
    [[ $RD_BOOT_PROBE =~ ^[01]$ && $RD_BOOT_TIMEOUT =~ ^[1-9][0-9]*$ \
        && $RD_ALLOW_UNATTENDED =~ ^[01]$ ]] \
        || { RD_ERROR="probe and unattended settings are invalid"; return 1; }
}

_rd_load() {
    _rd_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    _rd_validate
}

_rd_install_helper() {
    mkdir -p "$TOOLBOX_BIN_DIR"
    install -m 0755 "$(_rd_src)" "$TOOLBOX_BIN_DIR/$RD_BIN"
}

module_install() {
    require_root; require_pve; _rd_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    pkg_ensure flock:util-linux
    ask RD_STORAGE "isolated restore target storage" "$RD_STORAGE"
    ask RD_VMID_START "temporary VMID range start" "$RD_VMID_START"
    ask RD_BOOT_PROBE "boot probe (1 enabled, 0 disabled)" "$RD_BOOT_PROBE"
    ask RD_BOOT_TIMEOUT "boot probe timeout (seconds)" "$RD_BOOT_TIMEOUT"
    ask RD_ALLOW_UNATTENDED "allow explicit --unattended runs (1/0)" "$RD_ALLOW_UNATTENDED"
    _rd_validate || die "$RD_ERROR"
    local key; for key in "${RD_CONF_KEYS[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    _rd_install_helper
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"
    ok "installed guarded restore drill helper"
    dim "  default invocation only prints a plan"
}

module_update() {
    local check_only=0 key missing=() changed=0
    [[ ${1:-} == --check ]] && check_only=1
    conf_exists "$MODULE_NAME" || die "not installed"; _rd_defaults
    for key in "${RD_CONF_KEYS[@]}"; do [[ -n $(conf_get "$MODULE_NAME" "$key") ]] || missing+=("$key"); done
    [[ -x $TOOLBOX_BIN_DIR/$RD_BIN ]] || changed=1
    cmp -s "$(_rd_src)" "$TOOLBOX_BIN_DIR/$RD_BIN" || changed=1
    if [[ ${#missing[@]} -eq 0 && $changed -eq 0 ]]; then ok "restore drill is up to date"; return 0; fi
    if [[ $check_only -eq 1 ]]; then warn "restore drill update available"; return 0; fi
    for key in "${missing[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    _rd_install_helper
    ok "updated restore drill"
}

module_status() {
    conf_exists "$MODULE_NAME" && [[ -x $TOOLBOX_BIN_DIR/$RD_BIN ]] \
        || { printf 'not installed'; return 1; }
    if [[ -f $(_rd_run_state) ]]; then printf 'attention: unfinished drill'; else printf 'ready, dry-run by default'; fi
}

module_status_long() {
    module_status || return 1; printf '\n'
    if _rd_load; then
        printf '  storage       %s\n' "$RD_STORAGE"
        printf '  VMID start    %s\n' "$RD_VMID_START"
        printf '  boot probe    %s (%ss)\n' "$RD_BOOT_PROBE" "$RD_BOOT_TIMEOUT"
        printf '  unattended    %s (still requires --unattended)\n' "$RD_ALLOW_UNATTENDED"
        [[ ! -f $(_rd_last_report) ]] || printf '  last report   %s\n' "$(_rd_last_report)"
    fi
}

module_doctor() {
    if [[ ! -x $TOOLBOX_BIN_DIR/$RD_BIN ]]; then
        doctor_result fail helper "restore drill helper is missing"
    else
        doctor_result pass helper "restore drill helper is installed"
    fi
    if [[ -f $(_rd_run_state) ]]; then
        local phase
        phase=$(awk -F= '$1 == "PHASE" { print $2; exit }' "$(_rd_run_state)")
        case $phase in
            probe-failed) doctor_result warn active-run "failed drill is preserved for inspection" \
                "cleanup explicitly with $RD_BIN --cleanup" ;;
            *) doctor_result fail active-run "unfinished restore drill needs operator attention" \
                "phase=${phase:-unknown}; inspect state before explicit cleanup" ;;
        esac
    else
        doctor_result pass active-run "no unfinished restore drill"
    fi
}

module_uninstall() {
    require_root
    [[ ! -e $(_rd_run_state) ]] \
        || die "unfinished drill state exists; inspect or clean it before uninstalling"
    rm -f -- "$TOOLBOX_BIN_DIR/$RD_BIN"
    conf_clear "$MODULE_NAME"; state_clear "$MODULE_NAME"
    ok "removed restore drill helper and configuration; retained the last drill report"
}
