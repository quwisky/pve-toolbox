#!/usr/bin/env bash
set -euo pipefail

tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$MOCK_LOG"
exists() { [[ -f $MOCK_STATE/$1.exists ]]; }

case $tool in
    qm|pct)
        action=${1:-}; id=${2:-}
        case $action in
            status)
                exists "$id" || exit 2
                printf 'status: %s\n' "$(<"$MOCK_STATE/$id.status")" ;;
            config)
                exists "$id" || exit 2
                [[ ${MOCK_CONFIG_FAIL:-0} != 1 ]] || exit 1
                [[ ! -f $MOCK_STATE/$id.marker ]] \
                    || printf 'description: %s\n' "$(<"$MOCK_STATE/$id.marker")"
                if [[ $tool == qm ]]; then
                    printf 'net0: virtio=02:00:00:00:00:01,bridge=vmbr0\n'
                    printf 'scsi0: test-store:vm-%s-disk-0,size=8G\n' "$id"
                else
                    printf 'net0: name=eth0,bridge=vmbr0\n'
                    printf 'rootfs: test-store:subvol-%s-disk-0,size=8G\n' "$id"
                fi ;;
            set)
                exists "$id" || exit 2
                shift 2
                while [[ $# -gt 0 ]]; do
                    case $1 in
                        --description) printf '%s' "$2" > "$MOCK_STATE/$id.marker"; shift 2 ;;
                        --delete|--onboot|--net[0-9]*|--scsi[0-9]*|--rootfs|--mp[0-9]*) shift 2 ;;
                        *) shift ;;
                    esac
                done ;;
            start)
                exists "$id" || exit 2
                [[ ${MOCK_PROBE_FAIL:-0} == 1 ]] \
                    || printf 'running' > "$MOCK_STATE/$id.status" ;;
            stop)
                exists "$id" || exit 2
                printf 'stopped' > "$MOCK_STATE/$id.status" ;;
            restore)
                [[ $tool == pct && ${MOCK_RESTORE_FAIL:-0} != 1 ]] || exit 1
                : > "$MOCK_STATE/$id.exists"
                printf 'stopped' > "$MOCK_STATE/$id.status" ;;
            destroy)
                [[ ${MOCK_DESTROY_FAIL:-0} != 1 ]] || exit 1
                exists "$id" || exit 2
                rm -f -- "$MOCK_STATE/$id.exists" "$MOCK_STATE/$id.status" "$MOCK_STATE/$id.marker" ;;
            *) exit 64 ;;
        esac ;;
    qmrestore)
        backup=${1:-}; id=${2:-}
        [[ ${MOCK_RESTORE_FAIL:-0} != 1 ]] || exit 1
        [[ -n $backup && $id =~ ^[0-9]+$ ]] || exit 64
        : > "$MOCK_STATE/$id.exists"
        printf 'stopped' > "$MOCK_STATE/$id.status" ;;
    *) exit 64 ;;
esac
