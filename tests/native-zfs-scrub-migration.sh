#!/usr/bin/env bash
# Upgrade fixtures for moving toolbox scrub schedules to native ZFS timers.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

write_fake_systemctl() {
    local bin=$1
    cat > "$bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
set -euo pipefail
root=$PVE_TOOLBOX_SYSTEMCTL_ROOT
action=${1:-}
shift || true
printf '%s' "$action" >> "$PVE_TOOLBOX_SYSTEMCTL_LOG"
printf '\t%s' "$@" >> "$PVE_TOOLBOX_SYSTEMCTL_LOG"
printf '\n' >> "$PVE_TOOLBOX_SYSTEMCTL_LOG"
unit=${*: -1}
case $action in
    cat)
        [[ -f $root/templates/$unit ]]
        ;;
    is-enabled)
        if [[ -f $root/enabled/$unit ]]; then
            [[ ${1:-} == --quiet ]] || printf 'enabled\n'
            exit 0
        fi
        [[ ${1:-} == --quiet ]] || printf 'disabled\n'
        exit 1
        ;;
    is-active)
        [[ -f $root/active/$unit ]]
        ;;
    enable)
        [[ ${PVE_TOOLBOX_FAIL_ENABLE_UNIT:-} != "$unit" ]] || exit 5
        : > "$root/enabled/$unit"
        ;;
    disable)
        [[ ${PVE_TOOLBOX_FAIL_DISABLE_UNIT:-} != "$unit" ]] || exit 6
        rm -f -- "$root/enabled/$unit"
        [[ " $* " != *' --now '* ]] || rm -f -- "$root/active/$unit"
        ;;
    start)
        [[ ${PVE_TOOLBOX_FAIL_START_UNIT:-} != "$unit" ]] || exit 7
        : > "$root/active/$unit"
        ;;
    stop)
        rm -f -- "$root/active/$unit"
        ;;
    daemon-reload) : ;;
    *) exit 64 ;;
esac
SYSTEMCTL
    chmod 0755 "$bin/systemctl"
    cat > "$bin/systemd-analyze" <<'ANALYZE'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == calendar && -n ${2:-} && $2 != invalid ]]
ANALYZE
    chmod 0755 "$bin/systemd-analyze"
}

