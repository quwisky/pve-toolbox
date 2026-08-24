# shellcheck shell=bash
#
# Timestamped snapshots of the Proxmox VE host configuration.
#
# PBS and vzdump preserve what is *inside* a guest. Nothing preserves what the
# host itself was: storage definitions, firewall rules, ACLs, network layout
# and passthrough config live in exactly one place, and a failed boot disk
# takes all of them. This module records that, on a timer, into verified
# tar.gz archives, and reports to Discord.
#
# The launcher's verbs do not cover backup and restore, so the lifecycle lives
# here and the work lives in a runner installed into TOOLBOX_BIN_DIR - the
# helper-script pattern from docs/writing-a-module.md.
#
# This release captures. Restore is a later one: every archived path already
# carries a restore class in its manifest, written from the table the restore
# side will read back.
#
# The launcher reads this metadata indirectly, in meta().
# shellcheck disable=SC2034
MODULE_NAME="config-backup"
MODULE_TITLE="PVE config backup"
MODULE_DESC="timestamped snapshots of /etc/pve and host config, reported to Discord"
MODULE_TAGS="backup config notify"
MODULE_HOST_ONLY=1        # needs pmxcfs and the host's own view of the network

CB_BIN="pve-config-backup"
CB_UNIT="pve-toolbox-config-backup"

# -------------------------------------------------------------- internals --

_cb_dir()   { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/opt/pve-toolbox}" "$MODULE_NAME"; }
_cb_src()   { printf '%s/%s.sh' "$(_cb_dir)" "$CB_BIN"; }
_cb_timer() { printf '%s/%s.timer' "$TOOLBOX_SYSTEMD_DIR" "$CB_UNIT"; }

_cb_sum() { # _cb_sum <file>
    [[ -f $1 ]] || { printf 'none'; return 0; }
    sha256sum "$1" | awk '{print $1}'
}

# The timer on disk is the truth, not the state file. state_set writes to
# TOOLBOX_STATE_DIR while systemd_remove takes out the unit, so state outlives
# a partial uninstall - and because is_installed compares the status string
# exactly, a module that wrongly claims to be installed becomes invisible to
# update, uninstall and completion.
_cb_installed() { [[ -f $(_cb_timer) ]]; }

# systemd_oneshot takes a fixed four arguments and writes no Environment=
# lines, so the runner's paths have to ride in on the command itself. Its own
# defaults happen to match lib/common.sh's today, but TOOLBOX_CONF_DIR and
# friends are a documented override - and under one the unit would start,
# find no config, warn to the journal and quietly run with no webhook and
# default retention. /usr/bin/env because systemd needs an absolute path for
# argv[0] and never involves a shell.
_cb_exec() {
    printf '/usr/bin/env CB_CONF=%s CB_STATE_FILE=%s PVE_TOOLBOX_LIB=%s %s/%s run' \
        "$(conf_file "$MODULE_NAME")" \
        "$TOOLBOX_STATE_DIR/$MODULE_NAME.state" \
        "$TOOLBOX_LIB_DIR" "$TOOLBOX_BIN_DIR" "$CB_BIN"
}

# The same environment, for running the helper by hand from the module.
_cb_run_helper() { # _cb_run_helper <args...>
    CB_CONF="$(conf_file "$MODULE_NAME")" \
    CB_STATE_FILE="$TOOLBOX_STATE_DIR/$MODULE_NAME.state" \
    PVE_TOOLBOX_LIB="$TOOLBOX_LIB_DIR" \
        "$TOOLBOX_BIN_DIR/$CB_BIN" "$@"
}

_cb_schedule_of() {
    local f; f=$(_cb_timer)
    [[ -f $f ]] || { printf 'no timer'; return 0; }
    sed -n 's/^OnCalendar=//p' "$f" | head -n1
}

