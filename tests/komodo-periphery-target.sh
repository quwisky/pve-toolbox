#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source lib/pve.sh
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
declare -F pve_lxc_ready >/dev/null || fail 'local LXC validation missing'
MODE=good
pvesh() {
    [[ $1 == get && $3 == --output-format && $4 == json ]] || return 99
    case "$MODE:$2" in
        good:/nodes/pve1/lxc) printf '[{"vmid":101,"status":"running","name":"web"}]' ;;
        duplicate:/nodes/pve1/lxc) printf '[{"vmid":101,"status":"running"},{"vmid":101,"status":"running"}]' ;;
        good:/nodes/pve1/lxc/101/config) printf '{"ostype":"debian","rootfs":"local:vm-101-disk-0"}' ;;
        locked:/nodes/pve1/lxc/101/config) printf '{"ostype":"debian","lock":"backup"}' ;;
        template:/nodes/pve1/lxc/101/config) printf '{"ostype":"debian","template":1}' ;;
        ubuntu:/nodes/pve1/lxc/101/config) printf '{"ostype":"ubuntu"}' ;;
        stopped:/nodes/pve1/lxc/101/config) printf '{"ostype":"debian"}' ;;
        stopped:/nodes/pve1/lxc/101/status/current) printf '{"status":"stopped"}' ;;
        good:/nodes/pve1/lxc/101/status/current) printf '{"status":"running"}' ;;
        *) return 1 ;;
    esac
}
pve_lxc_inventory pve1 || fail 'inventory rejected'
pve_lxc_ready pve1 101 || fail 'running target rejected'
for MODE in locked template ubuntu stopped moved; do
    if pve_lxc_ready pve1 101; then fail "$MODE accepted"; fi
    [[ -z $PVE_LXC_CONFIG_JSON ]] || fail 'stale configuration leaked'
done
MODE=good
for id in 0 99 abc '101;id' ../101; do
    if pve_lxc_ready pve1 "$id"; then fail 'invalid id accepted'; fi
done
if pve_lxc_ready ../pve1 101; then fail 'invalid node accepted'; fi
MODE=duplicate
if pve_lxc_inventory pve1; then fail 'duplicate inventory accepted'; fi
[[ -z $PVE_LXC_JSON ]] || fail 'stale inventory leaked'
printf 'ok local LXC targets fail closed\n'
