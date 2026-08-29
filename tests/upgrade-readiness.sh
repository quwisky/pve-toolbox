#!/usr/bin/env bash
# Mixed-cluster fixtures for the read-only upgrade preflight.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/conf" "$WORK/state" "$WORK/apt/sources.list.d"
printf '%s\n' \
    'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' \
    'deb https://packages.example.test/tool trixie main' > "$WORK/apt/sources.list"
: > "$WORK/reboot-required"

TOOLBOX_CONF_DIR="$WORK/conf"
TOOLBOX_STATE_DIR="$WORK/state"
UR_APT_DIR="$WORK/apt"
UR_REBOOT_FILE="$WORK/reboot-required"
UR_NOW_EPOCH=2000000000
export TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR UR_APT_DIR UR_REBOOT_FILE UR_NOW_EPOCH

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/report.sh
source "$ROOT/lib/report.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"
# shellcheck source=modules/upgrade-readiness/module.sh
source "$ROOT/modules/upgrade-readiness/module.sh"

dpkg() {
    [[ $* == '--get-selections' ]] || fail "unexpected dpkg invocation: $*"
    printf '%s\n' $'pve-manager\tinstall' $'linux-image-amd64\thold'
}

df() {
    [[ ${1:-} == -Pm && ${2:-} == -- ]] || fail "unexpected df invocation: $*"
    if [[ ${3:-} == / ]]; then
        printf '%s\n' 'Filesystem 1048576-blocks Used Available Capacity Mounted on' '/dev/root 10000 9000 1000 90% /'
    else
        printf '%s\n' 'Filesystem 1048576-blocks Used Available Capacity Mounted on' "/dev/test 10000 6000 4000 60% ${3:-}"
    fi
}

pvesh() {
    [[ ${1:-} == get ]] || fail "upgrade preflight attempted a mutating PVE call: $*"
    case ${2:-} in
        /nodes) printf '%s\n' '[{"node":"pve1"},{"node":"pve2"},{"node":"pve3"}]' ;;
        /nodes/pve3/status) return 1 ;;
        /nodes/*/status) printf '%s\n' '{"status":"online"}' ;;
        /nodes/pve1/version) printf '%s\n' '{"version":"9.0.3"}' ;;
        /nodes/pve2/version) printf '%s\n' '{"version":"8.4.8"}' ;;
        /nodes/pve1/services) printf '%s\n' '[{"name":"pveproxy.service","state":"failed"}]' ;;
        /nodes/pve2/services) printf '%s\n' '[]' ;;
        /nodes/pve1/storage) printf '%s\n' '[{"storage":"local","enabled":1,"active":0}]' ;;
        /nodes/pve2/storage) printf '%s\n' '[{"storage":"local","enabled":1,"active":1}]' ;;
        /cluster/resources) printf '%s\n' '[{"vmid":100,"type":"qemu"},{"vmid":101,"type":"lxc"}]' ;;
        /cluster/tasks)
            jq -n --argjson now "$UR_NOW_EPOCH" '[
              {type:"vzdump",id:100,status:"OK",endtime:($now-3600)},
              {type:"vzdump",id:101,status:"OK",endtime:($now-259200)}
            ]' ;;
        *) fail "unexpected PVE fixture endpoint: ${2:-}" ;;
    esac
}

result_state() {
    local wanted=$1 i
    for ((i = 0; i < ${#REPORT_IDS[@]}; i++)); do
        [[ ${REPORT_IDS[$i]} == "$wanted" ]] && { printf '%s' "${REPORT_STATES[$i]}"; return 0; }
    done
    return 1
}

conf_set upgrade-readiness UR_POLICY pve-9
conf_set upgrade-readiness UR_BACKUP_HOURS 48
conf_set upgrade-readiness UR_MIN_FREE_MB 2048
doctor_reset
module_doctor
[[ $(report_exit_code) == 1 ]] || fail "upgrade blockers did not return failure"
[[ $(result_state repository.1) == fail ]] || fail "bad official suite was not failed"
[[ $(result_state repository.2) == warn ]] || fail "third-party repository was not warned"
[[ $(result_state packages.holds) == fail ]] || fail "held package was not failed"
[[ $(result_state reboot.pending) == fail ]] || fail "pending reboot was not failed"
[[ $(result_state space.root) == fail ]] || fail "low root space was not failed"
[[ $(result_state node.pve2.version) == fail ]] || fail "mixed PVE major was not failed"
[[ $(result_state cluster.versions) == warn ]] || fail "cluster version skew was not warned"
[[ $(result_state node.pve3.reachability) == fail ]] || fail "unavailable cluster node was not failed"
[[ $(result_state node.pve1.services) == fail ]] || fail "failed service was not failed"
[[ $(result_state node.pve1.storage) == fail ]] || fail "inactive storage was not failed"
[[ $(result_state backup.100) == pass ]] || fail "recent backup did not pass"
[[ $(result_state backup.101) == fail ]] || fail "missing recent backup was not failed"
pass "mixed versions, suites, holds, space, services, storage, and backups"

conf_clear upgrade-readiness
UR_POLICY='../escape' UR_BACKUP_HOURS=48 UR_MIN_FREE_MB=2048
_ur_load && fail "unsafe policy name was accepted"
UR_POLICY=pve-9 UR_BACKUP_HOURS=0 UR_MIN_FREE_MB=2048
_ur_load && fail "zero backup policy was accepted"
pass "upgrade policy input fails closed"
