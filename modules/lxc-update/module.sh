# shellcheck shell=bash
# Module discovery must not probe or modify guests.
# shellcheck disable=SC2034
MODULE_NAME="lxc-update"
MODULE_TITLE="LXC package updates"
MODULE_DESC="confirmed or scheduled local Debian/Ubuntu package updates"
MODULE_TAGS="lxc upgrade apt notify schedule"
MODULE_HOST_ONLY=1

LX_UNIT="pve-toolbox-lxc-update"
LX_BIN="pve-toolbox-lxc-update"
LX_DEFAULT_SCHEDULE="Sun *-*-* 04:00:00"

_lx_dir() { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}" "$MODULE_NAME"; }
_lx_src() { printf '%s/run.sh' "$(_lx_dir)"; }
_lx_guest_src() { printf '%s/guest.sh' "$(_lx_dir)"; }
_lx_runner() { printf '%s/%s' "$TOOLBOX_BIN_DIR" "$LX_BIN"; }
_lx_guest() { printf '%s/lxc-update-guest.sh' "$TOOLBOX_LIB_DIR"; }
_lx_lib_src() { printf '%s/lib/%s' "${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}" "$1"; }
_lx_service() { printf '%s/%s.service' "$TOOLBOX_SYSTEMD_DIR" "$LX_UNIT"; }
_lx_timer() { printf '%s/%s.timer' "$TOOLBOX_SYSTEMD_DIR" "$LX_UNIT"; }
_lx_exec() {
    printf '/usr/bin/env PVE_TOOLBOX_LIB=%s LX_GUEST_HELPER=%s TOOLBOX_CONF_DIR=%s TOOLBOX_STATE_DIR=%s %s --scheduled' \
        "$TOOLBOX_LIB_DIR" "$(_lx_guest)" "$TOOLBOX_CONF_DIR" \
        "$TOOLBOX_STATE_DIR" "$(_lx_runner)"
}

_lx_valid_schedule() {
    local output
    [[ -n ${1:-} ]] || return 1
    command -v systemd-analyze >/dev/null 2>&1 || return 1
    output=$(LC_ALL=C systemd-analyze calendar --iterations=1 "$1" 2>/dev/null) \
        || return 1
    [[ $output == *'Next elapse:'* && $output != *'Next elapse: never'* ]]
}

_lx_schedule_preset() { # _lx_schedule_preset <daily|weekly>
    case $1 in
        daily) printf '*-*-* 04:00:00' ;;
        weekly) printf '%s' "$LX_DEFAULT_SCHEDULE" ;;
        *) return 1 ;;
    esac
}

_lx_schedule_kind() { # _lx_schedule_kind <OnCalendar>
    case $1 in
        '*-*-* 04:00:00') printf daily ;;
        "$LX_DEFAULT_SCHEDULE") printf weekly ;;
        *) printf custom ;;
    esac
}

