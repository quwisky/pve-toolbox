#!/usr/bin/env bash
# Unit and launcher tests for the read-only doctor framework.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"

state_for() { # state_for <id>
    local wanted=$1 i
    for ((i = 0; i < ${#DOCTOR_IDS[@]}; i++)); do
        [[ ${DOCTOR_IDS[$i]} == "$wanted" ]] && { printf '%s' "${DOCTOR_STATES[$i]}"; return; }
    done
}

# Results have a deliberately narrow protocol because module checks execute in
# isolated subshells. Control characters must not let one result forge another.
doctor_reset
doctor_result pass host.example $'healthy\tservice' $'line one\nline two'
[[ ${DOCTOR_SUMMARIES[0]} == "healthy service" ]] \
    || fail "doctor result retained a tab"
[[ ${DOCTOR_DETAILS[0]} == "line one; line two" ]] \
    || fail "doctor result retained a newline"
doctor_result bogus bad.id nope >/dev/null 2>&1 \
    && fail "doctor accepted an unknown state"
doctor_result pass 'bad id' nope >/dev/null 2>&1 \
    && fail "doctor accepted an unsafe id"
pass "doctor result protocol is validated"

doctor_reset
record=$(DOCTOR_EMIT=1 DOCTOR_PREFIX=module.example. \
    doctor_result warn endpoint "endpoint is slow" "900 ms")
doctor_import_module example 0 "$record"
[[ ${DOCTOR_IDS[0]} == module.example.endpoint && ${DOCTOR_STATES[0]} == warn ]] \
    || fail "valid isolated module result was not imported"
doctor_import_module broken 0 "unexpected module output"
[[ $(state_for module.broken.protocol) == fail ]] \
    || fail "invalid module output was not rejected"
pass "isolated module results fail closed"

# Healthy core fixture. Command functions override host tools, and path knobs
# keep the test independent of whether the runner is a PVE node.
healthy_etc="$WORK/healthy-etc"
mkdir -p "$healthy_etc"
: > "$healthy_etc/corosync.conf"
PVE_TOOLBOX_PVE_ETC=$healthy_etc
PVE_TOOLBOX_REBOOT_FILE="$WORK/no-reboot-required"
pvecm() { printf 'Quorate: Yes\n'; }
systemctl() { :; }
zpool() { printf 'rpool\tONLINE\ntank\tONLINE\n'; }
pvesm() {
    printf 'Name Type Status Total Used Available %%\n'
    printf 'local dir active 100 20 80 20.00%%\n'
}
PVE_NODES_JSON='[{"node":"pve1"}]'
PVE1_TASKS_JSON='[]'
PVE2_TASKS_JSON='[]'
pvesh() {
    local action=${1:-} endpoint=${2:-}
    shift 2
    [[ $action == get ]] || { printf 'unexpected pvesh action: %s\n' "$action" >&2; return 64; }
    case $endpoint in
        /nodes)
            [[ $* == '--output-format json' ]] \
                || { printf 'unexpected node query: %s\n' "$*" >&2; return 64; }
            printf '%s\n' "$PVE_NODES_JSON"
            ;;
        /nodes/pve1/tasks|/nodes/pve2/tasks)
            [[ $* =~ ^--errors\ 1\ --since\ [0-9]+\ --limit\ 50\ --output-format\ json$ ]] \
                || { printf 'unexpected task query: %s\n' "$*" >&2; return 64; }
            if [[ $endpoint == /nodes/pve1/tasks ]]; then
                printf '%s\n' "$PVE1_TASKS_JSON"
            else
                printf '%s\n' "$PVE2_TASKS_JSON"
            fi
            ;;
        *)
            printf 'unexpected pvesh endpoint: %s\n' "$endpoint" >&2
            return 64
            ;;
    esac
}

