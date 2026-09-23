#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source lib/pve.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

MODE=good
PVE_LOG=$(mktemp)
trap 'rm -f -- "$PVE_LOG"' EXIT
pvesh() {
    printf '%s\n' "$*" >> "$PVE_LOG"
    [[ $# == 4 && $1 == get && $3 == --output-format && $4 == json ]] || return 99
    case "$MODE:$2" in
        duplicate:/nodes/pve1/qemu)
            printf '[{"vmid":201,"status":"running"},{"vmid":201,"status":"running"}]' ;;
        malformed:/nodes/pve1/qemu) printf '{"vmid":201}' ;;
        remote:/nodes/pve1/qemu) printf '[]' ;;
        race:/nodes/pve1/qemu)
            if [[ $(awk '/^get \/nodes\/pve1\/qemu / { n++ } END { print n+0 }' "$PVE_LOG") -ge 2 ]]; then printf '[]'; else printf '[{"vmid":201,"status":"running"}]'; fi ;;
        stopped:/nodes/pve1/qemu) printf '[{"vmid":201,"status":"stopped"}]' ;;
        *:/nodes/pve1/qemu) printf '[{"vmid":201,"status":"running","name":"debian-vm"}]' ;;
        locked:/nodes/pve1/qemu/201/config) printf '{"lock":"backup","smbios1":"uuid=11111111-2222-3333-4444-555555555555"}' ;;
        template:/nodes/pve1/qemu/201/config) printf '{"template":1,"smbios1":"uuid=11111111-2222-3333-4444-555555555555"}' ;;
        disabled:/nodes/pve1/qemu/201/config) printf '{"agent":"enabled=0","smbios1":"uuid=11111111-2222-3333-4444-555555555555"}' ;;
        nouuid:/nodes/pve1/qemu/201/config) printf '{"agent":"1"}' ;;
        changeduuid:/nodes/pve1/qemu/201/config) printf '{"agent":"1","smbios1":"uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}' ;;
        *:/nodes/pve1/qemu/201/config) printf '{"agent":"1","smbios1":"uuid=11111111-2222-3333-4444-555555555555"}' ;;
        moved:/nodes/pve1/qemu/201/status/current) return 1 ;;
        stopped:/nodes/pve1/qemu/201/status/current) printf '{"status":"stopped"}' ;;
        *:/nodes/pve1/qemu/201/status/current) printf '{"status":"running"}' ;;
        *) return 99 ;;
    esac
}

pve_qemu_inventory pve1 || fail 'valid local inventory rejected'
pve_qemu_ready pve1 201 || fail 'local running VM rejected'
[[ $PVE_QEMU_CONFIG_JSON == *'"agent":"1"'* ]] || fail 'VM config not returned'
for id in 0 99 201x ../201 '201;touch /tmp/unsafe'; do
    if pve_qemu_ready pve1 "$id"; then fail 'unsafe VMID accepted'; fi
done
if pve_qemu_ready ../pve1 201; then fail 'unsafe node accepted'; fi
for MODE in duplicate malformed remote locked template stopped moved; do
    if pve_qemu_ready pve1 201; then fail "$MODE accepted"; fi
    [[ -z $PVE_QEMU_CONFIG_JSON ]] || fail 'failed validation left stale config'
done
MODE=race
: > "$PVE_LOG"
if pve_qemu_ready pve1 201; then fail 'migration after status accepted'; fi
[[ -z $PVE_QEMU_CONFIG_JSON ]] || fail 'migration retained stale VM config'
for MODE in disabled nouuid changeduuid; do
    pve_qemu_ready pve1 201 || fail "$MODE VM rejected by generic readiness"
done
MODE=duplicate
if pve_qemu_inventory pve1; then fail 'duplicate VMID accepted'; fi
[[ -z $PVE_QEMU_JSON ]] || fail 'failed inventory left stale JSON'
if awk '/^(create|set|delete) / { bad=1 } END { exit !bad }' "$PVE_LOG"; then fail 'VM validation mutated PVE'; fi
printf 'ok local QEMU validation rejects unsafe or moved targets\n'