_lx_write_units() { # _lx_write_units <OnCalendar>
    local schedule=$1 service timer work
    service=$(_lx_service); timer=$(_lx_timer)
    _lx_valid_schedule "$schedule" \
        || { warn "invalid systemd OnCalendar: $schedule"; return 1; }
    [[ -d $TOOLBOX_SYSTEMD_DIR && ! -L $TOOLBOX_SYSTEMD_DIR ]] \
        || { warn "unsafe systemd unit directory: $TOOLBOX_SYSTEMD_DIR"; return 1; }
    [[ -d $TOOLBOX_BIN_DIR && ! -L $TOOLBOX_BIN_DIR ]] \
        || { warn "unsafe binary directory: $TOOLBOX_BIN_DIR"; return 1; }
    [[ ! -L $TOOLBOX_LIB_DIR && ( ! -e $TOOLBOX_LIB_DIR || -d $TOOLBOX_LIB_DIR ) ]] \
        || { warn "unsafe library directory: $TOOLBOX_LIB_DIR"; return 1; }
    for path in "$service" "$timer"; do
        [[ ! -L $path && ( ! -e $path || -f $path ) ]] \
            || { warn "unsafe LXC update unit path: $path"; return 1; }
    done
    for path in "$(_lx_runner)" "$(_lx_guest)" \
        "$TOOLBOX_LIB_DIR/common.sh" "$TOOLBOX_LIB_DIR/report.sh" \
        "$TOOLBOX_LIB_DIR/discord.sh"; do
        [[ ! -L $path && ( ! -e $path || -f $path ) ]] \
            || { warn "unsafe LXC scheduler runtime path: $path"; return 1; }
    done

    work=$(mktemp -d)
    cat > "$work/service" <<EOF
[Unit]
Description=pve-toolbox automatic LXC package updates
After=pve-cluster.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$(_lx_exec)
Nice=10
IOSchedulingClass=idle
UMask=0077
TimeoutStartSec=infinity
TimeoutStopSec=infinity
KillMode=process
StandardOutput=journal
StandardError=journal
EOF
    cat > "$work/timer" <<EOF
[Unit]
Description=pve-toolbox automatic LXC package updates (timer)

[Timer]
OnCalendar=$schedule
RandomizedDelaySec=1800
AccuracySec=1s
Persistent=false
Unit=$LX_UNIT.service

[Install]
WantedBy=timers.target
EOF
    if ! install_toolbox_lib common.sh report.sh discord.sh \
        || ! install -m 0644 "$(_lx_guest_src)" "$(_lx_guest)" \
        || ! install -m 0755 "$(_lx_src)" "$(_lx_runner)" \
        || ! install -m 0644 "$work/service" "$service" \
        || ! install -m 0644 "$work/timer" "$timer" \
        || ! systemctl daemon-reload \
        || ! systemctl enable --now "$LX_UNIT.timer" >/dev/null 2>&1; then
        rm -rf -- "$work"
        warn "could not install and enable $LX_UNIT.timer"
        return 1
    fi
    rm -rf -- "$work"
    ok "enabled $LX_UNIT.timer ($schedule, delay up to 30 minutes)"
}

_lx_stop_timer() {
    local timer known=0
    timer=$(_lx_timer)
    if [[ -e $timer || -L $timer ]] \
        || systemctl is-enabled --quiet "$LX_UNIT.timer" 2>/dev/null \
        || systemctl is-active --quiet "$LX_UNIT.timer" 2>/dev/null \
        || systemctl is-failed --quiet "$LX_UNIT.timer" 2>/dev/null; then
        known=1
    fi
    [[ $known == 0 ]] && return 0
    if ! systemctl disable --now "$LX_UNIT.timer" >/dev/null 2>&1; then
        warn "could not disable and stop $LX_UNIT.timer"
        return 1
    fi
}

_lx_remove_units() {
    local service timer path timer_failed=0 service_failed=0
    service=$(_lx_service); timer=$(_lx_timer)
    for path in "$service" "$timer"; do
        [[ ! -L $path && ( ! -e $path || -f $path ) ]] \
            || { warn "unsafe LXC update unit path: $path"; return 1; }
    done
    systemctl is-failed --quiet "$LX_UNIT.timer" 2>/dev/null && timer_failed=1
    systemctl is-failed --quiet "$LX_UNIT.service" 2>/dev/null && service_failed=1
    _lx_stop_timer || return 1
    rm -f -- "$service" "$timer" || return 1
    systemctl daemon-reload || return 1
    if [[ $timer_failed == 1 ]] \
        && ! systemctl reset-failed "$LX_UNIT.timer" >/dev/null 2>&1; then
        warn "could not clear the failed $LX_UNIT.timer state"
        return 1
    fi
    if [[ $service_failed == 1 ]] \
        && ! systemctl reset-failed "$LX_UNIT.service" >/dev/null 2>&1; then
        warn "could not clear the failed $LX_UNIT.service state"
        return 1
    fi
}