# How long without a run before the status says so. Derived from the schedule
# at install time, because "stale" means something different on a daily timer
# than on a monthly one.
_cb_stale_days_for() { # _cb_stale_days_for <OnCalendar>
    case ${1,,} in
        *hourly*)  printf '1' ;;
        *daily*)   printf '2' ;;
        *weekly*)  printf '8' ;;
        *monthly*) printf '32' ;;
        *)         printf '2' ;;
    esac
}

# Whole days since an ISO 8601 timestamp. -1, not 0, when it cannot be parsed:
# reporting a corrupt timestamp as *fresh* fails in the wrong direction.
_cb_age_days() { # _cb_age_days <iso8601>
    local t now
    [[ -n $1 ]] || { printf '%d' -1; return 0; }
    t=$(date -d "$1" +%s 2>/dev/null) || { printf '%d' -1; return 0; }
    now=$(date +%s)
    printf '%d' $(( (now - t) / 86400 ))
}

_cb_archive_dir() {
    local d
    d=$(conf_get "$MODULE_NAME" CB_ARCHIVE_DIR)
    printf '%s' "${d:-/var/lib/pve-toolbox/config-backup}"
}

_cb_webhook_shown() {
    local f url
    f=$(conf_file "$MODULE_NAME")
    [[ -f $f ]] || { printf 'not configured'; return 0; }
    [[ -r $f ]] || { printf 'configured (root only)'; return 0; }
    url=$(conf_get "$MODULE_NAME" DISCORD_WEBHOOK)
    [[ -n $url ]] || { printf 'not configured'; return 0; }
    printf '%s/****%s' "${url%/*}" "${url: -4}"
}

_cb_human() { # _cb_human <bytes>
    local b=${1:-0}
    if   [[ $b -ge 1073741824 ]]; then awk -v b="$b" 'BEGIN{printf "%.1f GiB", b/1073741824}'
    elif [[ $b -ge 1048576 ]];    then awk -v b="$b" 'BEGIN{printf "%.1f MiB", b/1048576}'
    elif [[ $b -ge 1024 ]];       then awk -v b="$b" 'BEGIN{printf "%.1f KiB", b/1024}'
    else printf '%s B' "$b"; fi
}

# Every prompt has an env var of the same name, so -y drives the whole install.
# ask uses an already-set value as its default and takes it without reading
# under ASSUME_YES, which is the whole mechanism.
_cb_defaults() {
    : "${CB_WEBHOOK:=}"
    : "${CB_ARCHIVE_DIR:=/var/lib/pve-toolbox/config-backup}"
    : "${CB_SCHEDULE:=daily}"
    : "${CB_RETENTION_COUNT:=30}"
    : "${CB_RETENTION_DAYS:=90}"
    : "${CB_NOTIFY_ON_CHANGE:=n}"
    : "${CB_INCLUDE_SECRETS:=n}"
    : "${CB_AGE_RECIPIENT:=}"
    : "${CB_VOLATILE_SECTIONS:=firewall-live/}"
    # Must match the runner's default: _cb_write_conf writes this
    # unconditionally, and the runner sources the conf after its own default -
    # so an empty value here silently disabled the allow-list on every
    # installed host, leaving user.cfg protected by nothing.
    : "${CB_SECRET_ALLOW:=pve/user.cfg derived/dpkg-selections.txt}"
    : "${CB_RUN_NOW:=n}"
    : "${CB_TEST_NOTIFY:=y}"
}

# A re-run is a reconfigure, so an unset prompt starts from what is already
# configured rather than from the factory default.
_cb_seed_from_conf() {
    conf_exists "$MODULE_NAME" || return 0
    local k v
    for k in CB_ARCHIVE_DIR CB_RETENTION_COUNT CB_RETENTION_DAYS \
             CB_AGE_RECIPIENT CB_VOLATILE_SECTIONS CB_SECRET_ALLOW; do
        v=$(conf_get "$MODULE_NAME" "$k")
        [[ -n $v ]] && printf -v "$k" '%s' "$v"
    done
    [[ -z $CB_WEBHOOK ]] && CB_WEBHOOK=$(conf_get "$MODULE_NAME" DISCORD_WEBHOOK)
    v=$(conf_get "$MODULE_NAME" CB_NOTIFY_ON_CHANGE)
    [[ $v == 1 ]] && CB_NOTIFY_ON_CHANGE=y
    v=$(conf_get "$MODULE_NAME" CB_INCLUDE_SECRETS)
    [[ $v == 1 ]] && CB_INCLUDE_SECRETS=y
    return 0
}

