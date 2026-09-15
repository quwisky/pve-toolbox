# shellcheck shell=bash disable=SC2034
# Move toolbox scrub schedules to Debian's native ZFS timer and service.
# This fragment is sourced by run-migrations.sh and must remain side-effect free.

MIGRATION_TARGET_VERSION=0.7.0
MIGRATION_FILES=(
    "${PVE_TOOLBOX_CONF_DIR:-/etc/pve-toolbox}/zfs-scrub.conf"
    "${PVE_TOOLBOX_STATE_DIR:-/var/lib/pve-toolbox}/zfs-scrub.state"
)
MIGRATION_SYSTEMD_FILES=()
MIGRATION_UNITS=()
MIGRATION_KEEP_UNIT_STATE=1

_M020_POOLS=()
_M020_SCHEDULES=()
_M020_RECOVER_STATE=0

_m020_error() {
    printf 'pve-toolbox: native ZFS scrub migration: %s\n' "$1" >&2
}

_m020_safe_file() {
    local path=$1 private=$2 mode
    [[ -f $path && ! -L $path ]] || return 1
    [[ $(stat -c '%u' "$path") -eq $EUID ]] || return 1
    mode=$(stat -c '%a' "$path")
    if [[ $private -eq 1 ]]; then
        (( (8#$mode & 077) == 0 ))
    else
        (( (8#$mode & 022) == 0 ))
    fi
}

_m020_state_pools() (
    local state=$1
    unset POOLS
    # Toolbox state contains only shell-quoted assignments and is read only
    # after its type, owner, and write permissions have been checked.
    # shellcheck source=/dev/null
    source "$state"
    printf '%s' "${POOLS:-}"
)

_m020_valid_pool() {
    [[ $1 =~ ^[A-Za-z][A-Za-z0-9_.:-]*$ ]]
}

_m020_schedule_from() {
    local timer=$1
    local -a calendars=()
    mapfile -t calendars < <(sed -n 's/^OnCalendar=//p' "$timer")
    [[ ${#calendars[@]} -eq 1 && -n ${calendars[0]} ]] || return 1
    printf '%s' "${calendars[0]}"
}

_m020_recovery_unit() { # require the protected, unmodified file systemd loaded
    local unit=$1 file=$2 value
    _m020_safe_file "$file" 0 || return 1
    value=$(systemctl show --property=FragmentPath --value "$unit" 2>/dev/null) \
        && [[ $value == "$file" ]] || return 1
    value=$(systemctl show --property=DropInPaths --value "$unit" 2>/dev/null) \
        && [[ -z $value ]] || return 1
    value=$(systemctl show --property=NeedDaemonReload --value "$unit" 2>/dev/null) \
        && [[ $value == no ]]
}

_m020_recovery_service() {
    local file=$1 conf=$2
    # Recognize the legacy runner and its config without sourcing credentials
    # or interpreting arbitrary service files as shell code.
    awk -v conf="Environment=SCRUB_CONF=$conf" \
        -v runner="ExecStart=${TOOLBOX_BIN_DIR:-/usr/local/bin}/pve-toolbox-zfs-scrub %i" '
        /^\[/ { service = ($0 == "[Service]") }
        service && /^[[:space:]]*ExecStart[[:space:]]*=/ {
            starts++; if ($0 != runner) bad = 1
        }
        service && /^[[:space:]]*Environment[[:space:]]*=/ && /SCRUB_CONF/ {
            configs++; if ($0 != conf) bad = 1
        }
        service && /^[[:space:]]*(EnvironmentFile|UnsetEnvironment)[[:space:]]*=/ { bad = 1 }
        END { exit !(starts == 1 && configs == 1 && !bad) }
    ' "$file"
}

migration_prepare() {
    local conf state systemd_dir timer pool schedule native monthly override
    local state_value state_pool old_state native_state monthly_state service target
    local -a timer_pools=() state_pools=()
    local -A timer_seen=() state_seen=()

    conf="${PVE_TOOLBOX_CONF_DIR:-/etc/pve-toolbox}/zfs-scrub.conf"
    state="${PVE_TOOLBOX_STATE_DIR:-/var/lib/pve-toolbox}/zfs-scrub.state"
    systemd_dir=${PVE_TOOLBOX_SYSTEMD_DIR:-/etc/systemd/system}
    _M020_POOLS=()
    _M020_SCHEDULES=()
    _M020_RECOVER_STATE=0
    MIGRATION_SYSTEMD_FILES=()
    MIGRATION_UNITS=()

    for timer in "$systemd_dir"/pve-toolbox-zfs-scrub@*.timer; do
        [[ -e $timer || -L $timer ]] || continue
        _m020_safe_file "$timer" 0 || {
            _m020_error "legacy timer is not a protected regular file: $timer"
            return 1
        }
        pool=${timer##*@}
        pool=${pool%.timer}
        _m020_valid_pool "$pool" || {
            _m020_error "legacy timer has an unsafe pool instance: $timer"
            return 1
        }
        [[ -z ${timer_seen[$pool]+x} ]] || {
            _m020_error "legacy timer repeats pool '$pool'"
            return 1
        }
        schedule=$(_m020_schedule_from "$timer") || {
            _m020_error "legacy timer for '$pool' has no single effective OnCalendar"
            return 1
        }
        systemd-analyze calendar "$schedule" >/dev/null 2>&1 || {
            _m020_error "legacy timer for '$pool' has an invalid OnCalendar: $schedule"
            return 1
        }
        timer_seen[$pool]=1
        timer_pools+=("$pool")
        _M020_SCHEDULES+=("$schedule")
    done

    if [[ ${#timer_pools[@]} -eq 0 && ! -e $conf && ! -L $conf \
        && ! -e $state && ! -L $state ]]; then
        return 0
    fi
    _m020_safe_file "$conf" 1 || {
        _m020_error "legacy config is missing or unsafe; expected a protected regular file: $conf"
        return 1
    }
    if [[ ! -e $state && ! -L $state ]]; then
        [[ ${#timer_pools[@]} -gt 0 ]] || {
            _m020_error "legacy state is missing and no timers establish installed pools; review the retained configuration: $conf"
            return 1
        }
        service="$systemd_dir/pve-toolbox-zfs-scrub@.service"
        _m020_safe_file "$service" 0 && _m020_recovery_service "$service" "$conf" || {
            _m020_error "legacy state is missing and the scrub service is missing, unsafe, or unrecognized; restore the original service and retry"
            return 1
        }
        for pool in "${timer_pools[@]}"; do
            timer="pve-toolbox-zfs-scrub@$pool.timer"
            target="pve-toolbox-zfs-scrub@$pool.service"
            _m020_recovery_unit "$timer" "$systemd_dir/$timer" \
                && _m020_recovery_unit "$target" "$service" || {
                _m020_error "cannot recover missing state for '$pool': legacy units have overrides, changed paths, or pending edits; review them before retrying"
                return 1
            }
            state_value=$(systemctl show --property=Unit --value "$timer" 2>/dev/null) \
                && [[ $state_value == "$target" ]] || {
                _m020_error "cannot recover missing state for '$pool': legacy timer does not target the expected scrub service"
                return 1
            }
        done
        # Legacy module status/update already use timer files as the pool
        # inventory. Rebuild only the derived facts needed by this migration.
        state_pools=("${timer_pools[@]}")
        _M020_RECOVER_STATE=1
    else
        _m020_safe_file "$state" 0 || {
            _m020_error "legacy state is unsafe; expected a protected regular file: $state"
            return 1
        }
        state_value=$(_m020_state_pools "$state") || {
            _m020_error "could not read the installed pool list from legacy state"
            return 1
        }
        read -r -a state_pools <<<"$state_value"
    fi
    [[ ${#state_pools[@]} -gt 0 ]] || {
        _m020_error "legacy state contains no installed pool list"
        return 1
    }
    for state_pool in "${state_pools[@]}"; do
        _m020_valid_pool "$state_pool" || {
            _m020_error "legacy state contains an unsafe pool name: $state_pool"
            return 1
        }
        [[ -z ${state_seen[$state_pool]+x} ]] || {
            _m020_error "legacy state repeats pool '$state_pool'"
            return 1
        }
        state_seen[$state_pool]=1
        [[ -n ${timer_seen[$state_pool]+x} ]] || {
            _m020_error "legacy state lists '$state_pool' without a timer"
            return 1
        }
    done
    [[ ${#state_pools[@]} -eq ${#timer_pools[@]} ]] || {
        _m020_error "legacy timer set does not match the installed pool list"
        return 1
    }

    systemctl cat zfs-scrub@.service >/dev/null 2>&1 \
        && systemctl cat zfs-scrub-weekly@.timer >/dev/null 2>&1 || {
        _m020_error "native zfs-scrub service and weekly timer are required"
        return 1
    }

    for pool in "${timer_pools[@]}"; do
        native="zfs-scrub-weekly@$pool.timer"
        monthly="zfs-scrub-monthly@$pool.timer"
        override="$systemd_dir/$native.d/override.conf"
        [[ ! -e ${override%/*} && ! -L ${override%/*} ]] || {
            _m020_error "native timer for '$pool' already has local overrides"
            return 1
        }
        old_state=$(systemctl is-enabled \
            "pve-toolbox-zfs-scrub@$pool.timer" 2>/dev/null || true)
        native_state=$(systemctl is-enabled "$native" 2>/dev/null || true)
        monthly_state=$(systemctl is-enabled "$monthly" 2>/dev/null || true)
        [[ $old_state == enabled || $old_state == disabled ]] || {
            _m020_error "legacy timer for '$pool' has unsupported enablement state '$old_state'"
            return 1
        }
        if [[ $native_state != disabled || $monthly_state != disabled ]] \
            || systemctl is-active --quiet "$native" >/dev/null 2>&1 \
            || systemctl is-active --quiet "$monthly" >/dev/null 2>&1; then
            _m020_error "native scrub scheduling for '$pool' is already enabled, masked, or otherwise claimed"
            return 1
        fi
        _M020_POOLS+=("$pool")
        MIGRATION_SYSTEMD_FILES+=("$override")
        MIGRATION_UNITS+=(
            "pve-toolbox-zfs-scrub@$pool.timer"
            "$native"
            "$monthly"
        )
    done
}

migration_apply() {
    local systemd_dir state pool schedule native monthly old override dir tmp i
    systemd_dir=${PVE_TOOLBOX_SYSTEMD_DIR:-/etc/systemd/system}
    state="${PVE_TOOLBOX_STATE_DIR}/zfs-scrub.state"
    [[ ${#_M020_POOLS[@]} -gt 0 ]] || return 0
    if [[ $_M020_RECOVER_STATE -eq 1 && ( -e $state || -L $state ) ]]; then
        _m020_error "legacy state appeared after recovery preparation; refusing to replace it"
        return 1
    fi

    for i in "${!_M020_POOLS[@]}"; do
        pool=${_M020_POOLS[$i]}
        schedule=${_M020_SCHEDULES[$i]}
        native="zfs-scrub-weekly@$pool.timer"
        override="$systemd_dir/$native.d/override.conf"
        dir=${override%/*}
        [[ ! -e $dir && ! -L $dir ]] || {
            _m020_error "refusing changed native timer override path for '$pool'"
            return 1
        }
        mkdir -- "$dir"
        chmod 0755 -- "$dir"
        cat > "$override" <<EOF
[Timer]
OnCalendar=
OnCalendar=$schedule
RandomizedDelaySec=1800
EOF
        chmod 0644 -- "$override"
    done
    systemctl daemon-reload >/dev/null 2>&1 || {
        _m020_error "could not reload systemd after writing native timer overrides"
        return 1
    }

    # Enabling a timer does not start it, so Persistent=true cannot launch a
    # missed scrub while dpkg is still configuring the package.
    for pool in "${_M020_POOLS[@]}"; do
        native="zfs-scrub-weekly@$pool.timer"
        systemctl enable "$native" >/dev/null 2>&1 \
            && systemctl is-enabled --quiet "$native" >/dev/null 2>&1 || {
            _m020_error "could not enable and verify native timer '$native'"
            return 1
        }
    done

    for pool in "${_M020_POOLS[@]}"; do
        native="zfs-scrub-weekly@$pool.timer"
        monthly="zfs-scrub-monthly@$pool.timer"
        old="pve-toolbox-zfs-scrub@$pool.timer"
        systemctl disable "$old" >/dev/null 2>&1 || {
            _m020_error "could not disable legacy scrub timer for '$pool'"
            return 1
        }
        systemctl is-enabled --quiet "$native" >/dev/null 2>&1 \
            && ! systemctl is-enabled --quiet "$monthly" >/dev/null 2>&1 \
            && ! systemctl is-enabled --quiet "$old" >/dev/null 2>&1 || {
            _m020_error "duplicate scrub schedule guard failed for '$pool'"
            return 1
        }
    done

    tmp=$(mktemp "${state%/*}/.zfs-scrub.state.XXXXXX") || return 1
    if [[ $_M020_RECOVER_STATE -eq 1 ]]; then
        printf 'POOLS=%q\n' "${_M020_POOLS[*]}" > "$tmp" \
            || { rm -f -- "$tmp"; return 1; }
    else
        sed '/^SCHEDULE_OWNER=/d; /^NATIVE_TIMER_TEMPLATE=/d' "$state" > "$tmp" \
            || { rm -f -- "$tmp"; return 1; }
    fi
    if ! printf '%s\n' 'SCHEDULE_OWNER=native' \
        'NATIVE_TIMER_TEMPLATE=zfs-scrub-weekly@.timer' >> "$tmp" \
        || ! chmod 0644 -- "$tmp" || ! mv -f -- "$tmp" "$state"; then
        rm -f -- "$tmp"
        _m020_error "could not write native scrub ownership state"
        return 1
    fi
}