_lx_backup_one() { # _lx_backup_one <source> <backup>
    if [[ -L $1 || ( -e $1 && ! -f $1 ) ]]; then
        warn "unsafe LXC scheduler path: $1"
        return 1
    elif [[ -f $1 ]]; then
        cp -a -- "$1" "$2"
    else
        : > "$2.missing"
    fi
}

_lx_restore_one() { # _lx_restore_one <backup> <target>
    rm -f -- "$2"
    [[ -f $1.missing ]] || cp -a -- "$1" "$2"
}

_lx_backup_install() { # _lx_backup_install <directory>
    _lx_backup_one "$(conf_file "$MODULE_NAME")" "$1/config" \
        && _lx_backup_one "$(_lx_runner)" "$1/runner" \
        && _lx_backup_one "$(_lx_guest)" "$1/guest" \
        && _lx_backup_one "$TOOLBOX_LIB_DIR/common.sh" "$1/common" \
        && _lx_backup_one "$TOOLBOX_LIB_DIR/report.sh" "$1/report" \
        && _lx_backup_one "$TOOLBOX_LIB_DIR/discord.sh" "$1/discord" \
        && _lx_backup_one "$(_lx_service)" "$1/service" \
        && _lx_backup_one "$(_lx_timer)" "$1/timer" \
        || return 1
    if systemctl is-enabled --quiet "$LX_UNIT.timer" 2>/dev/null; then
        : > "$1/timer-enabled"
    fi
}

_lx_restore_install() { # _lx_restore_install <directory>
    _lx_restore_one "$1/config" "$(conf_file "$MODULE_NAME")" || return 1
    _lx_stop_timer || return 1
    _lx_restore_one "$1/runner" "$(_lx_runner)" \
        && _lx_restore_one "$1/guest" "$(_lx_guest)" \
        && _lx_restore_one "$1/common" "$TOOLBOX_LIB_DIR/common.sh" \
        && _lx_restore_one "$1/report" "$TOOLBOX_LIB_DIR/report.sh" \
        && _lx_restore_one "$1/discord" "$TOOLBOX_LIB_DIR/discord.sh" \
        && _lx_restore_one "$1/service" "$(_lx_service)" \
        && _lx_restore_one "$1/timer" "$(_lx_timer)" \
        && systemctl daemon-reload \
        || return 1
    if [[ -f $1/timer-enabled ]]; then
        systemctl enable --now "$LX_UNIT.timer" >/dev/null 2>&1 || return 1
    fi
}

_lx_write_config() { # enabled schedule notify exclusions webhook
    conf_set "$MODULE_NAME" LX_EXCLUDE "$4" \
        && conf_set "$MODULE_NAME" DISCORD_WEBHOOK "$5" \
        && conf_set "$MODULE_NAME" LX_SCHEDULE_ENABLED "$1" \
        && conf_set "$MODULE_NAME" LX_SCHEDULE "$2" \
        && conf_set "$MODULE_NAME" LX_SCHEDULE_NOTIFY "$3"
}

_lx_enabled() { [[ $(conf_get "$MODULE_NAME" LX_SCHEDULE_ENABLED) == 1 ]]; }
_lx_enabled_setting_valid() {
    case $(conf_get "$MODULE_NAME" LX_SCHEDULE_ENABLED) in ''|0|1) return 0 ;; *) return 1 ;; esac
}
_lx_unit_files_exist() {
    [[ -e $(_lx_service) || -L $(_lx_service) \
        || -e $(_lx_timer) || -L $(_lx_timer) ]]
}
_lx_units_exist() {
    _lx_unit_files_exist \
        || systemctl is-enabled --quiet "$LX_UNIT.timer" 2>/dev/null \
        || systemctl is-active --quiet "$LX_UNIT.timer" 2>/dev/null \
        || systemctl is-failed --quiet "$LX_UNIT.timer" 2>/dev/null
}
_lx_assets_exist() {
    [[ -e $(_lx_runner) || -L $(_lx_runner) \
        || -e $(_lx_guest) || -L $(_lx_guest) \
        || -e $(_lx_service) || -L $(_lx_service) \
        || -e $(_lx_timer) || -L $(_lx_timer) ]]
}

