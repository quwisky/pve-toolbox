#!/usr/bin/env bash
#
# pve-toolbox-zfs-scrub - scrub one ZFS pool and report to a Discord webhook.
#
# Installed by the pve-toolbox 'zfs-scrub' module as
# /usr/local/bin/pve-toolbox-zfs-scrub and driven by one systemd timer per pool:
#
#   pve-toolbox-zfs-scrub <pool>         start a scrub, wait for it, report start + result
#   pve-toolbox-zfs-scrub --test <pool>  send a test notification, scrub nothing
#
# One pool per invocation on purpose: every pool gets its own timer, its own
# schedule and its own pair of Discord messages.
#
# Config, written by the module. Root-only, because the webhook URL is the
# only credential Discord checks:
#
#   /etc/pve-toolbox/zfs-scrub.conf
#     DISCORD_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>'
#     POLL_INTERVAL=300
#     NOTIFY_START=1
#
set -euo pipefail

CONF="${SCRUB_CONF:-/etc/pve-toolbox/zfs-scrub.conf}"

DISCORD_WEBHOOK=""
POLL_INTERVAL=300
NOTIFY_START=1

# Reporting comes from the shared lib installed alongside this script.
TOOLBOX_LIB="${PVE_TOOLBOX_LIB:-/usr/local/lib/pve-toolbox}"
# shellcheck source=../../lib/discord.sh
source "$TOOLBOX_LIB/discord.sh" 2>/dev/null \
    || { printf 'error: cannot source %s/discord.sh\n' "$TOOLBOX_LIB" >&2; exit 1; }

POOL=""
HOST_SHORT=$(hostname -s 2>/dev/null || hostname)

log()  { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------- zfs --

_pool_exists() { zpool list -H -o name "$1" >/dev/null 2>&1; }
_health()      { zpool list -H -o health "$1" 2>/dev/null || printf 'UNKNOWN'; }
_scrubbing()   { zpool status "$1" 2>/dev/null | grep -q 'scrub in progress'; }

# The scan: line is the one summary zfs keeps across reboots.
_scan_line() {
    zpool status "$1" 2>/dev/null \
        | sed -n 's/^[[:space:]]*scan:[[:space:]]*//p' | head -n1
}

_errors_line() {
    zpool status -v "$1" 2>/dev/null \
        | sed -n 's/^errors:[[:space:]]*//p' | head -n1
}

_capacity() {
    local size alloc cap
    IFS=$'\t' read -r size alloc cap \
        < <(zpool list -H -o size,alloc,cap "$1" 2>/dev/null) || true
    printf '%s of %s used, cap %s' "${alloc:--}" "${size:--}" "${cap:--}"
}

_hms() { printf '%02d:%02d:%02d' $(($1 / 3600)) $((($1 % 3600) / 60)) $(($1 % 60)); }

# _result <scan-line> -> sets R_STATE R_REPAIRED R_DURATION R_ERRORS
_result() {
    local line=$1
    R_STATE=unknown; R_REPAIRED="-"; R_DURATION="-"; R_ERRORS="-"
    case $line in
        *"scrub in progress"*) R_STATE=running ;;
        *"scrub canceled"*)    R_STATE=canceled ;;
        *"scrub paused"*)      R_STATE=paused ;;
        *"scrub repaired"*)    R_STATE=finished ;;
        *resilver*)            R_STATE=resilver ;;
    esac
    [[ $R_STATE == finished ]] || return 0
    R_REPAIRED=$(sed -n 's/.*scrub repaired \([^ ]*\) in .*/\1/p' <<<"$line")
    R_DURATION=$(sed -n 's/.* in \(.*\) with [0-9][0-9]* errors.*/\1/p' <<<"$line")
    R_ERRORS=$(sed -n 's/.* with \([0-9][0-9]*\) errors.*/\1/p' <<<"$line")
    : "${R_REPAIRED:=-}" "${R_DURATION:=-}" "${R_ERRORS:=-}"
}

# ---------------------------------------------------------------- report --

_notify_start() {
    discord_notify "$DISCORD_WEBHOOK" "$DISCORD_INFO" "ZFS scrub started - $POOL" \
        "Scrub of *$POOL* is now running. The result lands here when it finishes." \
        Host     "$HOST_SHORT" \
        Pool     "$POOL" \
        Health   "$(_health "$POOL")" \
        Capacity "$(_capacity "$POOL")"
}

