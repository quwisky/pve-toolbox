#!/usr/bin/env bash
#
# pve-toolbox-zfs-sync - run one syncoid replication job and report to Discord.
#
# Installed by the pve-toolbox 'zfs-replication' module as
# /usr/local/bin/pve-toolbox-zfs-sync and driven by one systemd timer per job:
#
#   pve-toolbox-zfs-sync <job>         replicate, then report success or failure
#   pve-toolbox-zfs-sync --test <job>  send a test notification, replicate nothing
#   pve-toolbox-zfs-sync --list        list configured jobs
#
# Config, written by the module, root-only because the webhook URL is the only
# credential Discord checks. Job keys are the job name uppercased, with
# anything non-alphanumeric turned into an underscore:
#
#   /etc/pve-toolbox/zfs-replication.conf
#     DISCORD_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>'
#     JOBS='appdata'
#     JOB_APPDATA_SRC='fast-data-pool/appdata'
#     JOB_APPDATA_DST='data-pool/appdata-backup'
#     JOB_APPDATA_OPTS='--recursive --compress=zstd-fast'
#     JOB_APPDATA_CHOWN='102105:102105'   # optional, applied to the target
#     JOB_APPDATA_CHMOD='775'             # optional
#     JOB_APPDATA_PATH=''                 # optional, defaults to the mountpoint
#
set -euo pipefail

CONF="${SYNC_CONF:-/etc/pve-toolbox/zfs-replication.conf}"

DISCORD_WEBHOOK=""
JOBS=""
LOG_DIR="/var/log/pve-toolbox"
NOTIFY_START=0
LOG_TAIL=25

# Reporting comes from the shared lib installed alongside this script.
TOOLBOX_LIB="${PVE_TOOLBOX_LIB:-/usr/local/lib/pve-toolbox}"
# shellcheck source=../../lib/discord.sh
source "$TOOLBOX_LIB/discord.sh" 2>/dev/null \
    || { printf 'error: cannot source %s/discord.sh\n' "$TOOLBOX_LIB" >&2; exit 1; }

JOB=""
HOST_SHORT=$(hostname -s 2>/dev/null || hostname)

log()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; }


# ------------------------------------------------------------------- zfs --

_ds_exists() { zfs list -H -o name "$1" >/dev/null 2>&1; }

# Bytes used, so the report can state how much the run actually moved.
_used_bytes() { zfs get -Hp -o value used "$1" 2>/dev/null || printf '0'; }
_snap_count() { zfs list -H -t snapshot -r -o name "$1" 2>/dev/null | grep -c . || printf '0'; }

_human() { # bytes -> 1.2G
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"
}

_hms() { printf '%02d:%02d:%02d' $(($1 / 3600)) $((($1 % 3600) / 60)) $(($1 % 60)); }

# ------------------------------------------------------------------ jobs --