_lx_config_health() {
    local schedule
    schedule=$(conf_get "$MODULE_NAME" LX_SCHEDULE)
    _lx_valid_schedule "$schedule" \
        || { LX_HEALTH_REASON="configured schedule is invalid"; return 1; }
    [[ $(conf_get "$MODULE_NAME" LX_SCHEDULE_NOTIFY) =~ ^[01]$ ]] \
        || { LX_HEALTH_REASON="automatic notification setting is invalid"; return 1; }
    if [[ $(conf_get "$MODULE_NAME" LX_SCHEDULE_NOTIFY) == 1 ]]; then
        local webhook
        webhook=$(conf_get "$MODULE_NAME" DISCORD_WEBHOOK)
        [[ $webhook =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+$ ]] \
            || { LX_HEALTH_REASON="automatic Discord webhook is invalid"; return 1; }
    fi
}

_lx_runtime_health() { # _lx_runtime_health <OnCalendar>
    local schedule=$1 service timer lib
    service=$(_lx_service); timer=$(_lx_timer)
    [[ -f $(_lx_runner) && ! -L $(_lx_runner) && -x $(_lx_runner) ]] \
        || { LX_HEALTH_REASON="scheduled runner is missing or unsafe"; return 1; }
    cmp -s "$(_lx_src)" "$(_lx_runner)" \
        || { LX_HEALTH_REASON="scheduled runner differs from this toolbox"; return 1; }
    [[ -f $(_lx_guest) && ! -L $(_lx_guest) ]] \
        || { LX_HEALTH_REASON="scheduled guest helper is missing or unsafe"; return 1; }
    cmp -s "$(_lx_guest_src)" "$(_lx_guest)" \
        || { LX_HEALTH_REASON="scheduled guest helper differs from this toolbox"; return 1; }
    for lib in common.sh report.sh discord.sh; do
        [[ -f $TOOLBOX_LIB_DIR/$lib && ! -L $TOOLBOX_LIB_DIR/$lib ]] \
            || { LX_HEALTH_REASON="scheduled library $lib is missing or unsafe"; return 1; }
        cmp -s "$(_lx_lib_src "$lib")" "$TOOLBOX_LIB_DIR/$lib" \
            || { LX_HEALTH_REASON="scheduled library $lib differs from this toolbox"; return 1; }
    done
    [[ -f $service && ! -L $service ]] \
        || { LX_HEALTH_REASON="service file is missing or unsafe"; return 1; }
    [[ -f $timer && ! -L $timer ]] \
        || { LX_HEALTH_REASON="timer file is missing or unsafe"; return 1; }
    grep -Fqx "ExecStart=$(_lx_exec)" "$service" \
        || { LX_HEALTH_REASON="service command differs from configuration"; return 1; }
    if ! grep -Fqx 'TimeoutStartSec=infinity' "$service" \
        || ! grep -Fqx 'TimeoutStopSec=infinity' "$service" \
        || ! grep -Fqx 'KillMode=process' "$service"; then
        LX_HEALTH_REASON="service transaction protection is incomplete"
        return 1
    fi
    grep -Fqx "OnCalendar=$schedule" "$timer" \
        || { LX_HEALTH_REASON="timer schedule differs from configuration"; return 1; }
    if ! grep -Fqx 'Persistent=false' "$timer"; then
        LX_HEALTH_REASON="timer catch-up policy is unsafe"
        return 1
    fi
    if ! grep -Fqx 'RandomizedDelaySec=1800' "$timer" \
        || ! grep -Fqx 'AccuracySec=1s' "$timer"; then
        LX_HEALTH_REASON="timer delay policy differs from configuration"
        return 1
    fi
}