# The conf keys the runner reads. Also the migration list: an update writes any
# of these the installed conf is missing, and leaves everything else alone.
CB_CONF_KEYS=(
    CB_ARCHIVE_DIR CB_RETENTION_COUNT CB_RETENTION_DAYS
    CB_NOTIFY_ON_CHANGE CB_INCLUDE_SECRETS CB_AGE_RECIPIENT
    CB_VOLATILE_SECTIONS CB_SECRET_ALLOW
)

_cb_write_conf() {
    local notify=0 secrets=0
    [[ $CB_NOTIFY_ON_CHANGE == y ]] && notify=1
    [[ $CB_INCLUDE_SECRETS   == y ]] && secrets=1
    conf_set "$MODULE_NAME" DISCORD_WEBHOOK       "$CB_WEBHOOK"
    conf_set "$MODULE_NAME" CB_ARCHIVE_DIR        "$CB_ARCHIVE_DIR"
    conf_set "$MODULE_NAME" CB_RETENTION_COUNT    "$CB_RETENTION_COUNT"
    conf_set "$MODULE_NAME" CB_RETENTION_DAYS     "$CB_RETENTION_DAYS"
    conf_set "$MODULE_NAME" CB_NOTIFY_ON_CHANGE   "$notify"
    conf_set "$MODULE_NAME" CB_INCLUDE_SECRETS    "$secrets"
    conf_set "$MODULE_NAME" CB_AGE_RECIPIENT      "$CB_AGE_RECIPIENT"
    conf_set "$MODULE_NAME" CB_VOLATILE_SECTIONS  "$CB_VOLATILE_SECTIONS"
    conf_set "$MODULE_NAME" CB_SECRET_ALLOW       "$CB_SECRET_ALLOW"
    ok "wrote $(conf_file "$MODULE_NAME") (0600)"
}

# Defaults for keys added after this host was installed. conf_set only rewrites
# a line that already matches ^KEY=, so anything the operator added by hand
# survives untouched.
_cb_missing_conf_keys() {
    CB_MISSING=()
    local k
    for k in "${CB_CONF_KEYS[@]}"; do
        [[ -n $(conf_get "$MODULE_NAME" "$k") ]] || CB_MISSING+=("$k")
    done
    return 0
}

_cb_migrate_conf() {
    _cb_defaults
    local k
    for k in "${CB_MISSING[@]:-}"; do
        [[ -n $k ]] || continue
        case $k in
            CB_NOTIFY_ON_CHANGE) conf_set "$MODULE_NAME" "$k" 0 ;;
            CB_INCLUDE_SECRETS)  conf_set "$MODULE_NAME" "$k" 0 ;;
            *)                   conf_set "$MODULE_NAME" "$k" "${!k}" ;;
        esac
        ok "added missing config key $k"
    done
    return 0
}

# ---------------------------------------------------------------- install --