# Job settings live under JOB_<NAME>_*; resolve them into JOB_SRC, JOB_DST, ...
_job_key() {
    local n=${1//[^A-Za-z0-9]/_}
    printf 'JOB_%s_%s' "${n^^}" "$2"
}

_load_job() {
    local var
    var=$(_job_key "$JOB" SRC);   JOB_SRC=${!var:-}
    var=$(_job_key "$JOB" DST);   JOB_DST=${!var:-}
    var=$(_job_key "$JOB" OPTS);  JOB_OPTS=${!var:-"--recursive"}
    var=$(_job_key "$JOB" CHOWN); JOB_CHOWN=${!var:-}
    var=$(_job_key "$JOB" CHMOD); JOB_CHMOD=${!var:-}
    var=$(_job_key "$JOB" PATH);  JOB_PATH=${!var:-}

    [[ -n $JOB_SRC ]] || fail "job '$JOB' has no source - is it in JOBS= in $CONF?"
    [[ -n $JOB_DST ]] || fail "job '$JOB' has no target"
}

# Fall back to the target's own mountpoint rather than a hardcoded /mnt path.
_target_path() {
    if [[ -n $JOB_PATH ]]; then
        printf '%s' "$JOB_PATH"
        return 0
    fi
    local mp
    mp=$(zfs get -H -o value mountpoint "$JOB_DST" 2>/dev/null || true)
    [[ -n $mp && $mp != none && $mp != legacy && $mp != - ]] && printf '%s' "$mp"
}

# --------------------------------------------------------------- reports --

_notify_start() {
    discord_notify "$DISCORD_WEBHOOK" "$DISCORD_INFO" "ZFS replication started - $JOB" \
        "Replicating *$JOB_SRC* to *$JOB_DST*." \
        Job    "$JOB" \
        Host   "$HOST_SHORT" \
        Source "$JOB_SRC" \
        Target "$JOB_DST"
}

_record() { # _record <status> <elapsed>
    printf '%s|%s|%s\n' "$1" "$(date -Is)" "$(_hms "$2")" > "$LOG_DIR/$JOB.last"
}

# ------------------------------------------------------------------ main --

main() {
    local mode=sync
    case ${1:-} in
        -h|--help) usage; exit 0 ;;
        --list)    mode=list ;;
        --test)    mode=selftest; shift ;;
    esac

    command -v jq   >/dev/null 2>&1 || fail "jq not found"
    command -v curl >/dev/null 2>&1 || fail "curl not found"

    if [[ -r $CONF ]]; then
        # shellcheck source=/dev/null
        source "$CONF"
    else
        fail "cannot read $CONF"
    fi

    if [[ $mode == list ]]; then
        printf '%s\n' $JOBS
        exit 0
    fi

    JOB=${1:-}
    [[ -n $JOB ]] || { usage >&2; exit 2; }
    [[ " $JOBS " == *" $JOB "* ]] || fail "unknown job: $JOB (JOBS='$JOBS')"
    _load_job

    if [[ $mode == selftest ]]; then
        discord_notify "$DISCORD_WEBHOOK" "$DISCORD_INFO" "pve-toolbox test notification" \
            "Replication reports for *$JOB* on *$HOST_SHORT* will arrive in this channel." \
            Job    "$JOB" \
            Host   "$HOST_SHORT" \
            Source "$JOB_SRC" \
            Target "$JOB_DST" \
            || fail "could not deliver the test notification - check DISCORD_WEBHOOK in $CONF"
        exit 0
    fi

    command -v syncoid >/dev/null 2>&1 || fail "syncoid not found - apt install sanoid"
    command -v zfs     >/dev/null 2>&1 || fail "zfs not found"

    # A slow run must not have a second copy started on top of it.
    local lock="/run/lock/pve-toolbox-zfs-sync-$JOB.lock"
    exec 9>"$lock"
    if ! flock -n 9; then
        log "job $JOB is already running - leaving it alone"
        exit 0
    fi

    _ds_exists "$JOB_SRC" || fail "source dataset does not exist: $JOB_SRC"

    mkdir -p "$LOG_DIR"
    chmod 0750 "$LOG_DIR"
    local logfile="$LOG_DIR/$JOB.log"
    [[ -f $logfile ]] && mv -f "$logfile" "$logfile.prev"
    {
        printf 'pve-toolbox zfs-replication job %s\n' "$JOB"
        printf 'started  %s\n' "$(date -Is)"
        printf 'source   %s\n' "$JOB_SRC"
        printf 'target   %s\n' "$JOB_DST"
        printf 'options  %s\n\n' "$JOB_OPTS"
    } > "$logfile"
    chmod 0640 "$logfile"

    if [[ $NOTIFY_START == 1 ]]; then _notify_start || true; fi

    local before_used before_snaps started rc=0
    before_used=$(_used_bytes "$JOB_DST")
    before_snaps=$(_snap_count "$JOB_DST")
    started=$SECONDS

    log "replicating $JOB_SRC -> $JOB_DST"
    # shellcheck disable=SC2086
    syncoid $JOB_OPTS "$JOB_SRC" "$JOB_DST" >> "$logfile" 2>&1 || rc=$?
    local elapsed=$((SECONDS - started))

    if [[ $rc -ne 0 ]]; then
        local tail_out desc
        tail_out=$(tail -n "$LOG_TAIL" "$logfile")
        desc=$(printf 'syncoid exited %s. Last %s lines of %s:\n%s' \
                      "$rc" "$LOG_TAIL" "$logfile" "$(discord_fence "$tail_out")")
        _record failed "$elapsed"
        discord_notify "$DISCORD_WEBHOOK" "$DISCORD_ERR" "ZFS replication failed - $JOB" "$desc" \
            Job         "$JOB" \
            Host        "$HOST_SHORT" \
            Source      "$JOB_SRC" \
            Target      "$JOB_DST" \
            "Exit code" "$rc" \
            Duration    "$(_hms "$elapsed")" || true
        fail "syncoid exited $rc - see $logfile"
    fi

    # Ownership fixups, only where they were actually asked for.
    local path perms="not requested"
    path=$(_target_path)
    if [[ -n $JOB_CHOWN || -n $JOB_CHMOD ]]; then
        if [[ -z $path ]]; then
            perms="skipped, $JOB_DST has no mountpoint"
            log "warning: $perms"
        elif [[ ! -d $path ]]; then
            perms="skipped, $path is not a directory"
            log "warning: $perms"
        else
            perms=""
            if [[ -n $JOB_CHOWN ]]; then
                chown -R "$JOB_CHOWN" "$path" && perms="owner $JOB_CHOWN"
            fi
            if [[ -n $JOB_CHMOD ]]; then
                chmod -R "$JOB_CHMOD" "$path" && perms="${perms:+$perms, }mode $JOB_CHMOD"
            fi
            perms="${perms:-none} on $path"
            log "applied $perms"
        fi
    fi

    local after_used after_snaps delta
    after_used=$(_used_bytes "$JOB_DST")
    after_snaps=$(_snap_count "$JOB_DST")
    delta=$((after_used - before_used))
    [[ $delta -lt 0 ]] && delta=0

    # syncoid succeeded but a requested chown/chmod did not land: the original
    # script reported that as a clean success. Flag it instead.
    local color=$DISCORD_OK verdict="finished"
    if [[ $perms == skipped* ]]; then
        color=$DISCORD_WARN
        verdict="finished, permissions not applied"
    fi

    _record ok "$elapsed"
    printf '\nfinished %s after %s\n' "$(date -Is)" "$(_hms "$elapsed")" >> "$logfile"

    discord_notify "$DISCORD_WEBHOOK" "$color" "ZFS replication $verdict - $JOB" \
        "Replicated *$JOB_SRC* to *$JOB_DST*." \
        Job          "$JOB" \
        Host         "$HOST_SHORT" \
        Source       "$JOB_SRC" \
        Target       "$JOB_DST" \
        Duration     "$(_hms "$elapsed")" \
        Grew         "$(_human "$delta")" \
        "Target size" "$(_human "$after_used")" \
        Snapshots    "$before_snaps to $after_snaps" \
        Permissions  "$perms" || true
    log "done in $(_hms "$elapsed")"
}

main "$@"
