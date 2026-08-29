#!/usr/bin/env bash
# Directory, ZFS, and LVM-thin fixtures for the read-only hygiene audit.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/dir" "$WORK/conf" "$WORK/state"

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
# shellcheck source=modules/storage-hygiene/module.sh
source "$ROOT/modules/storage-hygiene/module.sh"

SH_NOW_EPOCH=2000000000
export SH_NOW_EPOCH

pvesh() {
    [[ ${1:-} == get ]] || fail "storage audit attempted a mutating PVE call: $*"
    local endpoint=${2:-}
    case $endpoint in
        /cluster/resources)
            printf '%s\n' '[
              {"vmid":100,"node":"pve1","type":"qemu"},
              {"vmid":101,"node":"pve1","type":"lxc"}
            ]' ;;
        /nodes)
            printf '%s\n' '[{"node":"pve1"}]' ;;
        /storage)
            jq -n --arg path "$WORK/dir" '[
              {storage:"local",type:"dir",path:$path,nodes:"pve1"},
              {storage:"local-copy",type:"dir",path:$path,nodes:"pve1"},
              {storage:"zfs-store",type:"zfspool",pool:"tank/data",nodes:"pve1"},
              {storage:"local-lvm",type:"lvmthin",vgname:"pve",thinpool:"data",nodes:"pve1"},
              {storage:"disabled",type:"dir",path:"/offline",disable:1,nodes:"pve1"}
            ]' ;;
        /nodes/pve1/qemu/100/config)
            printf '%s\n' '{
              "scsi0":"local:vm-100-disk-0,size=8G",
              "scsi1":"zfs-store:vm-100-disk-0,size=8G",
              "unused0":"local:vm-100-disk-9"
            }' ;;
        /nodes/pve1/lxc/101/config)
            printf '%s\n' '{"rootfs":"local:subvol-101-disk-0,size=8G"}' ;;
        /nodes/pve1/qemu/100/snapshot)
            printf '%s\n' '[
              {"name":"current"},
              {"name":"before-upgrade","snaptime":1991360000}
            ]' ;;
        /nodes/pve1/lxc/101/snapshot)
            printf '%s\n' '[]' ;;
        /nodes/pve1/storage)
            printf '%s\n' '[
              {"storage":"local","enabled":1,"active":1,"total":100,"used":90},
              {"storage":"local-copy","enabled":1,"active":1,"total":100,"used":10},
              {"storage":"zfs-store","enabled":1,"active":1,"total":100,"used":20},
              {"storage":"local-lvm","enabled":1,"active":1,"total":100,"used":97},
              {"storage":"disabled","enabled":0,"active":0,"total":100,"used":0}
            ]' ;;
        /nodes/pve1/storage/local/content)
            printf '%s\n' '[
              {"volid":"local:vm-100-disk-0","content":"images","vmid":100},
              {"volid":"local:vm-100-disk-9","content":"images","vmid":100},
              {"volid":"local:vm-100-disk-2","content":"images","vmid":100},
              {"volid":"local:vm-999-disk-0","content":"images","vmid":999},
              {"volid":"local:iso/old.iso","content":"iso","ctime":1980000000},
              {"volid":"local:vztmpl/fresh.tar.zst","content":"vztmpl","ctime":1999990000}
            ]' ;;
        /nodes/pve1/storage/local-copy/content|/nodes/pve1/storage/zfs-store/content|/nodes/pve1/storage/local-lvm/content)
            printf '%s\n' '[]' ;;
        *) fail "unexpected PVE fixture endpoint: $endpoint" ;;
    esac
}

df() {
    [[ ${1:-} == -Pi && ${2:-} == -- ]] || fail "unexpected df invocation: $*"
    printf '%s\n' \
        'Filesystem Inodes IUsed IFree IUse% Mounted on' \
        '/dev/test 100 88 12 88% /fixture'
}

zfs() {
    [[ $* == 'list -Hp -o name,type,used,available' ]] || fail "unexpected zfs invocation: $*"
    printf '%s\n' \
        $'tank/data/vm-100-disk-0\tvolume\t100\t900' \
        $'tank/data/vm-100-disk-8\tvolume\t100\t900' \
        $'tank/data/subvol-998-disk-0\tfilesystem\t100\t900'
}

