# shellcheck shell=bash
#
# Scheduled ZFS scrubs with Discord reporting.
#
# One systemd timer per pool, each on its own schedule, each firing a watcher
# that posts to Discord twice: once when the scrub starts and once when it
# ends, with the repaired/errors/duration summary zfs reports.
#
# The heavy lifting is in pve-toolbox-zfs-scrub.sh, installed as
# $TOOLBOX_BIN_DIR/pve-toolbox-zfs-scrub so the units do not depend on this
# checkout staying where it is.
#
# The launcher reads this metadata indirectly, in meta().
# shellcheck disable=SC2034
MODULE_NAME="zfs-scrub"
MODULE_TITLE="ZFS scrub + Discord"
MODULE_DESC="scheduled scrub per pool, Discord message on start and on result"
MODULE_TAGS="storage zfs monitoring notify"
MODULE_HOST_ONLY=1        # needs the host's zpool, not an LXC view of it

ZS_BIN="pve-toolbox-zfs-scrub"

# Namespaced away from zfs-scrub@.service, which zfsutils-linux ships.
ZS_UNIT="pve-toolbox-zfs-scrub"

# ------------------------------------------------------------- internals --

_zs_dir() { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}" "$MODULE_NAME"; }
_zs_src() { printf '%s/%s.sh' "$(_zs_dir)" "$ZS_BIN"; }

_zs_defaults() {
    : "${ZFS_SCRUB_WEBHOOK:=}"
    : "${ZFS_SCRUB_POOLS:=}"
    : "${ZFS_SCRUB_INTERVAL:=300}"
    : "${ZFS_SCRUB_NOTIFY_START:=y}"
}

_zs_pools() { zpool list -H -o name 2>/dev/null; }

# Pool names may contain . - : which are not legal in a variable name.
_zs_var() { # _zs_var <pool> -> ZFS_SCRUB_SCHEDULE_<POOL>
    local p=${1//[^A-Za-z0-9]/_}
    printf 'ZFS_SCRUB_SCHEDULE_%s' "${p^^}"
}

_zs_pools_unique() { # _zs_pools_unique <pool>...
    local pool var
    declare -A seen=()
    ZS_COLLISION=""
    for pool in "$@"; do
        var=$(_zs_var "$pool")
        if [[ -n ${seen[$var]+x} ]]; then
            ZS_COLLISION="${seen[$var]} and $pool"
            return 1
        fi
        seen[$var]=$pool
    done
    return 0
}

_zs_valid_schedule() {
    [[ -n ${1:-} ]] || return 1
    command -v systemd-analyze >/dev/null 2>&1 || return 1
    systemd-analyze calendar "$1" >/dev/null 2>&1
}

# Pools share spindles, so stagger them a week apart rather than scrubbing
# everything on the same night.
_zs_default_schedule() { # _zs_default_schedule <index>
    case $(( ${1:-0} % 4 )) in
        0) printf 'Sun *-*-01..07 03:00:00' ;;
        1) printf 'Sun *-*-08..14 03:00:00' ;;
        2) printf 'Sun *-*-15..21 03:00:00' ;;
        *) printf 'Sun *-*-22..28 03:00:00' ;;
    esac
}

# Unit names carry the pool name; refuse anything systemd would mangle.
_zs_valid_pool() {
    [[ $1 =~ ^[A-Za-z][A-Za-z0-9_.:-]*$ ]]
}

# Which pools currently have a timer on disk - the timers are the truth here,
# not the state file.
_zs_scheduled() {
    ZS_SCHEDULED=()
    local f b
    for f in "$TOOLBOX_SYSTEMD_DIR/$ZS_UNIT@"*.timer; do
        [[ -f $f ]] || continue
        b=$(basename "$f" .timer)
        ZS_SCHEDULED+=("${b#*@}")
    done
    return 0
}

_zs_schedule_of() { # _zs_schedule_of <pool>
    local f="$TOOLBOX_SYSTEMD_DIR/$ZS_UNIT@$1.timer"
    [[ -f $f ]] || { printf 'no timer'; return 0; }
    sed -n 's/^OnCalendar=//p' "$f" | head -n1
}