setup_case() { # setup_case <dir> <pool|schedule|active>...
    local case_dir=$1 fixture pool schedule active pools=""
    shift
    mkdir -p "$case_dir"/{bin,config,state,systemd,migrations,backups,run} \
        "$case_dir/systemctl"/{enabled,active,templates}
    cp -- "$ROOT/migrations/020-native-zfs-scrub-schedules.sh" \
        "$case_dir/migrations/"
    chmod 0644 "$case_dir/migrations/020-native-zfs-scrub-schedules.sh"
    write_fake_systemctl "$case_dir/bin"
    : > "$case_dir/systemctl/templates/zfs-scrub@.service"
    : > "$case_dir/systemctl/templates/zfs-scrub-weekly@.timer"
    printf 'DISCORD_WEBHOOK=%q\n' 'https://discord.com/api/webhooks/id/token' \
        > "$case_dir/config/zfs-scrub.conf"
    chmod 0600 "$case_dir/config/zfs-scrub.conf"
    for fixture in "$@"; do
        pool=${fixture%%|*}
        active=${fixture##*|}
        schedule=${fixture#*|}
        schedule=${schedule%|*}
        pools+="${pools:+ }$pool"
        cat > "$case_dir/systemd/pve-toolbox-zfs-scrub@$pool.timer" <<EOF
[Timer]
OnCalendar=$schedule
RandomizedDelaySec=1800
Persistent=true
Unit=pve-toolbox-zfs-scrub@$pool.service
EOF
        chmod 0644 "$case_dir/systemd/pve-toolbox-zfs-scrub@$pool.timer"
        : > "$case_dir/systemctl/enabled/pve-toolbox-zfs-scrub@$pool.timer"
        if [[ $active == active ]]; then
            : > "$case_dir/systemctl/active/pve-toolbox-zfs-scrub@$pool.timer"
        fi
    done
    {
        printf 'POOLS=%q\n' "$pools"
        printf 'INTERVAL=300\nNOTIFY_START=y\n'
    } > "$case_dir/state/zfs-scrub.state"
    chmod 0644 "$case_dir/state/zfs-scrub.state"
}

run_case() { # run_case <dir> [environment assignments...]
    local case_dir=$1
    shift
    env \
        PATH="$case_dir/bin:$PATH" \
        PVE_TOOLBOX_MIGRATION_DIR="$case_dir/migrations" \
        PVE_TOOLBOX_CONF_DIR="$case_dir/config" \
        PVE_TOOLBOX_STATE_DIR="$case_dir/state" \
        PVE_TOOLBOX_SYSTEMD_DIR="$case_dir/systemd" \
        PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$case_dir/backups" \
        PVE_TOOLBOX_RUN_DIR="$case_dir/run" \
        PVE_TOOLBOX_SYSTEMCTL_ROOT="$case_dir/systemctl" \
        PVE_TOOLBOX_SYSTEMCTL_LOG="$case_dir/systemctl.log" \
        "$@" "$ROOT/scripts/run-migrations.sh" 0.6.0
}

assert_enabled() { [[ -f $1/systemctl/enabled/$2 ]]; }
assert_disabled() { [[ ! -e $1/systemctl/enabled/$2 ]]; }
assert_active() { [[ -f $1/systemctl/active/$2 ]]; }
assert_inactive() { [[ ! -e $1/systemctl/active/$2 ]]; }

success="$WORK/success"
setup_case "$success" \
    'tank|Sun *-*-01..07 03:00:00|active' \
    'backup|Mon *-*-15..21 04:30:00|inactive'
tank_before=$(sha256sum "$success/systemd/pve-toolbox-zfs-scrub@tank.timer")
backup_before=$(sha256sum "$success/systemd/pve-toolbox-zfs-scrub@backup.timer")
run_case "$success" >/dev/null || fail "multi-pool native timer migration failed"
for fixture in \
    'tank|Sun *-*-01..07 03:00:00' \
    'backup|Mon *-*-15..21 04:30:00'; do
    pool=${fixture%%|*}
    schedule=${fixture#*|}
    override="$success/systemd/zfs-scrub-weekly@$pool.timer.d/override.conf"
    grep -Fxq "OnCalendar=$schedule" "$override" \
        || fail "native timer lost the exact $pool schedule"
    [[ $(grep -c '^OnCalendar=' "$override") -eq 2 \
        && $(sed -n '2p' "$override") == OnCalendar= \
        && $(sed -n '4p' "$override") == RandomizedDelaySec=1800 ]] \
        || fail "native timer override for $pool is incomplete"
    assert_enabled "$success" "zfs-scrub-weekly@$pool.timer" \
        || fail "native timer for $pool is not enabled"
    assert_inactive "$success" "zfs-scrub-weekly@$pool.timer" \
        || fail "migration started native timer for $pool"
    assert_disabled "$success" "zfs-scrub-monthly@$pool.timer" \
        || fail "monthly duplicate remains enabled for $pool"
    assert_disabled "$success" "pve-toolbox-zfs-scrub@$pool.timer" \
        || fail "legacy duplicate remains enabled for $pool"
done
[[ $(sha256sum "$success/systemd/pve-toolbox-zfs-scrub@tank.timer") == "$tank_before" \
    && $(sha256sum "$success/systemd/pve-toolbox-zfs-scrub@backup.timer") == "$backup_before" ]] \
    || fail "migration rewrote the legacy timer files"
grep -Fxq SCHEDULE_OWNER=native "$success/state/zfs-scrub.state" \
    || fail "migration did not record native schedule ownership"
grep -Fxq 020-native-zfs-scrub-schedules "$success/state/migrations.state" \
    || fail "migration was not recorded"
if grep -E $'^(start|enable)\t.*--now|^(start|stop)\t.*\.service' \
    "$success/systemctl.log" >/dev/null; then
    fail "migration could start or interrupt a pool scrub"
fi
native_line=$(grep -n $'^enable\tzfs-scrub-weekly@tank.timer$' \
    "$success/systemctl.log" | head -n1 | cut -d: -f1)
old_line=$(grep -n $'^disable\tpve-toolbox-zfs-scrub@tank.timer$' \
    "$success/systemctl.log" | head -n1 | cut -d: -f1)
[[ $native_line -lt $old_line ]] \
    || fail "legacy timer was disabled before the native timer was verified"
log_lines=$(wc -l < "$success/systemctl.log")
run_case "$success" >/dev/null || fail "repeat migration failed"
[[ $(wc -l < "$success/systemctl.log") -eq $log_lines ]] \
    || fail "completed migration changed timer state again"
pass "multiple pools preserve exact schedules without starting a scrub"
pass "completed native timer migration is idempotent"

conflict="$WORK/conflict"
setup_case "$conflict" 'tank|weekly|active'
: > "$conflict/systemctl/enabled/zfs-scrub-weekly@tank.timer"
conflict_state=$(sha256sum "$conflict/state/zfs-scrub.state")
conflict_output=""
conflict_rc=0
conflict_output=$(run_case "$conflict" 2>&1) || conflict_rc=$?
[[ $conflict_rc -ne 0 && $conflict_output == *'already enabled'* \
    && $(sha256sum "$conflict/state/zfs-scrub.state") == "$conflict_state" \
    && ! -e $conflict/systemd/zfs-scrub-weekly@tank.timer.d ]] \
    || fail "pre-existing native timer conflict changed the schedule"
assert_enabled "$conflict" pve-toolbox-zfs-scrub@tank.timer \
    || fail "conflict disabled the legacy timer"
assert_active "$conflict" pve-toolbox-zfs-scrub@tank.timer \
    || fail "conflict stopped the legacy timer"
pass "pre-existing native scheduling fails before timer changes"

missing="$WORK/missing"
setup_case "$missing" 'tank|weekly|inactive'
rm -- "$missing/systemctl/templates/zfs-scrub@.service"
missing_output=""
missing_rc=0
missing_output=$(run_case "$missing" 2>&1) || missing_rc=$?
[[ $missing_rc -ne 0 && $missing_output == *'service and weekly timer are required'* \
    && ! -e $missing/systemd/zfs-scrub-weekly@tank.timer.d ]] \
    || fail "missing native units did not stop before changes"
pass "native service and timer presence is required"

rollback="$WORK/rollback"
setup_case "$rollback" \
    'tank|Sun *-*-01..07 03:00:00|active' \
    'backup|Mon *-*-15..21 04:30:00|inactive'
rollback_state=$(sha256sum "$rollback/state/zfs-scrub.state")
rollback_output=""
rollback_rc=0
rollback_output=$(run_case "$rollback" \
    PVE_TOOLBOX_FAIL_DISABLE_UNIT=pve-toolbox-zfs-scrub@backup.timer \
    2>&1) || rollback_rc=$?
[[ $rollback_rc -ne 0 && $rollback_output == *'disable legacy scrub timer'* \
    && $rollback_output == *'restored files'* ]] \
    || fail "timer switch failure did not report rollback"
[[ $(sha256sum "$rollback/state/zfs-scrub.state") == "$rollback_state" \
    && ! -e $rollback/state/migrations.state ]] \
    || fail "timer switch failure changed or recorded legacy state"
for pool in tank backup; do
    assert_enabled "$rollback" "pve-toolbox-zfs-scrub@$pool.timer" \
        || fail "rollback did not re-enable legacy timer for $pool"
    assert_disabled "$rollback" "zfs-scrub-weekly@$pool.timer" \
        || fail "rollback retained native timer for $pool"
    [[ ! -e $rollback/systemd/zfs-scrub-weekly@$pool.timer.d ]] \
        || fail "rollback retained native override for $pool"
done
assert_active "$rollback" pve-toolbox-zfs-scrub@tank.timer \
    || fail "rollback did not restart the previously active timer"
assert_inactive "$rollback" pve-toolbox-zfs-scrub@backup.timer \
    || fail "rollback started the previously inactive timer"
backup_state=$(find "$rollback/backups" \
    -path '*/files/*/zfs-scrub.state' -type f -print -quit)
[[ -n $backup_state \
    && $(sha256sum "$backup_state" | awk '{print $1}') == "${rollback_state%% *}" ]] \
    || fail "rollback did not retain the original configuration backup"
pass "timer switch failures restore files and exact enabled state"