_lx_health() {
    LX_HEALTH_REASON=""
    local schedule
    schedule=$(conf_get "$MODULE_NAME" LX_SCHEDULE)
    _lx_config_health || return 1
    _lx_runtime_health "$schedule" || return 1
    systemctl is-enabled --quiet "$LX_UNIT.timer" 2>/dev/null \
        || { LX_HEALTH_REASON="timer is disabled"; return 1; }
    if systemctl is-failed --quiet "$LX_UNIT.timer" 2>/dev/null; then
        LX_HEALTH_REASON="automatic update timer failed"
        return 1
    fi
    systemctl is-active --quiet "$LX_UNIT.timer" 2>/dev/null \
        || { LX_HEALTH_REASON="timer is inactive"; return 1; }
    if systemctl is-failed --quiet "$LX_UNIT.service" 2>/dev/null; then
        LX_HEALTH_REASON="last automatic update service failed"
        return 1
    fi
}

_lx_lock_idle() {
    command -v flock >/dev/null 2>&1 || die "missing host command: flock"
    [[ ! -L $TOOLBOX_STATE_DIR ]] || die "unsafe state directory"
    mkdir -p "$TOOLBOX_STATE_DIR"
    local lock="$TOOLBOX_STATE_DIR/lxc-update.lock"
    [[ ! -L $lock && ( ! -e $lock || -f $lock ) ]] \
        || die "unsafe LXC updater lock path"
    exec {LX_CHANGE_LOCK}>"$lock"
    flock -n "$LX_CHANGE_LOCK" \
        || die "an LXC update batch is active; retry the module update after it finishes"
}