_notify_result() {
    local elapsed=$1 scan health errors color verdict
    scan=$(_scan_line "$POOL")
    health=$(_health "$POOL")
    errors=$(_errors_line "$POOL")
    _result "$scan"

    case $R_STATE in
        finished)
            if [[ $R_ERRORS =~ ^[0-9]+$ ]] && [[ $R_ERRORS -gt 0 ]]; then
                color=$DISCORD_ERR;  verdict="finished with $R_ERRORS errors"
            elif [[ $health != ONLINE ]]; then
                color=$DISCORD_WARN; verdict="finished, pool is $health"
            elif [[ $R_REPAIRED != 0B && $R_REPAIRED != 0 && $R_REPAIRED != "-" ]]; then
                color=$DISCORD_WARN; verdict="finished, repaired $R_REPAIRED"
            else
                color=$DISCORD_OK;   verdict="finished clean"
            fi ;;
        canceled) color=$DISCORD_WARN; verdict="canceled" ;;
        paused)   color=$DISCORD_WARN; verdict="paused" ;;
        *)        color=$DISCORD_WARN; verdict="finished, status not recognised" ;;
    esac

    # A scan line can report 0 errors while zfs still knows about damaged files.
    if [[ -n $errors && $errors != "No known data errors" ]]; then
        color=$DISCORD_ERR
        verdict="finished, data errors on the pool"
    fi

    discord_notify "$DISCORD_WEBHOOK" "$color" "ZFS scrub $verdict - $POOL" "$scan" \
        Host          "$HOST_SHORT" \
        Pool          "$POOL" \
        Health        "$health" \
        Repaired      "$R_REPAIRED" \
        Errors        "$R_ERRORS" \
        "Scrub time"  "$R_DURATION" \
        "Watched for" "$(_hms "$elapsed")" \
        "Data errors" "${errors:--}"
}

# Stopping the unit does not stop the scrub - say so rather than going quiet.
_on_signal() {
    trap - TERM INT
    discord_notify "$DISCORD_WEBHOOK" "$DISCORD_WARN" "ZFS scrub no longer watched - $POOL" \
        "The watcher unit was stopped, so no result will be reported for this run. The scrub itself keeps running in the kernel; follow it with 'zpool status $POOL'." \
        Host "$HOST_SHORT" \
        Pool "$POOL"
    exit 143
}

# ------------------------------------------------------------------ main --

main() {
    local mode=scrub
    case ${1:-} in
        -h|--help) usage; exit 0 ;;
        --test)    mode=selftest; shift ;;
    esac

    POOL=${1:-}
    [[ -n $POOL ]] || { usage >&2; exit 2; }

    command -v zpool >/dev/null 2>&1 || fail "zpool not found - is this a ZFS host?"
    command -v jq    >/dev/null 2>&1 || fail "jq not found"
    command -v curl  >/dev/null 2>&1 || fail "curl not found"

    if [[ -r $CONF ]]; then
        # shellcheck source=/dev/null
        source "$CONF"
    else
        log "warning: cannot read $CONF - falling back to defaults"
    fi
    [[ $POLL_INTERVAL =~ ^[0-9]+$ ]] || POLL_INTERVAL=300
    if [[ $POLL_INTERVAL -lt 10 ]]; then POLL_INTERVAL=10; fi

    _pool_exists "$POOL" || fail "no such ZFS pool: $POOL"

    if [[ $mode == selftest ]]; then
        discord_notify "$DISCORD_WEBHOOK" "$DISCORD_INFO" "pve-toolbox test notification" \
            "Scrub reports for *$POOL* on *$HOST_SHORT* will arrive in this channel." \
            Host        "$HOST_SHORT" \
            Pool        "$POOL" \
            Health      "$(_health "$POOL")" \
            "Last scan" "$(_scan_line "$POOL")" \
            || fail "could not deliver the test notification - check DISCORD_WEBHOOK in $CONF"
        exit 0
    fi

    if _scrubbing "$POOL"; then
        log "a scrub is already running on $POOL - leaving it alone"
        exit 0
    fi

    trap _on_signal TERM INT

    if [[ $NOTIFY_START == 1 ]]; then _notify_start || true; fi

    if ! zpool scrub "$POOL"; then
        discord_notify "$DISCORD_WEBHOOK" "$DISCORD_ERR" "ZFS scrub failed to start - $POOL" \
            "'zpool scrub $POOL' returned an error, so nothing is running." \
            Host   "$HOST_SHORT" \
            Pool   "$POOL" \
            Health "$(_health "$POOL")" || true
        fail "zpool scrub $POOL failed"
    fi
    log "scrub of $POOL started, polling every ${POLL_INTERVAL}s"

    local started=$SECONDS
    sleep 5
    while _scrubbing "$POOL"; do
        sleep "$POLL_INTERVAL"
    done

    trap - TERM INT
    _notify_result "$((SECONDS - started))" || true
}

main "$@"