_zs_sum() { # _zs_sum <file>
    [[ -f $1 ]] || { printf 'none'; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

_zs_write_conf() {
    local notify_start=0
    [[ $ZFS_SCRUB_NOTIFY_START == y ]] && notify_start=1
    conf_set "$MODULE_NAME" DISCORD_WEBHOOK "$ZFS_SCRUB_WEBHOOK"
    conf_set "$MODULE_NAME" POLL_INTERVAL   "$ZFS_SCRUB_INTERVAL"
    conf_set "$MODULE_NAME" NOTIFY_START    "$notify_start"
    ok "wrote $(conf_file "$MODULE_NAME") (0600)"
}

# One template service for every pool; %i is the pool name.
_zs_write_service() {
    cat > "$TOOLBOX_SYSTEMD_DIR/$ZS_UNIT@.service" <<EOF
[Unit]
Description=pve-toolbox ZFS scrub of %i
Documentation=man:zpool-scrub(8)
After=zfs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=SCRUB_CONF=$(conf_file "$MODULE_NAME")
Environment=PVE_TOOLBOX_LIB=$TOOLBOX_LIB_DIR
ExecStart=$TOOLBOX_BIN_DIR/$ZS_BIN %i
# The unit stays active for the whole scrub so it can report the result;
# on a large pool that is hours, not minutes.
TimeoutStartSec=infinity
Nice=19
StandardOutput=journal
StandardError=journal
EOF
    ok "wrote $ZS_UNIT@.service"
}

_zs_write_timer() { # _zs_write_timer <pool> <OnCalendar>
    _zs_valid_schedule "$2" || die "invalid systemd OnCalendar for $1: $2"
    cat > "$TOOLBOX_SYSTEMD_DIR/$ZS_UNIT@$1.timer" <<EOF
[Unit]
Description=pve-toolbox ZFS scrub of $1 (timer)

[Timer]
OnCalendar=$2
RandomizedDelaySec=1800
Persistent=true
Unit=$ZS_UNIT@$1.service

[Install]
WantedBy=timers.target
EOF
}

_zs_enable() { # _zs_enable <pool>
    if systemctl enable --now "$ZS_UNIT@$1.timer" >/dev/null 2>&1; then
        ok "enabled $ZS_UNIT@$1.timer  ($(_zs_schedule_of "$1"))"
    else
        warn "could not enable $ZS_UNIT@$1.timer"
        return 1
    fi
}

_zs_remove_timer() { # _zs_remove_timer <pool>
    systemctl disable --now "$ZS_UNIT@$1.timer" >/dev/null 2>&1 || true
    rm -f "$TOOLBOX_SYSTEMD_DIR/$ZS_UNIT@$1.timer"
}

# zfsutils-linux ships its own scrub timers; two schedules on one pool is
# just wasted I/O.
_zs_distro_timers() { # _zs_distro_timers <pool>...
    ZS_CONFLICT=()
    local p u
    for p in "$@"; do
        for u in "zfs-scrub-monthly@$p.timer" "zfs-scrub-weekly@$p.timer"; do
            systemctl is-enabled --quiet "$u" 2>/dev/null && ZS_CONFLICT+=("$u")
        done
    done
    return 0
}

_zs_webhook_shown() {
    local f url
    f=$(conf_file "$MODULE_NAME")
    [[ -f $f ]] || { printf 'not configured'; return 0; }
    [[ -r $f ]] || { printf 'configured (root only)'; return 0; }
    url=$(conf_get "$MODULE_NAME" DISCORD_WEBHOOK)
    [[ -n $url ]] || { printf 'not configured'; return 0; }
    printf '%s/****%s' "${url%/*}" "${url: -4}"
}

# --------------------------------------------------------------- install --

module_install() {
    require_root
    require_pve
    have_zfs || die "no zpool binary - this module needs ZFS on the host"
    _zs_defaults
    pkg_ensure curl:curl jq:jq

    step "Discord webhook"
    if [[ -z $ZFS_SCRUB_WEBHOOK && $ASSUME_YES -eq 1 ]]; then
        die "set ZFS_SCRUB_WEBHOOK for a non-interactive install"
    fi
    while [[ -z $ZFS_SCRUB_WEBHOOK ]]; do
        ask ZFS_SCRUB_WEBHOOK "Discord webhook URL" ""
    done
    if [[ ! $ZFS_SCRUB_WEBHOOK =~ ^https://[A-Za-z0-9._~/-]+$ ]]; then
        die "that does not look like a URL (Server Settings -> Integrations -> Webhooks)"
    fi
    case $ZFS_SCRUB_WEBHOOK in
        https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*|https://ptb.discord.com/api/webhooks/*) ;;
        *) warn "not a discord.com/api/webhooks URL - continuing, it just has to accept the same JSON" ;;
    esac

    step "Pools"
    local all=() p
    mapfile -t all < <(_zs_pools)
    [[ ${#all[@]} -eq 0 ]] && die "no ZFS pools on this host"

    local want=()
    if [[ -n $ZFS_SCRUB_POOLS ]]; then
        for p in $ZFS_SCRUB_POOLS; do
            zpool list -H -o name "$p" >/dev/null 2>&1 || die "no such pool: $p"
            want+=("$p")
        done
    else
        local pick size health
        for p in "${all[@]}"; do
            size=$(zpool list -H -o size "$p" 2>/dev/null || printf '?')
            health=$(zpool list -H -o health "$p" 2>/dev/null || printf '?')
            pick=y; ask_yn pick "  scrub $p ($size, $health)" "y"
            [[ $pick == y ]] && want+=("$p")
        done
    fi
    [[ ${#want[@]} -eq 0 ]] && { warn "no pools selected"; return 1; }

    for p in "${want[@]}"; do
        _zs_valid_pool "$p" || die "pool name '$p' cannot be used in a systemd unit name"
    done
    _zs_pools_unique "${want[@]}" \
        || die "pool names normalize to the same schedule variable: $ZS_COLLISION"

    step "Schedules"
    dim "  staggered a week apart so the pools do not all scrub on the same night"
    local i=0 var
    for p in "${want[@]}"; do
        var=$(_zs_var "$p")
        [[ -z ${!var:-} ]] && printf -v "$var" '%s' "$(_zs_default_schedule "$i")"
        while true; do
            ask "$var" "  $p (systemd OnCalendar)" "${!var}"
            _zs_valid_schedule "${!var}" && break
            [[ $ASSUME_YES -eq 1 ]] && die "invalid systemd OnCalendar for $p: ${!var}"
            warn "invalid systemd OnCalendar: ${!var}"
            printf -v "$var" '%s' "$(_zs_default_schedule "$i")"
        done
        i=$((i + 1))
    done
    ask ZFS_SCRUB_INTERVAL "how often to check whether a scrub finished (seconds)" \
        "$ZFS_SCRUB_INTERVAL"
    ask_yn ZFS_SCRUB_NOTIFY_START "also notify when a scrub starts" \
        "$ZFS_SCRUB_NOTIFY_START"

    _zs_distro_timers "${want[@]}"
    if [[ ${#ZS_CONFLICT[@]} -gt 0 ]]; then
        step "Timers already scrubbing these pools"
        warn "from zfsutils-linux: ${ZS_CONFLICT[*]}"
        local dis=y u
        ask_yn dis "disable them so each pool is scrubbed once, by us" "y"
        if [[ $dis == y ]]; then
            for u in "${ZS_CONFLICT[@]}"; do
                systemctl disable --now "$u" >/dev/null 2>&1 || true
                ok "disabled $u"
            done
        fi
    fi

    step "Install"
    install_toolbox_lib discord.sh
    install -m 0755 "$(_zs_src)" "$TOOLBOX_BIN_DIR/$ZS_BIN"
    ok "installed $TOOLBOX_BIN_DIR/$ZS_BIN"
    _zs_write_conf
    _zs_write_service
    for p in "${want[@]}"; do
        var=$(_zs_var "$p")
        _zs_write_timer "$p" "${!var}"
    done
    systemctl daemon-reload
    for p in "${want[@]}"; do
        _zs_enable "$p" || die "could not enable the timer for $p"
    done

    step "Verification"
    local t=y
    ask_yn t "send a test notification to Discord now" "y"
    if [[ $t == y ]]; then
        if SCRUB_CONF="$(conf_file "$MODULE_NAME")" PVE_TOOLBOX_LIB="$TOOLBOX_LIB_DIR" \
           "$TOOLBOX_BIN_DIR/$ZS_BIN" --test "${want[0]}"; then
            ok "sent - check the channel"
        else
            warn "failed - fix DISCORD_WEBHOOK in $(conf_file "$MODULE_NAME") and retry"
        fi
    fi

    local now=n
    ask_yn now "start a scrub on the selected pools right now" "n"
    if [[ $now == y ]]; then
        for p in "${want[@]}"; do
            systemctl start --no-block "$ZS_UNIT@$p.service"
            ok "started $ZS_UNIT@$p.service (runs in the background)"
        done
    fi

    state_set "$MODULE_NAME" POOLS "${want[*]}"
    state_set "$MODULE_NAME" INTERVAL "$ZFS_SCRUB_INTERVAL"
    state_set "$MODULE_NAME" NOTIFY_START "$ZFS_SCRUB_NOTIFY_START"
    state_set "$MODULE_NAME" SCRIPT_SUM "$(_zs_sum "$(_zs_src)")"
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"

    step "Done - ${#want[@]} pool(s) scheduled"
    dim "  systemctl list-timers '$ZS_UNIT@*'"
    dim "  journalctl -u '$ZS_UNIT@*' -f   follow a running scrub"
    dim "  stopping the unit stops the reporting, not the scrub"
}

# ---------------------------------------------------------------- update --

# There is no upstream release here: an update re-syncs the installed watcher
# and the per-pool timers with this checkout, and picks up new pools.
module_update() {
    require_root
    local check_only=0
    [[ ${1:-} == --check ]] && check_only=1

    _zs_scheduled
    [[ ${#ZS_SCHEDULED[@]} -eq 0 ]] && die "not installed"
    _zs_pools_unique "${ZS_SCHEDULED[@]}" \
        || die "pool names normalize to the same schedule variable: $ZS_COLLISION"

    local src dst new cur
    src=$(_zs_src); dst="$TOOLBOX_BIN_DIR/$ZS_BIN"
    new=$(_zs_sum "$src"); cur=$(_zs_sum "$dst")

    local missing=() stale=() invalid=() p
    if have_zfs; then
        # `done <` redirects stdin for the whole body, so nothing in here may
        # prompt - ask and confirm would read pool names instead of the
        # operator, and bash hides a read prompt when stdin is not a terminal.
        while read -r p; do
            [[ -n $p ]] || continue
            [[ " ${ZS_SCHEDULED[*]} " == *" $p "* ]] || missing+=("$p")
        done < <(_zs_pools)
        for p in "${ZS_SCHEDULED[@]}"; do
            if zpool list -H -o name "$p" >/dev/null 2>&1; then
                _zs_valid_schedule "$(_zs_schedule_of "$p")" || invalid+=("$p")
            else
                stale+=("$p")
            fi
        done
    fi

    local drift=0
    [[ $new != "$cur" ]] && drift=1
    printf '  watcher    %s\n' \
        "$([[ $drift -eq 1 ]] && printf 'differs from this checkout' || printf 'up to date')"
    printf '  scheduled  %s\n' "${ZS_SCHEDULED[*]}"
    if [[ ${#missing[@]} -gt 0 ]]; then warn "pools with no scrub timer: ${missing[*]}"; fi
    if [[ ${#stale[@]} -gt 0 ]];   then warn "timers for pools that are gone: ${stale[*]}"; fi
    if [[ ${#invalid[@]} -gt 0 ]]; then warn "invalid timer schedule: ${invalid[*]}"; fi

    if [[ $drift -eq 0 && ${#missing[@]} -eq 0 && ${#stale[@]} -eq 0 && ${#invalid[@]} -eq 0 && ${FORCE:-0} -eq 0 ]]; then
        ok "up to date"
        return 0
    fi
    if [[ $check_only -eq 1 ]]; then
        info "update available: watcher or pool timers are out of sync"
        return 0
    fi

    step "Watcher and units"
    install_toolbox_lib discord.sh
    install -m 0755 "$src" "$dst"
    ok "installed $dst"
    _zs_write_service

    if [[ ${#stale[@]} -gt 0 ]]; then
        step "Pools that no longer exist"
        for p in "${stale[@]}"; do
            local drop=y
            ask_yn drop "  remove the timer for $p" "y"
            if [[ $drop == y ]]; then
                _zs_remove_timer "$p"
                ok "removed $ZS_UNIT@$p.timer"
            fi
        done
    fi

    local added=()
    if [[ ${#missing[@]} -gt 0 ]]; then
        step "New pools"
        local i=${#ZS_SCHEDULED[@]}
        for p in "${missing[@]}"; do
            if ! _zs_valid_pool "$p"; then
                warn "skipping $p - not usable in a systemd unit name"
                continue
            fi
            local add=y sched
            ask_yn add "  schedule scrubs for $p" "y"
            [[ $add == y ]] || continue
            sched=$(_zs_default_schedule "$i")
            while true; do
                ask sched "  $p (systemd OnCalendar)" "$sched"
                _zs_valid_schedule "$sched" && break
                [[ $ASSUME_YES -eq 1 ]] && die "invalid systemd OnCalendar for $p: $sched"
                warn "invalid systemd OnCalendar: $sched"
                sched=$(_zs_default_schedule "$i")
            done
            _zs_write_timer "$p" "$sched"
            added+=("$p")
            i=$((i + 1))
        done
    fi

    if [[ ${#invalid[@]} -gt 0 ]]; then
        step "Pools with invalid schedules"
        local repair_index=${#ZS_SCHEDULED[@]}
        for p in "${invalid[@]}"; do
            local repair_sched
            repair_sched=$(_zs_default_schedule "$repair_index")
            while true; do
                ask repair_sched "  $p (systemd OnCalendar)" "$repair_sched"
                _zs_valid_schedule "$repair_sched" && break
                [[ $ASSUME_YES -eq 1 ]] && die "invalid systemd OnCalendar for $p: $repair_sched"
                warn "invalid systemd OnCalendar: $repair_sched"
                repair_sched=$(_zs_default_schedule "$repair_index")
            done
            _zs_write_timer "$p" "$repair_sched"
            added+=("$p")
            repair_index=$((repair_index + 1))
        done
    fi

    systemctl daemon-reload
    for p in "${added[@]:-}"; do
        [[ -n $p ]] || continue
        _zs_enable "$p" || die "could not enable the timer for $p"
    done

    _zs_scheduled
    state_set "$MODULE_NAME" POOLS "${ZS_SCHEDULED[*]}"
    state_set "$MODULE_NAME" SCRIPT_SUM "$new"
    state_set "$MODULE_NAME" UPDATED_AT "$(date -Is)"
    step "In sync - ${#ZS_SCHEDULED[@]} pool(s) scheduled"
}

# ---------------------------------------------------------------- status --

module_status() {
    _zs_scheduled
    if [[ ${#ZS_SCHEDULED[@]} -eq 0 ]]; then
        printf 'not installed'
        return 1
    fi
    if ! _zs_pools_unique "${ZS_SCHEDULED[@]}"; then
        printf 'invalid pools  [%s]' "$ZS_COLLISION"
        return 0
    fi
    local schedule_pool
    for schedule_pool in "${ZS_SCHEDULED[@]}"; do
        if ! _zs_valid_schedule "$(_zs_schedule_of "$schedule_pool")"; then
            printf 'invalid schedule  [%s]' "$schedule_pool"
            return 0
        fi
    done
    local running=() p
    if have_zfs; then
        for p in "${ZS_SCHEDULED[@]}"; do
            if zpool status "$p" 2>/dev/null | grep -q 'scrub in progress'; then
                running+=("$p")
            fi
        done
    fi
    if [[ ${#running[@]} -gt 0 ]]; then
        printf 'scrubbing  [%s]' "${running[*]}"
    else
        printf 'pools:%d  [%s]' "${#ZS_SCHEDULED[@]}" "${ZS_SCHEDULED[*]}"
    fi
}

module_status_long() {
    _zs_scheduled
    if [[ ${#ZS_SCHEDULED[@]} -eq 0 ]]; then
        warn "not installed"
        return 1
    fi
    printf '  watcher    %s\n' "$TOOLBOX_BIN_DIR/$ZS_BIN"
    printf '  config     %s\n' "$(conf_file "$MODULE_NAME")"
    printf '  webhook    %s\n' "$(_zs_webhook_shown)"
    printf '  notify     start=%s, poll every %ss\n' \
        "$(state_get "$MODULE_NAME" NOTIFY_START)" \
        "$(state_get "$MODULE_NAME" INTERVAL)"
    echo
    local p health scan
    for p in "${ZS_SCHEDULED[@]}"; do
        health=$(zpool list -H -o health "$p" 2>/dev/null || printf '?')
        scan=$(zpool status "$p" 2>/dev/null \
            | sed -n 's/^[[:space:]]*scan:[[:space:]]*//p' | head -n1)
        printf '  %-16s %-9s %s\n' "$p" "$health" "$(_zs_schedule_of "$p")"
        printf '    %s\n' "${scan:-no scrub recorded}"
    done
    echo
    systemctl list-timers "$ZS_UNIT@*" --no-pager 2>/dev/null || true
}

# ------------------------------------------------------------- uninstall --

module_uninstall() {
    require_root
    _zs_scheduled
    local p
    for p in "${ZS_SCHEDULED[@]}"; do
        _zs_remove_timer "$p"
        ok "removed $ZS_UNIT@$p.timer"
    done
    rm -f "$TOOLBOX_SYSTEMD_DIR/$ZS_UNIT@.service"
    systemctl daemon-reload
    rm -f "$TOOLBOX_BIN_DIR/$ZS_BIN"
    state_clear "$MODULE_NAME"
    ok "watcher, units and state removed"

    if conf_exists "$MODULE_NAME"; then
        local conf drop=y
        conf=$(conf_file "$MODULE_NAME")
        ask_yn drop "also remove $conf (holds the webhook URL)" "y"
        if [[ $drop == y ]]; then
            conf_clear "$MODULE_NAME"
            ok "removed $conf"
        else
            warn "config left in place: $conf"
        fi
    fi
    dim "  $TOOLBOX_LIB_DIR/discord.sh is shared with other modules and stays"
    warn "a scrub already running in the kernel is not stopped - 'zpool scrub -s <pool>' does that"
}