module_install() {
    require_root
    local requested_enabled=${LX_SCHEDULE_ENABLED:-}
    local requested_preset=${LX_SCHEDULE_PRESET:-}
    local requested_schedule=${LX_SCHEDULE:-}
    local requested_notify=${LX_SCHEDULE_NOTIFY:-}
    local LX_EXCLUDE="" DISCORD_WEBHOOK="" LX_SCHEDULE_ENABLED=0
    local LX_SCHEDULE="$LX_DEFAULT_SCHEDULE" LX_SCHEDULE_NOTIFY=0
    local id replacement="" schedule_enabled schedule_notify schedule_preset rollback install_failed=0
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    [[ -z $requested_enabled ]] || LX_SCHEDULE_ENABLED=$requested_enabled
    [[ -z $requested_schedule ]] || LX_SCHEDULE=$requested_schedule
    [[ -z $requested_notify ]] || LX_SCHEDULE_NOTIFY=$requested_notify
    ask LX_EXCLUDE "Excluded container IDs, space-separated (use none to clear)" "${LX_EXCLUDE:-none}"
    [[ $LX_EXCLUDE != none ]] || LX_EXCLUDE=""
    for id in $LX_EXCLUDE; do
        [[ $id =~ ^[1-9][0-9]{2,8}$ ]] || { warn "invalid container ID: $id"; return 1; }
    done
    if [[ $ASSUME_YES == 0 ]]; then
        ask_secret replacement "Discord webhook URL (blank keeps existing; none clears)"
        [[ -z $replacement ]] || DISCORD_WEBHOOK=$replacement
    fi
    [[ $DISCORD_WEBHOOK != none ]] || DISCORD_WEBHOOK=""

    schedule_enabled=n
    case ${LX_SCHEDULE_ENABLED,,} in 1|y|yes) schedule_enabled=y ;; esac
    ask_yn schedule_enabled "Enable automatic LXC package updates" "$schedule_enabled"
    if [[ $schedule_enabled == y ]]; then
        schedule_preset=${requested_preset:-$(_lx_schedule_kind "$LX_SCHEDULE")}
        while true; do
            ask schedule_preset "Schedule preset (daily, weekly, custom)" "$schedule_preset"
            case ${schedule_preset,,} in
                daily|weekly)
                    LX_SCHEDULE=$(_lx_schedule_preset "${schedule_preset,,}")
                    break ;;
                custom)
                    ask LX_SCHEDULE "systemd OnCalendar" "$LX_SCHEDULE"
                    _lx_valid_schedule "$LX_SCHEDULE" && break
                    [[ $ASSUME_YES -eq 1 ]] && die "invalid systemd OnCalendar: $LX_SCHEDULE"
                    warn "invalid systemd OnCalendar: $LX_SCHEDULE" ;;
                *)
                    [[ $ASSUME_YES -eq 1 ]] \
                        && die "schedule preset must be daily, weekly, or custom"
                    warn "choose daily, weekly, or custom" ;;
            esac
        done
        _lx_valid_schedule "$LX_SCHEDULE" || die "invalid systemd OnCalendar: $LX_SCHEDULE"
        schedule_notify=n
        case ${LX_SCHEDULE_NOTIFY,,} in 1|y|yes) schedule_notify=y ;; esac
        ask_yn schedule_notify "Send a Discord report after every automatic run" "$schedule_notify"
        if [[ $schedule_notify == y ]]; then
            [[ $DISCORD_WEBHOOK =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+$ ]] \
                || die "automatic reports require a configured Discord webhook"
        fi
    else
        schedule_notify=n
        case ${LX_SCHEDULE_NOTIFY,,} in 1|y|yes) schedule_notify=y ;; esac
    fi

    _lx_lock_idle
    rollback=$(mktemp -d)
    _lx_backup_install "$rollback" \
        || { rm -rf -- "$rollback"; die "could not back up the existing LXC scheduler"; }
    trap '_lx_restore_install "$rollback" >/dev/null 2>&1 || true; rm -rf -- "$rollback"; exit 130' INT TERM HUP
    if ! _lx_write_config \
        "$([[ $schedule_enabled == y ]] && printf 1 || printf 0)" \
        "$LX_SCHEDULE" \
        "$([[ $schedule_notify == y ]] && printf 1 || printf 0)" \
        "$LX_EXCLUDE" "$DISCORD_WEBHOOK"; then
        install_failed=1
    elif [[ $schedule_enabled == y ]]; then
        _lx_write_units "$LX_SCHEDULE" || install_failed=1
    else
        _lx_remove_units || install_failed=1
    fi
    if [[ $install_failed == 1 ]]; then
        if ! _lx_restore_install "$rollback"; then
            rm -rf -- "$rollback"
            die "LXC scheduler configuration failed and its previous state could not be restored"
        fi
        rm -rf -- "$rollback"
        trap - INT TERM HUP
        warn "LXC scheduler configuration failed; restored the previous state"
        return 1
    fi
    rm -rf -- "$rollback"
    trap - INT TERM HUP
    [[ $schedule_enabled == y ]] || ok "automatic LXC package updates disabled"
    ok "configured; run pve-toolbox lxc-update --dry-run to preview"
}

