#!/bin/bash
# PVE doubles on the host side. pct logs its full argv and runs guests in the chroot.
set -euo pipefail
case ${0##*/} in
    hostname) printf 'pve1\n' ;;
    pveversion) printf 'pve-manager/9.0\n' ;;
    timeout) # Records every limit and can stand in for an apply that ran out of time.
        printf '%s\n' "$*" >> "$BR_HOST/timeouts"
        if [[ -f $BR_HOST/apply-timeout && $* == *' apply '* ]]; then exit 124; fi
        exec /usr/bin/timeout "$@" ;;
    pvesh)
        [[ $1 == get && $3 == --output-format && $4 == json ]] || exit 98
        case $2 in
            /nodes/pve1/lxc) cat "$BR_HOST/inventory" ;;
            /nodes/pve1/lxc/101/config) cat "$BR_HOST/config" ;;
            /nodes/pve1/lxc/101/status/current) cat "$BR_HOST/status" ;;
            *) exit 98 ;;
        esac ;;
    pct)
        printf '%s\n' "$*" >> "$BR_PCT_LOG"
        action=$1; id=$2; shift 2
        [[ $id == 101 ]] || exit 98
        [[ ! -f $BR_HOST/pct-down ]] || exit 1
        case $action in
            exec)
                [[ $1 == -- ]] || exit 98
                shift
                if [[ -f $BR_HOST/apply-garbage && $* == *' apply '* ]]; then printf 'not json\n'; exit 0; fi
                # A canned guest outcome, as a fault the chroot guest cannot reach here produces it. Exits 1.
                if [[ -f $BR_HOST/apply-outcome && $* =~ pve-toolbox-bao-run-([0-9a-f]{32})/guest\.sh\ apply ]]; then
                    # As guest.sh leaves it after an incomplete restore.
                    if [[ -f $BR_HOST/apply-outcome-backup ]]; then
                        mkdir -m 0700 "$BR_TEST_ROOT/run/pve-toolbox-bao-run-${BASH_REMATCH[1]}/backup"
                        printf 'previous\n' > "$BR_TEST_ROOT/run/pve-toolbox-bao-run-${BASH_REMATCH[1]}/backup/0"
                    fi
                    jq -c --arg tx "${BASH_REMATCH[1]}" '.transaction_id = $tx' "$BR_HOST/apply-outcome"
                    exit 1
                fi
                # A guest that never stops writing, slowly enough that buffering it would not exhaust the test.
                if [[ -f $BR_HOST/flood-apply && $* == *' apply '* || -f $BR_HOST/flood-status && $* == *' status'* ]]; then
                    chunk=$(printf 'x%.0s' {1..65536})
                    while :; do printf '%s' "$chunk"; sleep 0.1; done
                fi
                if [[ -f $BR_HOST/replace-after-mkdir && $1 == mkdir ]]; then
                    printf 'fedcba9876543210fedcba9876543210\n' > "$BR_TEST_ROOT/etc/machine-id"
                fi
                if [[ -f $BR_HOST/status-filter && $* == *' status'* ]]; then
                    chroot "$BR_TEST_ROOT" "$@" | jq -c "$(<"$BR_HOST/status-filter")"
                    exit 0
                fi
                # Hangs the inspection that guest staging cleanup starts with.
                if [[ -f $BR_HOST/slow-status && $* == *' status'* ]]; then sleep 6; fi
                if [[ -f $BR_HOST/slow-after-apply && $* == *' apply '* ]]; then
                    rc=0
                    chroot "$BR_TEST_ROOT" "$@" || rc=$?
                    : > "$BR_HOST/slow-status"
                    exit "$rc"
                fi
                if [[ -f $BR_HOST/break-state-after-apply && $* == *' apply '* ]]; then
                    rc=0
                    chroot "$BR_TEST_ROOT" "$@" || rc=$?
                    mkdir "$TOOLBOX_STATE_DIR/bao-run-101.state"
                    exit "$rc"
                fi
                if [[ -f $BR_HOST/docker-up-after-first-apply && $* == *' apply '* ]]; then
                    rc=0
                    chroot "$BR_TEST_ROOT" "$@" || rc=$?
                    rm -f "$BR_HOST/docker-up-after-first-apply" "$BR_TEST_ROOT/docker-down"
                    exit "$rc"
                fi
                exec chroot "$BR_TEST_ROOT" "$@" ;;
            push)
                [[ $3 == --perms && $4 == 0600 && $2 =~ ^/run/pve-toolbox-bao-run-[a-f0-9]{32}/(guest\.sh|bao-run|request\.json)$ ]] || exit 98
                cp -- "$1" "$BR_TEST_ROOT$2"
                chmod 0600 "$BR_TEST_ROOT$2"
                if [[ -f $BR_HOST/foreign-in-stage ]]; then : > "$BR_TEST_ROOT${2%/*}/foreign"; fi ;;
            *) exit 98 ;;
        esac ;;
    *) exit 98 ;;
esac