module_install() {
    require_root
    require_pve
    _cb_defaults
    _cb_seed_from_conf
    # git belongs to the git backend, which is a later release. curl and jq are
    # what discord.sh needs; tar and gzip are essential and always present.
    pkg_ensure curl:curl jq:jq

    step "Discord webhook"
    if [[ -z $CB_WEBHOOK && $ASSUME_YES -eq 1 ]]; then
        die "set CB_WEBHOOK for a non-interactive install"
    fi
    while [[ -z $CB_WEBHOOK ]]; do
        ask CB_WEBHOOK "Discord webhook URL" ""
    done
    if [[ ! $CB_WEBHOOK =~ ^https://[A-Za-z0-9._~/-]+$ ]]; then
        die "that does not look like a URL (Server Settings -> Integrations -> Webhooks)"
    fi
    case $CB_WEBHOOK in
        https://discord.com/api/webhooks/*|https://discordapp.com/api/webhooks/*|https://ptb.discord.com/api/webhooks/*) ;;
        *) warn "not a discord.com/api/webhooks URL - continuing, it just has to accept the same JSON" ;;
    esac

    step "Archives"
    ask CB_ARCHIVE_DIR "directory for the archives" "$CB_ARCHIVE_DIR"
    [[ $CB_ARCHIVE_DIR == /* ]] || die "the archive directory has to be an absolute path"

    ask CB_RETENTION_COUNT "keep at least this many archives, whatever their age" "$CB_RETENTION_COUNT"
    ask CB_RETENTION_DAYS  "beyond that, prune archives older than this many days" "$CB_RETENTION_DAYS"
    [[ $CB_RETENTION_COUNT =~ ^[0-9]+$ ]] || die "retention count has to be a number (0 = unlimited)"
    [[ $CB_RETENTION_DAYS  =~ ^[0-9]+$ ]] || die "retention days has to be a number (0 = unlimited)"
    dim "  keeps the newest $CB_RETENTION_COUNT runs whatever their age, then prunes past $CB_RETENTION_DAYS days"

    step "Schedule"
    ask CB_SCHEDULE "systemd OnCalendar" "$CB_SCHEDULE"
    [[ -n $CB_SCHEDULE ]] || die "a schedule is required"

    step "Reporting"
    dim "  a failed capture always reports; this is about the quiet case"
    ask_yn CB_NOTIFY_ON_CHANGE "also report when the configuration changed" "$CB_NOTIFY_ON_CHANGE"

    step "Secrets"
    dim "  /etc/pve/priv, *.pem and *.key are excluded by default"
    ask_yn CB_INCLUDE_SECRETS "include them, encrypted to an age recipient" "$CB_INCLUDE_SECRETS"
    if [[ $CB_INCLUDE_SECRETS == y ]]; then
        command -v age >/dev/null 2>&1 || die "including secrets needs age installed (apt install age)"
        while [[ -z $CB_AGE_RECIPIENT ]]; do
            [[ $ASSUME_YES -eq 1 ]] && die "set CB_AGE_RECIPIENT to include secrets non-interactively"
            ask CB_AGE_RECIPIENT "age recipient (age1...)" ""
        done
        warn "secrets will be archived encrypted - keep the age identity somewhere else"
    fi

    step "Install"
    install_toolbox_lib discord.sh
    install -m 0755 "$(_cb_src)" "$TOOLBOX_BIN_DIR/$CB_BIN"
    ok "installed $TOOLBOX_BIN_DIR/$CB_BIN"
    mkdir -p "$CB_ARCHIVE_DIR"
    chmod 0700 "$CB_ARCHIVE_DIR"
    ok "archives in $CB_ARCHIVE_DIR (0700)"
    _cb_write_conf
    systemd_oneshot "$CB_UNIT" "pve-toolbox PVE configuration snapshot" \
        "$(_cb_exec)" "$CB_SCHEDULE"

    step "Verification"
    # The only prompt without an env var of its own, which made every -y
    # install fire an outbound webhook call whether or not anyone wanted one.
    ask_yn CB_TEST_NOTIFY "send a test notification to Discord now" "$CB_TEST_NOTIFY"
    if [[ $CB_TEST_NOTIFY == y ]]; then
        if _cb_run_helper --test; then
            ok "sent - check the channel"
        else
            warn "failed - fix DISCORD_WEBHOOK in $(conf_file "$MODULE_NAME") and retry"
        fi
    fi

    # State before the unit starts. The runner writes this same file, so
    # starting it first leaves a window where its results are overwritten by
    # the install's own read-modify-write.
    state_set "$MODULE_NAME" ARCHIVE_DIR "$CB_ARCHIVE_DIR"
    state_set "$MODULE_NAME" SCHEDULE "$CB_SCHEDULE"
    state_set "$MODULE_NAME" STALE_AFTER_DAYS "$(_cb_stale_days_for "$CB_SCHEDULE")"
    state_set "$MODULE_NAME" SCRIPT_SUM "$(_cb_sum "$(_cb_src)")"
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"

    ask_yn CB_RUN_NOW "take the first snapshot right now" "$CB_RUN_NOW"
    if [[ $CB_RUN_NOW == y ]]; then
        systemctl start --no-block "$CB_UNIT.service"
        ok "started $CB_UNIT.service (runs in the background)"
    fi

    step "Done - snapshots $CB_SCHEDULE"
    dim "  systemctl list-timers '$CB_UNIT.timer'"
    dim "  $CB_BIN list"
}

# ----------------------------------------------------------------- update --

# No upstream release to track: an update re-syncs the installed runner and the
# unit with this checkout, and fills in config keys added since.
module_update() {
    require_root
    local check_only=0
    [[ ${1:-} == --check ]] && check_only=1

    _cb_installed || die "not installed"

    local src dst new cur drift=0
    src=$(_cb_src); dst="$TOOLBOX_BIN_DIR/$CB_BIN"
    new=$(_cb_sum "$src"); cur=$(_cb_sum "$dst")
    [[ $new != "$cur" ]] && drift=1

    _cb_missing_conf_keys

    local count
    count=$(state_get "$MODULE_NAME" ARCHIVE_COUNT)
    printf '  runner     %s\n' \
        "$([[ $drift -eq 1 ]] && printf 'differs from this checkout' || printf 'up to date')"
    printf '  schedule   %s\n' "$(_cb_schedule_of)"
    printf '  archives   %s in %s\n' "${count:-0}" "$(_cb_archive_dir)"
    [[ ${#CB_MISSING[@]} -gt 0 ]] && warn "config keys missing: ${CB_MISSING[*]}"

    if [[ $drift -eq 0 && ${#CB_MISSING[@]} -eq 0 && ${FORCE:-0} -eq 0 ]]; then
        ok "up to date"
        return 0
    fi
    if [[ $check_only -eq 1 ]]; then
        info "update available: the runner or the config is out of sync"
        return 0
    fi

    step "Runner and unit"
    install_toolbox_lib discord.sh
    install -m 0755 "$src" "$dst"
    ok "installed $dst"
    _cb_migrate_conf

    # Rewrite the unit from the schedule already on disk, so an operator's
    # OnCalendar survives an update that only wanted a newer runner.
    local sched
    sched=$(_cb_schedule_of)
    [[ $sched == "no timer" ]] && sched=daily
    systemd_oneshot "$CB_UNIT" "pve-toolbox PVE configuration snapshot" \
        "$(_cb_exec)" "$sched"

    state_set "$MODULE_NAME" SCHEDULE "$sched"
    state_set "$MODULE_NAME" STALE_AFTER_DAYS "$(_cb_stale_days_for "$sched")"
    state_set "$MODULE_NAME" SCRIPT_SUM "$new"
    state_set "$MODULE_NAME" UPDATED_AT "$(date -Is)"
    step "In sync - snapshots $sched"
}

# ----------------------------------------------------------------- status --

# Called for every module on every menu draw, so it reads the timer and the
# state file and touches nothing else. Counting archives means listing a
# directory that grows; that belongs in the long form.
module_status() {
    _cb_installed || { printf 'not installed'; return 1; }

    local last result count stale age
    last=$(state_get   "$MODULE_NAME" LAST_RUN)
    result=$(state_get "$MODULE_NAME" LAST_RESULT)
    count=$(state_get  "$MODULE_NAME" ARCHIVE_COUNT)
    stale=$(state_get  "$MODULE_NAME" STALE_AFTER_DAYS)

    [[ -z $last ]] && { printf 'never-run'; return 0; }
    if [[ $result == fail* ]]; then
        printf 'failed  [%s]' "$last"
        return 0
    fi

    age=$(_cb_age_days "$last")
    if [[ $age -lt 0 ]]; then
        printf 'unknown  [archives:%s]' "${count:-0}"
    elif [[ $age -gt ${stale:-2} ]]; then
        printf 'stale:%dd  [archives:%s]' "$age" "${count:-0}"
    else
        printf 'archives:%s  [%s]' "${count:-0}" "$last"
    fi
}

module_status_long() {
    local HOST_SHORT; HOST_SHORT=$(hostname -s 2>/dev/null || hostname)
    if ! _cb_installed; then
        warn "not installed"
        return 1
    fi
    local dir count bytes
    dir=$(_cb_archive_dir)
    printf '  helper     %s\n' "$TOOLBOX_BIN_DIR/$CB_BIN"
    printf '  config     %s\n' "$(conf_file "$MODULE_NAME")"
    printf '  webhook    %s\n' "$(_cb_webhook_shown)"
    printf '  archives   %s\n' "$dir"
    printf '  retention  keep newest %s, then prune past %sd\n' \
        "$(conf_get "$MODULE_NAME" CB_RETENTION_COUNT)" \
        "$(conf_get "$MODULE_NAME" CB_RETENTION_DAYS)"
    printf '  schedule   %s\n' "$(_cb_schedule_of)"
    printf '  last run   %s at %s, took %s\n' \
        "$(state_get "$MODULE_NAME" LAST_RESULT)" \
        "$(state_get "$MODULE_NAME" LAST_RUN)" \
        "$(state_get "$MODULE_NAME" LAST_DURATION)"
    printf '  last hash  %s\n' "$(state_get "$MODULE_NAME" LAST_HASH)"

    # The one place that is allowed to look at the archive directory.
    echo
    if [[ -d $dir ]]; then
        count=$(find "$dir" -maxdepth 1 -name "pve-config_${HOST_SHORT:-*}_*.tar.gz" -type f 2>/dev/null | wc -l)
        bytes=0
        local f
        while IFS= read -r f; do
            bytes=$((bytes + $(wc -c < "$f")))
        done < <(find "$dir" -maxdepth 1 -name "pve-config_${HOST_SHORT:-*}_*.tar.gz" -type f 2>/dev/null)
        printf '  %s archive(s), %s\n' "$(printf '%s' "$count" | tr -d ' ')" "$(_cb_human "$bytes")"
        local newest oldest
        newest=$(find "$dir" -maxdepth 1 -name "pve-config_${HOST_SHORT:-*}_*.tar.gz" -type f 2>/dev/null | LC_ALL=C sort | tail -n1)
        oldest=$(find "$dir" -maxdepth 1 -name "pve-config_${HOST_SHORT:-*}_*.tar.gz" -type f 2>/dev/null | LC_ALL=C sort | awk 'NR == 1 { v = $0 } END { print v }')
        [[ -n $newest ]] && printf '  newest     %s\n' "$(basename "$newest")"
        [[ -n $oldest ]] && printf '  oldest     %s\n' "$(basename "$oldest")"
    else
        warn "archive directory is missing: $dir"
    fi

    echo
    systemctl list-timers "$CB_UNIT.timer" --no-pager 2>/dev/null || true
}

# -------------------------------------------------------------- uninstall --

module_uninstall() {
    require_root
    local dir
    dir=$(_cb_archive_dir)

    systemd_remove "$CB_UNIT"
    rm -f "$TOOLBOX_BIN_DIR/$CB_BIN"
    state_clear "$MODULE_NAME"
    ok "runner, unit and state removed"

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

    # The archives are the point of the module. Deleting them is a separate,
    # explicit decision, and the default is no.
    if [[ -d $dir ]]; then
        local drop_data=n
        ask_yn drop_data "also delete the archives in $dir" "n"
        if [[ $drop_data == y ]]; then
            rm -rf "${dir:?}"
            warn "deleted $dir"
        else
            ok "archives left in place: $dir"
        fi
    fi
    dim "  $TOOLBOX_LIB_DIR/discord.sh is shared with other modules and stays"
}
