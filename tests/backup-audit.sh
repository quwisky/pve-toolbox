#!/usr/bin/env bash
# Fixture tests for the read-only backup audit module.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

TOOLBOX_CONF_DIR="$WORK/conf"
TOOLBOX_STATE_DIR="$WORK/state"
export TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/report.sh
source "$ROOT/lib/report.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"
# shellcheck source=modules/backup-audit/module.sh
source "$ROOT/modules/backup-audit/module.sh"

BA_NOW_EPOCH=2000000000
BA_SCENARIO=success
export BA_NOW_EPOCH BA_SCENARIO

pvesh() {
    [[ ${1:-} == get ]] || fail "backup audit attempted a non-read-only pvesh action: $*"
    local endpoint=${2:-}
    case "$BA_SCENARIO:$endpoint" in
        success:/cluster/resources)
            printf '%s\n' '[{"vmid":100,"node":"pve1","type":"qemu","name":"web"}]' ;;
        success:/cluster/backup)
            printf '%s\n' '[{"id":"job-ok","enabled":1,"all":1,"storage":"backup","prune-backups":"keep-last=3"}]' ;;
        success:/cluster/tasks)
            printf '%s\n' '[{"type":"vzdump","id":"100","status":"OK","endtime":1999996400}]' ;;
        success:/nodes/pve1/qemu/100/config)
            printf '%s\n' '{"scsi0":"local-lvm:vm-100-disk-0,size=8G"}' ;;
        success:/nodes/pve1/storage)
            printf '%s\n' '[{"storage":"backup","enabled":1,"active":1,"total":100,"used":20}]' ;;

        warning:/cluster/resources)
            printf '%s\n' '[
                {"vmid":100,"node":"pve1","type":"qemu"},
                {"vmid":101,"node":"pve1","type":"lxc"},
                {"vmid":102,"node":"pve2","type":"qemu"},
                {"vmid":103,"node":"pve2","type":"lxc"},
                {"vmid":104,"node":"pve2","type":"qemu"}
            ]' ;;
        warning:/cluster/backup)
            printf '%s\n' '[
                {"id":"enabled","enabled":1,"vmid":"100,103,104","exclude":"101","storage":"backup"},
                {"id":"disabled","enabled":0,"vmid":"102","storage":"backup","prune-backups":"keep-last=3"}
            ]' ;;
        warning:/cluster/tasks)
            printf '%s\n' '[
                {"type":"vzdump","id":"100","status":"OK","endtime":1999996400},
                {"type":"vzdump","id":"103","status":"OK","endtime":1999700000},
                {"type":"vzdump","id":"104","status":"OK","endtime":1999996400},
                {"type":"vzdump","id":"104","status":"backup failed","endtime":1999990000}
            ]' ;;
        warning:/nodes/pve1/qemu/100/config)
            printf '%s\n' '{"scsi0":"backup:vm-100-disk-0,backup=0,size=8G"}' ;;
        warning:/nodes/pve2/lxc/103/config)
            printf '%s\n' '{"rootfs":"backup:subvol-103-disk-0,size=8G","mp0":"backup:subvol-103-disk-1,mp=/data,size=8G"}' ;;
        warning:/nodes/pve2/qemu/104/config)
            printf '%s\n' '{"virtio0":"backup:vm-104-disk-0,size=8G"}' ;;
        warning:/nodes/pve1/storage)
            printf '%s\n' '[{"storage":"backup","enabled":1,"active":1,"total":100,"used":88}]' ;;
        warning:/nodes/pve2/storage)
            printf '%s\n' '[{"storage":"backup","enabled":1,"active":1,"total":100,"used":50}]' ;;

        failure:/cluster/resources)
            printf '%s\n' '[
                {"vmid":200,"node":"pve1","type":"qemu"},
                {"vmid":201,"node":"pve1","type":"lxc"}
            ]' ;;
        failure:/cluster/backup)
            printf '%s\n' '[{"id":"weak","enabled":1,"vmid":"201","storage":"offline","prune-backups":"keep-last=1"}]' ;;
        failure:/cluster/tasks)
            printf '%s\n' '[
                {"type":"vzdump","id":"201","status":"backup failed","endtime":1999996400},
                {"type":"vzdump","id":"201","status":"backup failed","endtime":1999990000}
            ]' ;;
        failure:/nodes/pve1/lxc/201/config)
            printf '%s\n' '{"rootfs":"local-lvm:subvol-201-disk-0,size=8G"}' ;;
        failure:/nodes/pve1/storage)
            printf '%s\n' '[{"storage":"offline","enabled":1,"active":0,"total":100,"used":99}]' ;;

        api-failure:/cluster/resources)
            printf 'permission denied\n' >&2
            return 7 ;;
        *)
            fail "unexpected pvesh fixture request: $BA_SCENARIO $endpoint" ;;
    esac
}

