#!/usr/bin/env bash
# Guest and host command doubles; real updater code is executed unchanged.
set -euo pipefail
name=${0##*/}
case $name in
    pveversion) printf 'pve-manager/9.0.0/test\n' ;;
    pvesh)
        path=$2
        if [[ $path == */lxc ]]; then
            cat "$LX_TEST/inventory.json"
        elif [[ $path == */config ]]; then
            id=${path%/config}; id=${id##*/}
            if [[ -f $LX_TEST/$id.config ]]; then cat "$LX_TEST/$id.config"
            else printf '{"ostype":"debian"}\n'; fi
        elif [[ $path == */status/current ]]; then
            printf '{"status":"running"}\n'
        else exit 1; fi ;;
    pct)
        [[ $1 == exec && $3 == -- && $4 == bash && $5 == -s && $6 == -- ]] || exit 64
        printf 'pct %s %s\n' "$2" "$7" >> "$LX_TEST/calls"
        export LX_TEST_CT=$2
        exec /bin/bash -s -- "$7" "$8" ;;
    awk)
        args=("$@")
        if [[ ${args[-1]} == /etc/os-release && -f $LX_TEST/os-release ]]; then
            args[-1]="$LX_TEST/os-release"
        fi
        exec /usr/bin/awk "${args[@]}" ;;
    apt-get)
        printf 'apt %s ' "${LX_TEST_CT:-none}" >> "$LX_TEST/calls"
        printf '%s ' "$@" >> "$LX_TEST/calls"
        printf '\n' >> "$LX_TEST/calls"
        action="" simulate=0
        for arg in "$@"; do
            case $arg in
                indextargets|update|upgrade|dist-upgrade|autoremove|autoclean) action=$arg ;;
                --simulate) simulate=1 ;;
            esac
        done
        if [[ $action == indextargets ]]; then
            if [[ -f $LX_TEST/targets ]]; then cat "$LX_TEST/targets"
            else printf 'Origin: Debian\nCodename: trixie\nTrusted: yes\nIdentifier: Packages\n\n'; fi
        elif [[ $action == update ]]; then
            [[ ! -f $LX_TEST/fail-refresh-${LX_TEST_CT} ]] || exit 100
            printf 'Package indexes refreshed\n'
        elif [[ $simulate == 1 ]]; then
            printf 'The following packages have been kept back:\n  held-app\n1 upgraded, 0 newly installed, 0 to remove and 1 not upgraded.\nInst sample [1] (2 test)\n'
        else
            if [[ -f $LX_TEST/delay ]]; then
                printf 'ACTIVE TRANSACTION\n'
                sleep 2
                printf 'transaction-finished\n' >> "$LX_TEST/calls"
            fi
            [[ ! -f $LX_TEST/fail-${LX_TEST_CT} && ! -f $LX_TEST/fail-${action}-${LX_TEST_CT} ]] || exit 100
            printf 'Updated sample; password=fixture-secret\n'
        fi ;;
    apt-mark) printf 'held-app\n' ;;
    dpkg)
        [[ $1 == --audit ]] || exit 64
        [[ ! -f $LX_TEST/broken ]] || printf 'package database needs repair\n' ;;
    curl)
        printf 'discord\n' >> "$LX_TEST/calls"
        [[ ! -f $LX_TEST/fail-notify ]] || exit 22
        # Capture the shared sender payload without contacting any service.
        while [[ $# -gt 0 ]]; do
            if [[ $1 == -d ]]; then printf "%s" "$2" > "$LX_TEST/discord.json"; break; fi
            shift
        done ;;
    systemd-analyze)
        schedule=${*: -1}
        [[ $1 == calendar && -n $schedule && $schedule != nonsense ]] || exit 1
        if [[ $schedule == '*-02-30 04:00:00' ]]; then
            printf 'Normalized form: *-02-30 04:00:00\n    Next elapse: never\n'
        else
            printf 'Normalized form: %s\n    Next elapse: Sun 2026-09-06 04:00:00 CEST\n' "$schedule"
        fi ;;
    systemctl)
        printf '%s\n' "$*" >> "$LX_TEST/calls"
        case ${1:-} in
            daemon-reload) ;;
            enable)
                [[ ${2:-} == --now && -n ${3:-} ]] || exit 1
                if [[ -f $LX_TEST/fail-enable ]]; then
                    rm "$LX_TEST/fail-enable"
                    exit 1
                fi
                rm -f "$LX_TEST/timer-inactive" "$LX_TEST/timer-failed"
                printf '%s\n' "$3" > "$LX_TEST/enabled-unit" ;;
            disable)
                if [[ -f $LX_TEST/fail-disable ]]; then
                    rm "$LX_TEST/fail-disable"
                    exit 1
                fi
                rm -f "$LX_TEST/enabled-unit" ;;
            is-enabled)
                unit=${*: -1}
                [[ -f $LX_TEST/enabled-unit && $(<"$LX_TEST/enabled-unit") == "$unit" ]] ;;
            is-active)
                unit=${*: -1}
                [[ $unit == *.timer && -f $LX_TEST/enabled-unit \
                    && ! -f $LX_TEST/timer-inactive ]] ;;
            is-failed)
                unit=${*: -1}
                if [[ $unit == *.timer ]]; then [[ -f $LX_TEST/timer-failed ]]
                else [[ -f $LX_TEST/service-failed ]]; fi ;;
            reset-failed)
                unit=${*: -1}
                if [[ $unit == *.timer ]]; then rm -f "$LX_TEST/timer-failed"
                else rm -f "$LX_TEST/service-failed"; fi ;;
            show)
                if [[ $* == *NextElapseUSecRealtime* ]]; then
                    printf 'Sun 2026-09-06 04:17:00 CEST\n'
                else
                    printf 'Sun 2026-08-30 04:11:00 CEST\n'
                fi ;;
            list-unit-files)
                [[ ! -f $LX_TEST/enabled-unit ]] || printf '%s enabled\n' "$(<"$LX_TEST/enabled-unit")" ;;
            *) ;;
        esac ;;
    *) exit 64 ;;
esac