module_update() {
    require_root
    conf_exists "$MODULE_NAME" || die "not installed"
    local check_only=0 schedule drift=0
    [[ ${1:-} == --check ]] && check_only=1
    _lx_enabled_setting_valid \
        || die "invalid automatic update setting; reconfigure lxc-update"

    if ! _lx_enabled; then
        if ! _lx_units_exist; then
            info "automatic LXC updates are disabled; guest packages unchanged"
            return 0
        fi
        if [[ $check_only == 1 ]]; then
            info "update available: remove scheduler units disabled by configuration"
            return 0
        fi
        _lx_remove_units || die "could not remove scheduler units disabled by configuration"
        ok "removed scheduler units; automatic LXC updates remain disabled"
        return 0
    fi
    schedule=$(conf_get "$MODULE_NAME" LX_SCHEDULE)
    LX_HEALTH_REASON=""
    _lx_config_health || die "$LX_HEALTH_REASON; reconfigure lxc-update"
    _lx_runtime_health "$schedule" || drift=1
    systemctl is-enabled --quiet "$LX_UNIT.timer" 2>/dev/null || drift=1
    systemctl is-active --quiet "$LX_UNIT.timer" 2>/dev/null || drift=1
    if systemctl is-failed --quiet "$LX_UNIT.timer" 2>/dev/null; then drift=1; fi
    if [[ $drift == 0 && ${FORCE:-0} == 0 ]]; then
        ok "up to date; automatic updates remain $schedule"
        return 0
    fi
    if [[ $check_only == 1 ]]; then
        info "update available: the scheduled runner or units are out of sync"
        return 0
    fi

    _lx_lock_idle
    local rollback
    rollback=$(mktemp -d)
    _lx_backup_install "$rollback" \
        || { rm -rf -- "$rollback"; die "could not back up the existing LXC scheduler"; }
    trap '_lx_restore_install "$rollback" >/dev/null 2>&1 || true; rm -rf -- "$rollback"; exit 130' INT TERM HUP
    if ! _lx_write_units "$schedule"; then
        if ! _lx_restore_install "$rollback"; then
            rm -rf -- "$rollback"
            trap - INT TERM HUP
            die "scheduled runner update failed and its previous state could not be restored"
        fi
        rm -rf -- "$rollback"
        trap - INT TERM HUP
        die "scheduled runner update failed; restored the previous state"
    fi
    rm -rf -- "$rollback"
    trap - INT TERM HUP
    ok "scheduled runner updated; guest packages unchanged"
}

module_status() {
    if ! conf_exists "$MODULE_NAME"; then
        if _lx_assets_exist; then
            printf 'degraded  [scheduler files exist without configuration]'
            return 0
        fi
        printf 'not installed'
        return 1
    fi
    if ! _lx_enabled_setting_valid; then
        printf 'degraded  [automatic update setting is invalid]'
        return 0
    fi
    if ! _lx_enabled; then
        if _lx_units_exist; then
            printf 'degraded  [scheduler files remain while automatic updates are disabled]'
        else
            printf 'configured (manual updates)'
        fi
    elif _lx_health; then
        printf 'scheduled  [%s]' "$(conf_get "$MODULE_NAME" LX_SCHEDULE)"
    else
        printf 'degraded  [%s]' "$LX_HEALTH_REASON"
    fi
}

