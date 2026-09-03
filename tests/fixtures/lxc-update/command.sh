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
    *) exit 64 ;;
esac
