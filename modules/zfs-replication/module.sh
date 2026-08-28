# shellcheck shell=bash
#
# syncoid replication jobs with Discord reporting.
#
# One systemd timer per job, so an hourly appdata sync and a nightly media
# sync are separate units with separate schedules and separate messages.
#
# The work is in pve-toolbox-zfs-sync.sh, installed as
# $TOOLBOX_BIN_DIR/pve-toolbox-zfs-sync so the units do not depend on this
# checkout staying where it is.
#
# The launcher reads this metadata indirectly, in meta().
# shellcheck disable=SC2034
MODULE_NAME="zfs-replication"
MODULE_TITLE="ZFS replication + Discord"
MODULE_DESC="syncoid jobs on a timer, Discord message with duration and size on each run"
MODULE_TAGS="storage zfs backup replication notify"
MODULE_HOST_ONLY=1        # needs the host's zfs, not an LXC view of it

ZR_BIN="pve-toolbox-zfs-sync"
ZR_UNIT="pve-toolbox-zfs-sync"
ZR_LOG_DIR="/var/log/pve-toolbox"

# ------------------------------------------------------------- internals --

_zr_dir() { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}" "$MODULE_NAME"; }
_zr_src() { printf '%s/%s.sh' "$(_zr_dir)" "$ZR_BIN"; }

_zr_defaults() {
    : "${ZFS_REPL_WEBHOOK:=}"
    : "${ZFS_REPL_JOBS:=}"
    : "${ZFS_REPL_NOTIFY_START:=n}"
    : "${ZFS_REPL_OPTS:=--recursive --compress=zstd-fast}"
    : "${ZFS_REPL_SCHEDULE:=*-*-* 02:30:00}"
}

# Job settings are stored as JOB_<NAME>_<KEY>, name uppercased with anything
# non-alphanumeric turned into an underscore. Same rule as the runner uses.
_zr_key() { # _zr_key <job> <KEY>
    local n=${1//[^A-Za-z0-9]/_}
    printf 'JOB_%s_%s' "${n^^}" "$2"
}

_zr_job_id() {
    local n=${1//[^A-Za-z0-9]/_}
    printf '%s' "${n^^}"
}

_zr_jobs_unique() { # _zr_jobs_unique <job>...
    local job id
    declare -A seen=()
    ZR_COLLISION=""
    for job in "$@"; do
        id=$(_zr_job_id "$job")
        if [[ -n ${seen[$id]+x} ]]; then
            ZR_COLLISION="${seen[$id]} and $job"
            return 1
        fi
        seen[$id]=$job
    done
    return 0
}

# Unit names carry the job name; refuse anything systemd would mangle.
_zr_valid_job() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9_.:-]*$ ]]; }

_zr_valid_schedule() {
    [[ -n ${1:-} ]] || return 1
    command -v systemd-analyze >/dev/null 2>&1 || return 1
    systemd-analyze calendar "$1" >/dev/null 2>&1
}

_zr_configured() { # -> ZR_JOBS from conf
    ZR_JOBS=()
    local raw
    raw=$(conf_get "$MODULE_NAME" JOBS)
    [[ -n $raw ]] || return 0
    read -r -a ZR_JOBS <<<"$raw"
    return 0
}

_zr_scheduled() { # -> ZR_SCHEDULED from the timers on disk
    ZR_SCHEDULED=()
    local f b
    for f in "$TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@"*.timer; do
        [[ -f $f ]] || continue
        b=$(basename "$f" .timer)
        ZR_SCHEDULED+=("${b#*@}")
    done
    return 0
}

_zr_schedule_of() {
    local f="$TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@$1.timer"
    [[ -f $f ]] || { printf 'no timer'; return 0; }
    sed -n 's/^OnCalendar=//p' "$f" | head -n1
}