result_state() { # result_state <id>
    local wanted=$1 i
    for ((i = 0; i < ${#REPORT_IDS[@]}; i++)); do
        if [[ ${REPORT_IDS[$i]} == "$wanted" ]]; then
            printf '%s' "${REPORT_STATES[$i]}"
            return 0
        fi
    done
    return 1
}

conf_set backup-audit BA_FRESHNESS_HOURS 48
conf_set backup-audit BA_STORAGE_WARN 85
conf_set backup-audit BA_STORAGE_FAIL 95
conf_set backup-audit BA_MIN_KEEP_LAST 2

doctor_reset
BA_SCENARIO=success
module_doctor
[[ $(report_exit_code) == 0 ]] || fail "healthy single-node fixture was not successful"
[[ $(result_state guest.100.coverage) == pass ]] || fail "covered guest was not reported"
[[ $(result_state guest.100.freshness) == pass ]] || fail "fresh backup was not reported"
[[ $(result_state storage.pve1.backup) == pass ]] || fail "healthy storage was not reported"
[[ $(result_state job.job-ok.retention) == pass ]] || fail "retention was not reported"
pass "single-node healthy backup audit"

doctor_reset
BA_SCENARIO=warning
module_doctor
[[ $(report_exit_code) == 2 ]] || fail "warning cluster fixture did not exit with warning"
[[ $(result_state guest.101.coverage) == warn ]] || fail "intentional exclusion was not distinguished"
[[ $(result_state guest.102.coverage) == warn ]] || fail "disabled-job coverage was not distinguished"
[[ $(result_state guest.103.freshness) == warn ]] || fail "stale success was not reported"
[[ $(result_state guest.100.volumes) == warn ]] || fail "excluded disk was not reported"
[[ $(result_state guest.103.volumes) == warn ]] || fail "non-included container mount was not reported"
[[ $(result_state guest.104.failures) == warn ]] || fail "single recent failure was not reported"
[[ $(result_state storage.pve1.backup) == warn ]] || fail "storage warning threshold was not applied"
[[ $(result_state job.enabled.retention) == warn ]] || fail "missing retention was not reported"
[[ $(printf '%s\n' "${REPORT_STATES[@]}" | grep -c '^fail$' || true) -eq 0 ]] \
    || fail "warning fixture produced a failure"
pass "cluster warning cases remain distinct"

doctor_reset
BA_SCENARIO=failure
module_doctor
[[ $(report_exit_code) == 1 ]] || fail "failure fixture did not exit failed"
[[ $(result_state guest.200.coverage) == fail ]] || fail "uncovered guest was not failed"
[[ $(result_state guest.201.freshness) == fail ]] || fail "missing success was not failed"
[[ $(result_state guest.201.failures) == fail ]] || fail "repeated failures were not failed"
[[ $(result_state storage.pve1.offline) == fail ]] || fail "unavailable storage was not failed"
[[ $(result_state job.weak.retention) == warn ]] || fail "weak retention was not warned"
pass "coverage, history, and storage failures fail closed"

doctor_reset
BA_SCENARIO=api-failure
module_doctor
[[ $(report_exit_code) == 1 ]] || fail "API failure did not fail the audit"
[[ $(result_state api.cluster-guest-inventory) == fail ]] \
    || fail "API failure did not produce a structured result"
[[ ${#REPORT_STATES[@]} -eq 1 ]] || fail "audit continued after guest inventory failure"
pass "Proxmox API failures do not produce partial success"

BA_FRESHNESS_HOURS=0 BA_STORAGE_WARN=85 BA_STORAGE_FAIL=95 BA_MIN_KEEP_LAST=2
_ba_validate_settings && fail "zero freshness was accepted"
[[ $BA_CONFIG_ERROR == *"positive integer"* ]] || fail "freshness error was not specific"
BA_FRESHNESS_HOURS=48 BA_STORAGE_WARN=95 BA_STORAGE_FAIL=85 BA_MIN_KEEP_LAST=2
_ba_validate_settings && fail "reversed storage thresholds were accepted"
BA_FRESHNESS_HOURS=48 BA_STORAGE_WARN=85 BA_STORAGE_FAIL=95 BA_MIN_KEEP_LAST=0
_ba_validate_settings && fail "zero retention minimum was accepted"
pass "threshold configuration is validated"