lvs() {
    [[ $* == '--reportformat json --units b --nosuffix -o vg_name,lv_name,lv_attr,data_percent,metadata_percent' ]] \
        || fail "unexpected lvs invocation: $*"
    printf '%s\n' '{"report":[{"lv":[
      {"vg_name":"pve","lv_name":"data","lv_attr":"twi-aotz--","data_percent":"96.2","metadata_percent":"81.0"},
      {"vg_name":"pve","lv_name":"vm-100-disk-0","lv_attr":"Vwi-a-tz--","data_percent":"","metadata_percent":""}
    ]}]}'
}

result_state() {
    local wanted=$1 i
    for ((i = 0; i < ${#REPORT_IDS[@]}; i++)); do
        if [[ ${REPORT_IDS[$i]} == "$wanted" ]]; then
            printf '%s' "${REPORT_STATES[$i]}"
            return 0
        fi
    done
    return 1
}

conf_set storage-hygiene SH_SNAPSHOT_DAYS 30
conf_set storage-hygiene SH_CONTENT_DAYS 180
conf_set storage-hygiene SH_CAPACITY_WARN 85
conf_set storage-hygiene SH_CAPACITY_FAIL 95
conf_set storage-hygiene SH_THIN_WARN 80
conf_set storage-hygiene SH_THIN_FAIL 95

doctor_reset
module_doctor
[[ $(report_exit_code) == 1 ]] || fail "critical storage fixture did not fail"
[[ $(result_state guest.100.snapshot.before-upgrade) == warn ]] \
    || fail "old guest snapshot was not warned"
[[ $(result_state definition.duplicate.local-local-copy) == warn ]] \
    || fail "duplicate directory definitions were not detected"
[[ $(result_state definition.disabled.disabled) == warn ]] \
    || fail "disabled storage definition was not reported"
[[ $(result_state storage.pve1.local.capacity) == warn ]] \
    || fail "directory capacity warning was not applied"
[[ $(result_state storage.pve1.local-lvm.capacity) == fail ]] \
    || fail "storage capacity failure was not applied"
[[ $(result_state inode.local) == warn ]] || fail "directory inode pressure was not reported"
[[ $(result_state volume.local-vm-100-disk-9.unused-config) == warn ]] \
    || fail "guest unused-disk evidence was not reported"
[[ $(result_state volume.local-vm-100-disk-2.ownership-unknown) == warn ]] \
    || fail "ambiguous live-guest volume was not marked unknown"
[[ $(result_state volume.local-vm-999-disk-0.orphan-candidate) == warn ]] \
    || fail "missing-owner volume was not reported as a candidate"
[[ $(result_state content.local-iso-old.iso.stale) == warn ]] \
    || fail "stale ISO was not reported"
[[ $(result_state zfs.tank-data-vm-100-disk-8.ownership-unknown) == warn ]] \
    || fail "ambiguous ZFS volume was not marked unknown"
[[ $(result_state zfs.tank-data-subvol-998-disk-0.orphan-candidate) == warn ]] \
    || fail "missing-owner ZFS dataset was not reported"
[[ $(result_state lvm-thin.pve.data) == fail ]] \
    || fail "LVM thin-pool pressure was not failed"
pass "directory, ZFS, and LVM-thin evidence is reported"

detail=$(jq -rn --argjson ids "$(printf '%s\n' "${REPORT_IDS[@]}" | jq -R . | jq -s .)" '$ids | join(" ")')
[[ $detail != *delete* && $detail != *prune* ]] || fail "audit emitted a cleanup action"
pass "audit remains read-only and proposes no automatic cleanup"

SH_SNAPSHOT_DAYS=0 SH_CONTENT_DAYS=180 SH_CAPACITY_WARN=85 SH_CAPACITY_FAIL=95 \
    SH_THIN_WARN=80 SH_THIN_FAIL=95
_sh_validate && fail "zero snapshot threshold was accepted"
SH_SNAPSHOT_DAYS=30 SH_CAPACITY_WARN=95 SH_CAPACITY_FAIL=85
_sh_validate && fail "reversed capacity thresholds were accepted"
SH_CAPACITY_WARN=85 SH_CAPACITY_FAIL=95 SH_THIN_WARN=95 SH_THIN_FAIL=80
_sh_validate && fail "reversed thin-pool thresholds were accepted"
pass "storage hygiene thresholds fail closed"