_zr_sum() {
    [[ -f $1 ]] || { printf 'none'; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

_zr_last_run() { # _zr_last_run <job> -> "ok 2026-08-21T02:41:03+0000 in 00:11:02"
    local f="$ZR_LOG_DIR/$1.last" status when took
    [[ -r $f ]] || { printf 'never run'; return 0; }
    IFS='|' read -r status when took < "$f" || true
    printf '%s at %s, took %s' "${status:-?}" "${when:-?}" "${took:-?}"
}

_zr_webhook_shown() {
    local f url
    f=$(conf_file "$MODULE_NAME")
    [[ -f $f ]] || { printf 'not configured'; return 0; }
    [[ -r $f ]] || { printf 'configured (root only)'; return 0; }
    url=$(conf_get "$MODULE_NAME" DISCORD_WEBHOOK)
    [[ -n $url ]] || { printf 'not configured'; return 0; }
    printf '%s/****%s' "${url%/*}" "${url: -4}"
}

# One template service for every job; %i is the job name.
_zr_write_service() {
    cat > "$TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@.service" <<EOF
[Unit]
Description=pve-toolbox ZFS replication job %i
Documentation=man:syncoid(8)
After=zfs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=SYNC_CONF=$(conf_file "$MODULE_NAME")
Environment=PVE_TOOLBOX_LIB=$TOOLBOX_LIB_DIR
ExecStart=$TOOLBOX_BIN_DIR/$ZR_BIN %i
# Replicating a large delta takes as long as it takes.
TimeoutStartSec=infinity
Nice=10
IOSchedulingClass=idle
StandardOutput=journal
StandardError=journal
EOF
    ok "wrote $ZR_UNIT@.service"
}

_zr_write_timer() { # _zr_write_timer <job> <OnCalendar>
    _zr_valid_schedule "$2" || die "invalid systemd OnCalendar for $1: $2"
    cat > "$TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@$1.timer" <<EOF
[Unit]
Description=pve-toolbox ZFS replication job $1 (timer)

[Timer]
OnCalendar=$2
RandomizedDelaySec=300
Persistent=true
Unit=$ZR_UNIT@$1.service

[Install]
WantedBy=timers.target
EOF
}

_zr_enable() {
    if systemctl enable --now "$ZR_UNIT@$1.timer" >/dev/null 2>&1; then
        ok "enabled $ZR_UNIT@$1.timer  ($(_zr_schedule_of "$1"))"
    else
        warn "could not enable $ZR_UNIT@$1.timer"
        return 1
    fi
}

_zr_remove_timer() {
    systemctl disable --now "$ZR_UNIT@$1.timer" >/dev/null 2>&1 || true
    rm -f "$TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@$1.timer"
}

# Ask for one job's settings and persist them. Returns 1 if the user backs out.
_zr_ask_job() { # _zr_ask_job <job>
    local job=$1 src="" dst="" opts="" own="" mode="" path="" sched=""
    local k

    k=$(_zr_key "$job" SRC);   src=$(conf_get "$MODULE_NAME" "$k")
    k=$(_zr_key "$job" DST);   dst=$(conf_get "$MODULE_NAME" "$k")
    k=$(_zr_key "$job" OPTS);  opts=$(conf_get "$MODULE_NAME" "$k")
    k=$(_zr_key "$job" CHOWN); own=$(conf_get "$MODULE_NAME" "$k")
    k=$(_zr_key "$job" CHMOD); mode=$(conf_get "$MODULE_NAME" "$k")
    k=$(_zr_key "$job" PATH);  path=$(conf_get "$MODULE_NAME" "$k")

    # Env overrides let -y drive this: ZFS_REPL_<JOB>_SRC and friends.
    local env_prefix="ZFS_REPL_${job//[^A-Za-z0-9]/_}"
    env_prefix=${env_prefix^^}
    local v
    v="${env_prefix}_SRC";   [[ -n ${!v:-} ]] && src=${!v}
    v="${env_prefix}_DST";   [[ -n ${!v:-} ]] && dst=${!v}
    v="${env_prefix}_OPTS";  [[ -n ${!v:-} ]] && opts=${!v}
    v="${env_prefix}_CHOWN"; [[ -n ${!v:-} ]] && own=${!v}
    v="${env_prefix}_CHMOD"; [[ -n ${!v:-} ]] && mode=${!v}
    v="${env_prefix}_PATH";  [[ -n ${!v:-} ]] && path=${!v}
    v="${env_prefix}_SCHEDULE"; sched=${!v:-$ZFS_REPL_SCHEDULE}

    ask src  "  source dataset" "$src"
    ask dst  "  target dataset" "$dst"
    if [[ -z $src || -z $dst ]]; then
        warn "job $job needs both a source and a target - skipped"
        return 1
    fi
    ask opts "  syncoid options" "${opts:-$ZFS_REPL_OPTS}"

    if have_zfs; then
        zfs list -H -o name "$src" >/dev/null 2>&1 \
            || warn "source $src does not exist yet"
        zfs list -H -o name "${dst%/*}" >/dev/null 2>&1 \
            || warn "target parent ${dst%/*} does not exist yet"
    fi

    local fix=n
    [[ -n $own || -n $mode ]] && fix=y
    ask_yn fix "  fix ownership on the target after each run" "$fix"
    if [[ $fix == y ]]; then
        ask own  "    chown (uid:gid, blank to skip)" "$own"
        ask mode "    chmod (blank to skip)" "$mode"
        ask path "    path (blank = the target's own mountpoint)" "$path"
    else
        own=""; mode=""; path=""
    fi
    while true; do
        ask sched "  schedule (systemd OnCalendar)" "${sched:-$ZFS_REPL_SCHEDULE}"
        _zr_valid_schedule "$sched" && break
        [[ $ASSUME_YES -eq 1 ]] && die "invalid systemd OnCalendar for $job: $sched"
        warn "invalid systemd OnCalendar: $sched"
        sched=""
    done

    conf_set "$MODULE_NAME" "$(_zr_key "$job" SRC)"   "$src"
    conf_set "$MODULE_NAME" "$(_zr_key "$job" DST)"   "$dst"
    conf_set "$MODULE_NAME" "$(_zr_key "$job" OPTS)"  "$opts"
    conf_set "$MODULE_NAME" "$(_zr_key "$job" CHOWN)" "$own"
    conf_set "$MODULE_NAME" "$(_zr_key "$job" CHMOD)" "$mode"
    conf_set "$MODULE_NAME" "$(_zr_key "$job" PATH)"  "$path"
    _zr_write_timer "$job" "$sched"
    ok "job $job: $src -> $dst  ($sched)"
}

# --------------------------------------------------------------- install --

module_install() {
    require_root
    require_pve
    have_zfs || die "no zfs binary - this module needs ZFS on the host"
    _zr_defaults
    pkg_ensure curl:curl jq:jq syncoid:sanoid util-linux:flock

    step "Discord webhook"
    if [[ -z $ZFS_REPL_WEBHOOK && $ASSUME_YES -eq 1 ]]; then
        die "set ZFS_REPL_WEBHOOK for a non-interactive install"
    fi
    if [[ -z $ZFS_REPL_WEBHOOK ]]; then
        ZFS_REPL_WEBHOOK=$(conf_get "$MODULE_NAME" DISCORD_WEBHOOK)
    fi
    while [[ -z $ZFS_REPL_WEBHOOK ]]; do
        ask ZFS_REPL_WEBHOOK "Discord webhook URL" ""
    done
    if [[ ! $ZFS_REPL_WEBHOOK =~ ^https://[A-Za-z0-9._~/-]+$ ]]; then
        die "that does not look like a URL (Server Settings -> Integrations -> Webhooks)"
    fi

    step "Jobs"
    dim "  one timer per job, so each pair syncs on its own schedule"
    local want=() job
    if [[ -n $ZFS_REPL_JOBS ]]; then
        read -r -a want <<<"$ZFS_REPL_JOBS"
    else
        _zr_configured
        want=("${ZR_JOBS[@]}")
        while true; do
            job=""
            ask job "job name (blank when done)" ""
            [[ -z $job ]] && break
            if ! _zr_valid_job "$job"; then
                warn "job names must start with a letter and hold only [A-Za-z0-9_.:-]"
                continue
            fi
            [[ " ${want[*]:-} " == *" $job "* ]] || want+=("$job")
        done
    fi
    [[ ${#want[@]} -eq 0 ]] && { warn "no jobs defined"; return 1; }

    for job in "${want[@]}"; do
        _zr_valid_job "$job" || die "job name '$job' cannot be used in a systemd unit name"
    done
    _zr_jobs_unique "${want[@]}" \
        || die "job names normalize to the same config key: $ZR_COLLISION"

    conf_set "$MODULE_NAME" DISCORD_WEBHOOK "$ZFS_REPL_WEBHOOK"
    conf_set "$MODULE_NAME" LOG_DIR "$ZR_LOG_DIR"

    local kept=()
    for job in "${want[@]}"; do
        step "Job: $job"
        if _zr_ask_job "$job"; then kept+=("$job"); fi
    done
    [[ ${#kept[@]} -eq 0 ]] && { warn "no usable jobs"; return 1; }

    ask_yn ZFS_REPL_NOTIFY_START "also notify when a job starts" "$ZFS_REPL_NOTIFY_START"
    local notify_start=0
    [[ $ZFS_REPL_NOTIFY_START == y ]] && notify_start=1
    conf_set "$MODULE_NAME" NOTIFY_START "$notify_start"
    conf_set "$MODULE_NAME" JOBS "${kept[*]}"

    step "Install"
    install_toolbox_lib discord.sh
    install -m 0755 "$(_zr_src)" "$TOOLBOX_BIN_DIR/$ZR_BIN"
    ok "installed $TOOLBOX_BIN_DIR/$ZR_BIN"
    mkdir -p "$ZR_LOG_DIR"
    chmod 0750 "$ZR_LOG_DIR"
    _zr_write_service
    systemctl daemon-reload
    for job in "${kept[@]}"; do
        _zr_enable "$job" || die "could not enable the timer for $job"
    done

    step "Verification"
    local t=y
    ask_yn t "send a test notification to Discord now" "y"
    if [[ $t == y ]]; then
        if SYNC_CONF="$(conf_file "$MODULE_NAME")" PVE_TOOLBOX_LIB="$TOOLBOX_LIB_DIR" \
           "$TOOLBOX_BIN_DIR/$ZR_BIN" --test "${kept[0]}"; then
            ok "sent - check the channel"
        else
            warn "failed - fix DISCORD_WEBHOOK in $(conf_file "$MODULE_NAME") and retry"
        fi
    fi

    local now=n
    ask_yn now "run the jobs once right now" "n"
    if [[ $now == y ]]; then
        for job in "${kept[@]}"; do
            systemctl start --no-block "$ZR_UNIT@$job.service"
            ok "started $ZR_UNIT@$job.service (runs in the background)"
        done
    fi

    state_set "$MODULE_NAME" JOBS "${kept[*]}"
    state_set "$MODULE_NAME" SCRIPT_SUM "$(_zr_sum "$(_zr_src)")"
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"

    step "Done - ${#kept[@]} job(s) scheduled"
    dim "  systemctl list-timers '$ZR_UNIT@*'"
    dim "  logs in $ZR_LOG_DIR/<job>.log, previous run kept as .log.prev"
}

# ---------------------------------------------------------------- update --

# No upstream release here: an update re-syncs the installed runner and the
# unit files with this checkout, and reports jobs whose timer went missing.
module_update() {
    require_root
    local check_only=0
    [[ ${1:-} == --check ]] && check_only=1

    _zr_configured
    _zr_jobs_unique "${ZR_JOBS[@]}" \
        || die "job names normalize to the same config key: $ZR_COLLISION"
    _zr_scheduled
    [[ ${#ZR_JOBS[@]} -eq 0 && ${#ZR_SCHEDULED[@]} -eq 0 ]] && die "not installed"

    local src dst new cur
    src=$(_zr_src); dst="$TOOLBOX_BIN_DIR/$ZR_BIN"
    new=$(_zr_sum "$src"); cur=$(_zr_sum "$dst")

    local missing=() stale=() invalid=() j
    for j in "${ZR_JOBS[@]}"; do
        [[ " ${ZR_SCHEDULED[*]} " == *" $j "* ]] || missing+=("$j")
    done
    for j in "${ZR_SCHEDULED[@]}"; do
        if [[ " ${ZR_JOBS[*]} " == *" $j "* ]]; then
            _zr_valid_schedule "$(_zr_schedule_of "$j")" || invalid+=("$j")
        else
            stale+=("$j")
        fi
    done

    local drift=0
    [[ $new != "$cur" ]] && drift=1
    printf '  runner     %s\n' \
        "$([[ $drift -eq 1 ]] && printf 'differs from this checkout' || printf 'up to date')"
    printf '  jobs       %s\n' "${ZR_JOBS[*]:-none}"
    if [[ ${#missing[@]} -gt 0 ]]; then warn "configured but no timer: ${missing[*]}"; fi
    if [[ ${#stale[@]} -gt 0 ]];   then warn "timer but not configured: ${stale[*]}"; fi
    if [[ ${#invalid[@]} -gt 0 ]]; then warn "invalid timer schedule: ${invalid[*]}"; fi

    if [[ $drift -eq 0 && ${#missing[@]} -eq 0 && ${#stale[@]} -eq 0 && ${#invalid[@]} -eq 0 && ${FORCE:-0} -eq 0 ]]; then
        ok "up to date"
        return 0
    fi
    if [[ $check_only -eq 1 ]]; then
        info "update available: runner or job timers are out of sync"
        return 0
    fi

    step "Runner and units"
    install_toolbox_lib discord.sh
    install -m 0755 "$src" "$dst"
    ok "installed $dst"
    _zr_write_service

    if [[ ${#stale[@]} -gt 0 ]]; then
        step "Timers with no job"
        for j in "${stale[@]}"; do
            local drop=y
            ask_yn drop "  remove the timer for $j" "y"
            if [[ $drop == y ]]; then
                _zr_remove_timer "$j"
                ok "removed $ZR_UNIT@$j.timer"
            fi
        done
    fi
    local repair=("${missing[@]}" "${invalid[@]}")
    if [[ ${#repair[@]} -gt 0 ]]; then
        step "Jobs needing a timer"
        for j in "${repair[@]}"; do
            [[ -n $j ]] || continue
            _zr_ask_job "$j" || continue
        done
    fi

    systemctl daemon-reload
    _zr_scheduled
    for j in "${ZR_SCHEDULED[@]}"; do
        _zr_enable "$j" || die "could not enable the timer for $j"
    done

    state_set "$MODULE_NAME" JOBS "${ZR_SCHEDULED[*]}"
    state_set "$MODULE_NAME" SCRIPT_SUM "$new"
    state_set "$MODULE_NAME" UPDATED_AT "$(date -Is)"
    step "In sync - ${#ZR_SCHEDULED[@]} job(s) scheduled"
}

# ---------------------------------------------------------------- status --

module_status() {
    _zr_configured
    if ! _zr_jobs_unique "${ZR_JOBS[@]}"; then
        printf 'invalid jobs  [%s]' "$ZR_COLLISION"
        return 0
    fi
    _zr_scheduled
    if [[ ${#ZR_SCHEDULED[@]} -eq 0 ]]; then
        printf 'not installed'
        return 1
    fi
    local schedule_job
    for schedule_job in "${ZR_SCHEDULED[@]}"; do
        if ! _zr_valid_schedule "$(_zr_schedule_of "$schedule_job")"; then
            printf 'invalid schedule  [%s]' "$schedule_job"
            return 0
        fi
    done
    local running=() j
    for j in "${ZR_SCHEDULED[@]}"; do
        if systemctl is-active --quiet "$ZR_UNIT@$j.service" 2>/dev/null; then
            running+=("$j")
        fi
    done
    if [[ ${#running[@]} -gt 0 ]]; then
        printf 'syncing  [%s]' "${running[*]}"
    else
        printf 'jobs:%d  [%s]' "${#ZR_SCHEDULED[@]}" "${ZR_SCHEDULED[*]}"
    fi
}

module_status_long() {
    _zr_scheduled
    if [[ ${#ZR_SCHEDULED[@]} -eq 0 ]]; then
        warn "not installed"
        return 1
    fi
    printf '  runner     %s\n' "$TOOLBOX_BIN_DIR/$ZR_BIN"
    printf '  config     %s\n' "$(conf_file "$MODULE_NAME")"
    printf '  webhook    %s\n' "$(_zr_webhook_shown)"
    printf '  logs       %s\n' "$ZR_LOG_DIR"
    echo
    local j src dst
    for j in "${ZR_SCHEDULED[@]}"; do
        src=$(conf_get "$MODULE_NAME" "$(_zr_key "$j" SRC)")
        dst=$(conf_get "$MODULE_NAME" "$(_zr_key "$j" DST)")
        printf '  %-14s %s -> %s\n' "$j" "${src:-?}" "${dst:-?}"
        printf '    %-12s %s\n' "schedule" "$(_zr_schedule_of "$j")"
        printf '    %-12s %s\n' "last run" "$(_zr_last_run "$j")"
    done
    echo
    systemctl list-timers "$ZR_UNIT@*" --no-pager 2>/dev/null || true
}

# ------------------------------------------------------------- uninstall --

module_uninstall() {
    require_root
    _zr_scheduled
    local j
    for j in "${ZR_SCHEDULED[@]}"; do
        _zr_remove_timer "$j"
        ok "removed $ZR_UNIT@$j.timer"
    done
    rm -f "$TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@.service"
    systemctl daemon-reload
    rm -f "$TOOLBOX_BIN_DIR/$ZR_BIN"
    state_clear "$MODULE_NAME"
    ok "runner, units and state removed"

    if conf_exists "$MODULE_NAME"; then
        local conf drop=y
        conf=$(conf_file "$MODULE_NAME")
        ask_yn drop "also remove $conf (holds the webhook URL and job definitions)" "y"
        if [[ $drop == y ]]; then
            conf_clear "$MODULE_NAME"
            ok "removed $conf"
        else
            warn "config left in place: $conf"
        fi
    fi
    dim "  $TOOLBOX_LIB_DIR/discord.sh is shared with other modules and stays"
    warn "replicated data and logs are left alone: $ZR_LOG_DIR"
}