doctor_reset
doctor_run_core
[[ ${#DOCTOR_STATES[@]} -eq 6 ]] || fail "core doctor did not return six checks"
for state in "${DOCTOR_STATES[@]}"; do
    [[ $state == pass ]] || fail "healthy core fixture reported $state"
done
doctor_render >/dev/null || fail "healthy doctor report exited nonzero"
pass "healthy core checks pass"

# PVE 9 exposes the historical task filters on each node's task endpoint, not
# on /cluster/tasks. Query every node so a failure on a peer is still visible.
PVE_NODES_JSON='[{"node":"pve1"},{"node":"pve2"}]'
PVE1_TASKS_JSON='[{"node":"pve1","type":"vzdump","status":"backup failed"}]'
PVE2_TASKS_JSON='[{"node":"pve2","type":"qmstart","status":"start failed"}]'
doctor_reset
doctor_check_tasks
[[ ${DOCTOR_STATES[0]} == warn \
    && ${DOCTOR_SUMMARIES[0]} == '2 failed Proxmox task(s) in the last 24 hours' ]] \
    || fail "cluster-wide node task failures were not reported"
[[ ${DOCTOR_DETAILS[0]} == *'pve1:vzdump backup failed'* \
    && ${DOCTOR_DETAILS[0]} == *'pve2:qmstart start failed'* ]] \
    || fail "cluster-wide task detail omitted a node"
pass "doctor queries supported per-node task history"

# Disabled storage is intentionally unavailable and has no capacity to audit.
# Keep it visible as detail without making healthy enabled storage fail.
pvesm() {
    printf 'Name Type Status Total Used Available %%\n'
    printf 'local dir active 100 20 80 20.00%%\n'
    printf 'local-lvm lvmthin disabled 0 0 0 N/A\n'
}
doctor_reset
doctor_check_storage
[[ ${DOCTOR_STATES[0]} == pass ]] || fail "disabled storage caused a capacity failure"
[[ ${DOCTOR_DETAILS[0]} == 'disabled: local-lvm' ]] \
    || fail "disabled storage was not retained as informational detail"
pass "doctor ignores intentionally disabled storage capacity"

# Failure and warning fixtures exercise each negative branch without touching
# the host. Historical task failures are warnings; loss of quorum, failed
# units, unhealthy pools, or unavailable storage are failures.
touch "$PVE_TOOLBOX_REBOOT_FILE"
pvecm() { printf 'Quorate: No\n'; }
systemctl() { printf 'broken.service loaded failed failed broken\n'; }
zpool() { printf 'rpool\tDEGRADED\n'; }
pvesm() {
    printf 'Name Type Status Total Used Available %%\n'
    printf 'local dir active 100 90 10 90.00%%\n'
    printf 'archive dir inactive 100 0 100 0.00%%\n'
}
PVE_NODES_JSON='[{"node":"pve1"}]'
PVE1_TASKS_JSON='[{"node":"pve1","type":"vzdump","status":"backup failed"}]'

doctor_reset
doctor_run_core
[[ $(state_for cluster.quorum) == fail ]] || fail "lost quorum was not a failure"
[[ $(state_for systemd.failed) == fail ]] || fail "failed unit was not a failure"
[[ $(state_for zfs.pools) == fail ]] || fail "degraded pool was not a failure"
[[ $(state_for storage.capacity) == fail ]] || fail "inactive storage was not a failure"
[[ $(state_for pve.tasks) == warn ]] || fail "failed task was not a warning"
[[ $(state_for host.reboot) == warn ]] || fail "pending reboot was not a warning"
if doctor_render >/dev/null; then
    fail "failed doctor report exited zero"
else
    [[ $? -eq 1 ]] || fail "failed doctor report used the wrong exit status"
fi
doctor_reset
doctor_result warn example.warning "warning"
if doctor_render >/dev/null; then
    fail "warning doctor report exited zero"
else
    [[ $? -eq 2 ]] || fail "warning doctor report used the wrong exit status"
fi
pass "doctor distinguishes warnings from failures"

# Drive the public command with a packaged-layout fixture. The installed
# module contributes a health result through the isolated module protocol.
fixture="$WORK/fixture"
fake_bin="$WORK/bin"
mkdir -p "$fixture/lib" "$fixture/modules/example" "$fake_bin" "$WORK/empty-pve"
cp "$ROOT/lib/common.sh" "$ROOT/lib/discord.sh" "$ROOT/lib/doctor.sh" "$fixture/lib/"
cp "$ROOT/pve-toolbox" "$fixture/pve-toolbox"
printf '0.2.1\n' > "$fixture/VERSION"
printf '%s\n' \
    'MODULE_NAME="example"' \
    'MODULE_TITLE="Example"' \
    'MODULE_DESC="doctor fixture"' \
    'MODULE_TAGS="test"' \
    'MODULE_HOST_ONLY=0' \
    'module_status() { printf installed; }' \
    'module_doctor() { doctor_result pass health "fixture is healthy"; }' \
    > "$fixture/modules/example/module.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/systemctl"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/zpool"
printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'Name Type Status Total Used Available %%\\nlocal dir active 100 20 80 20.00%%%%\\n'" \
    > "$fake_bin/pvesm"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case ${2:-} in' \
    '    /nodes) printf '\''[{"node":"pve1"}]\n'\'' ;;' \
    '    /nodes/pve1/tasks) printf '\''[]\n'\'' ;;' \
    '    *) exit 64 ;;' \
    'esac' \
    > "$fake_bin/pvesh"
chmod 0755 "$fake_bin"/* "$fixture/pve-toolbox"

output=$(PATH="$fake_bin:$PATH" PVE_TOOLBOX_ROOT="$fixture" \
    PVE_TOOLBOX_PVE_ETC="$WORK/empty-pve" \
    PVE_TOOLBOX_REBOOT_FILE="$WORK/no-reboot" \
    "$fixture/pve-toolbox" doctor) || fail "healthy public doctor command failed"
[[ $output == *"module.example.status"* && $output == *"module.example.health"* ]] \
    || fail "public doctor command omitted module checks"
PVE_TOOLBOX_ROOT="$fixture" "$fixture/pve-toolbox" doctor extra >/dev/null 2>&1 \
    && fail "doctor accepted an argument"
pass "public doctor command imports installed module checks"