module_status_long() {
    local status schedule next last_trigger invocation started completed overlap ids id value
    local degraded=0 health_ok=1 enabled_valid=1
    status=$(module_status) || { printf '%s' "$status"; return 1; }
    if ! conf_exists "$MODULE_NAME"; then
        printf '%s\n' "$status"
        printf 'Configuration: missing; reinstall or uninstall the module to repair this state\n'
        return 1
    fi
    [[ $status != degraded* ]] || degraded=1
    schedule=$(conf_get "$MODULE_NAME" LX_SCHEDULE)
    if ! _lx_enabled_setting_valid; then
        enabled_valid=0
        health_ok=0
    elif _lx_enabled; then
        if ! _lx_health; then
            status="degraded  [$LX_HEALTH_REASON]"
            degraded=1
            health_ok=0
        fi
    elif _lx_units_exist; then
        status='degraded  [scheduler files remain while automatic updates are disabled]'
        degraded=1
    fi
    printf '%s\n' "$status"
    if [[ $enabled_valid == 0 ]]; then
        printf 'Automatic updates: invalid configuration\n'
        printf 'Saved schedule: %s\n' "${schedule:-$LX_DEFAULT_SCHEDULE}"
    elif _lx_enabled; then
        printf 'Automatic updates: enabled\n'
        printf 'Schedule: %s (host local time, delay up to 30 minutes)\n' "$schedule"
        [[ $health_ok == 1 ]] \
            || printf 'Schedule health: degraded - %s\n' "$LX_HEALTH_REASON"
        next=$(systemctl show "$LX_UNIT.timer" \
            --property=NextElapseUSecRealtime --value 2>/dev/null) || next=""
        last_trigger=$(systemctl show "$LX_UNIT.timer" \
            --property=LastTriggerUSec --value 2>/dev/null) || last_trigger=""
        if [[ -n $next ]]; then
            printf 'Next run: %s\n' "$next"
        else
            printf 'Next run: unavailable\n'
        fi
        printf 'Last timer trigger: %s\n' "${last_trigger:-never}"
        printf 'Automatic Discord report: %s\n' \
            "$([[ $(conf_get "$MODULE_NAME" LX_SCHEDULE_NOTIFY) == 1 ]] && printf enabled || printf disabled)"
        printf 'Start now: systemctl start %s.service\n' "$LX_UNIT"
        printf 'Journal: journalctl -u %s.service\n' "$LX_UNIT"
    else
        printf 'Automatic updates: disabled\n'
        printf 'Saved schedule: %s\n' "${schedule:-$LX_DEFAULT_SCHEDULE}"
    fi
    printf 'Excluded IDs: %s\n' "$(conf_get "$MODULE_NAME" LX_EXCLUDE)"
    if [[ -n $(conf_get "$MODULE_NAME" DISCORD_WEBHOOK) ]]; then
        printf 'Discord webhook: configured (manual and optional automatic reports)\n'
    fi
    invocation=$(state_get "$MODULE_NAME" invocation)
    started=$(state_get "$MODULE_NAME" started_at)
    completed=$(state_get "$MODULE_NAME" completed_at)
    printf 'Invocation: %s\n' "${invocation:-none}"
    printf 'Started: %s\n' "${started:-never}"
    printf 'Completed: %s\n' "${completed:-never}"
    printf 'Last run: %s\n' "$(state_get "$MODULE_NAME" last_summary)"
    overlap=$(state_get lxc-update-overlap skipped_at)
    printf 'Last overlap skip: %s\n' "${overlap:-never}"
    printf 'Last report: %s/lxc-update.state\n' "$TOOLBOX_STATE_DIR"
    ids=$(state_get "$MODULE_NAME" container_ids)
    for id in $ids; do
        [[ $id =~ ^[1-9][0-9]{2,8}$ ]] || continue
        value=$(state_get "$MODULE_NAME" "ct_$id")
        printf 'ct_%s %s\n' "$id" "$value"
    done
    return "$degraded"
}

module_doctor() {
    if ! conf_exists "$MODULE_NAME"; then
        doctor_result fail configuration "scheduler files exist without configuration"
    elif ! _lx_enabled_setting_valid; then
        doctor_result fail schedule "automatic update setting is invalid"
    elif ! _lx_enabled && _lx_units_exist; then
        doctor_result fail schedule "scheduler files remain while automatic updates are disabled"
    elif ! _lx_enabled; then
        doctor_result pass schedule "automatic LXC updates are disabled"
    elif _lx_health; then
        doctor_result pass schedule "automatic LXC update timer is healthy" \
            "$(conf_get "$MODULE_NAME" LX_SCHEDULE)"
    else
        doctor_result fail schedule "$LX_HEALTH_REASON"
    fi
}

module_uninstall() {
    require_root
    _lx_lock_idle
    _lx_remove_units || die "could not remove the LXC update units"
    local path
    for path in "$(_lx_runner)" "$(_lx_guest)"; do
        [[ ! -e $path || -f $path || -L $path ]] \
            || die "unsafe scheduled runtime path: $path"
    done
    rm -f -- "$(_lx_runner)" "$(_lx_guest)" \
        || die "could not remove the scheduled runtime"
    conf_clear "$MODULE_NAME" || die "could not remove the LXC updater configuration"
    # Retain reports and the lock inode; shared libraries may serve other modules.
    ok "removed LXC updater configuration; last report retained"
}
