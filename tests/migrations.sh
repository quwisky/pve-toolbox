#!/usr/bin/env bash
# Package-upgrade migration behavior through the installed runner interface.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

run_migrations() {
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/run" \
        "$ROOT/scripts/run-migrations.sh" "$@"
}

mkdir -p "$WORK/migrations"
run_migrations 0.5.0
[[ ! -e $WORK/config && ! -e $WORK/state && ! -e $WORK/backups ]] \
    || fail "an empty upgrade created migration data"
pass "an upgrade with no migrations is a no-op"

mkdir -p "$WORK/fresh-migrations" "$WORK/fresh-config"
printf 'FORMAT=current\n' > "$WORK/fresh-config/current.conf"
cat > "$WORK/fresh-migrations/005-already-current.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.5.0
MIGRATION_FILES=("$PVE_TOOLBOX_CONF_DIR/current.conf")
MIGRATION_UNITS=()
migration_apply() { printf 'FORMAT=incorrect\n' > "$PVE_TOOLBOX_CONF_DIR/current.conf"; }
MIGRATION
chmod 0644 "$WORK/fresh-migrations/005-already-current.sh"
env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/fresh-migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/fresh-config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/fresh-state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/fresh-backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/fresh-run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 >/dev/null
[[ $(<"$WORK/fresh-config/current.conf") == FORMAT=current \
    && ! -e $WORK/fresh-backups ]] \
    || fail "a migration bundled with the installed version ran later"
grep -Fxq 005-already-current "$WORK/fresh-state/migrations.state" \
    || fail "an inapplicable migration was not marked complete"
pass "migrations already included by the previous version are skipped"

mkdir -p "$WORK/config" "$WORK/state"
printf 'FORMAT=old\n' > "$WORK/config/example.conf"
chmod 0600 "$WORK/config/example.conf"
printf 'CACHE=old\n' > "$WORK/state/example.state"
chmod 0644 "$WORK/state/example.state"
cat > "$WORK/migrations/010-example.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=(
    "$PVE_TOOLBOX_CONF_DIR/example.conf"
    "$PVE_TOOLBOX_STATE_DIR/example.state"
)
MIGRATION_UNITS=()
migration_apply() {
    printf 'FORMAT=current\n' > "$PVE_TOOLBOX_CONF_DIR/example.conf"
    printf 'CACHE=current\n' > "$PVE_TOOLBOX_STATE_DIR/example.state"
    printf 'applied\n' >> "$PVE_TOOLBOX_STATE_DIR/example.calls"
}
MIGRATION
chmod 0644 "$WORK/migrations/010-example.sh"

run_migrations 0.5.0
[[ $(<"$WORK/config/example.conf") == FORMAT=current ]] \
    || fail "the pending migration did not update configuration"
[[ $(stat -c '%a' "$WORK/config/example.conf") == 600 ]] \
    || fail "migration changed the operator file mode"
[[ $(<"$WORK/state/example.state") == CACHE=current \
    && $(stat -c '%a' "$WORK/state/example.state") == 644 ]] \
    || fail "the pending migration did not preserve state metadata"
grep -Fxq 010-example "$WORK/state/migrations.state" \
    || fail "successful migration was not recorded"
backup=$(find "$WORK/backups" -path '*/files/*/config/example.conf' -type f -print -quit)
[[ -n $backup && $(<"$backup") == FORMAT=old ]] \
    || fail "the original configuration was not backed up"
[[ $(stat -c '%a' "$backup") == 600 ]] \
    || fail "the backup did not preserve the original mode"
state_backup=$(find "$WORK/backups" -path '*/files/*/state/example.state' \
    -type f -print -quit)
[[ -n $state_backup && $(<"$state_backup") == CACHE=old ]] \
    || fail "the original state was not backed up"

run_migrations 0.5.0
[[ $(grep -c '^applied$' "$WORK/state/example.calls") -eq 1 ]] \
    || fail "a completed migration ran more than once"
pass "successful migrations back up, apply, record, and stay idempotent"

completed_backup=${backup%/files/*}
printf '010-example\t%s\n' "$completed_backup" > "$WORK/state/migration.pending"
run_migrations 0.5.0 >/dev/null
[[ $(<"$WORK/config/example.conf") == FORMAT=current \
    && ! -e $WORK/state/migration.pending ]] \
    || fail "a completed transaction marker rolled back committed configuration"
pass "completed transactions tolerate interruption during finalization"

printf 'VALUE=original\n' > "$WORK/config/failing.conf"
chmod 0640 "$WORK/config/failing.conf"
cat > "$WORK/migrations/020-failing.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=("$PVE_TOOLBOX_CONF_DIR/failing.conf")
MIGRATION_UNITS=()
migration_apply() {
    printf 'VALUE=partial\n' > "$PVE_TOOLBOX_CONF_DIR/failing.conf"
    [[ -f $PVE_TOOLBOX_STATE_DIR/allow-failing-migration ]] || return 1
    printf 'VALUE=current\n' > "$PVE_TOOLBOX_CONF_DIR/failing.conf"
}
MIGRATION
chmod 0644 "$WORK/migrations/020-failing.sh"

output=""
if output=$(run_migrations 0.5.0 2>&1); then
    fail "a failed migration was reported as successful"
fi
[[ $output == *'020-failing'* && $output == *'restored'* ]] \
    || fail "migration failure did not identify the rollback"
[[ $(<"$WORK/config/failing.conf") == VALUE=original ]] \
    || fail "failed migration left partial configuration"
[[ $(stat -c '%a' "$WORK/config/failing.conf") == 640 ]] \
    || fail "rollback changed the original file mode"
if grep -Fxq 020-failing "$WORK/state/migrations.state"; then
    fail "failed migration was recorded as complete"
fi

: > "$WORK/state/allow-failing-migration"
run_migrations 0.5.0
[[ $(<"$WORK/config/failing.conf") == VALUE=current ]] \
    || fail "failed migration could not be retried"
grep -Fxq 020-failing "$WORK/state/migrations.state" \
    || fail "retried migration was not recorded"
pass "failed migrations roll back and can be retried"

printf 'VALUE=before-interruption\n' > "$WORK/config/interrupted.conf"
cat > "$WORK/migrations/030-interrupted.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=("$PVE_TOOLBOX_CONF_DIR/interrupted.conf")
MIGRATION_UNITS=()
migration_apply() {
    if [[ ! -f $PVE_TOOLBOX_STATE_DIR/resume-interrupted ]]; then
        printf 'VALUE=partial-interruption\n' > "$PVE_TOOLBOX_CONF_DIR/interrupted.conf"
        : > "$PVE_TOOLBOX_STATE_DIR/interrupted-ready"
        while true; do sleep 0.1; done
    fi
    cat "$PVE_TOOLBOX_CONF_DIR/interrupted.conf" \
        > "$PVE_TOOLBOX_STATE_DIR/interrupted-observed"
    printf 'VALUE=after-interruption\n' > "$PVE_TOOLBOX_CONF_DIR/interrupted.conf"
}
MIGRATION
chmod 0644 "$WORK/migrations/030-interrupted.sh"

setsid env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 >/dev/null 2>&1 &
migration_pid=$!
for _ in {1..100}; do
    [[ -e $WORK/state/interrupted-ready ]] && break
    sleep 0.05
done
[[ -e $WORK/state/interrupted-ready ]] \
    || { kill "$migration_pid" 2>/dev/null || true; fail "interruption fixture never entered migration"; }
kill -KILL -- "-$migration_pid"
wait "$migration_pid" 2>/dev/null || true
[[ $(<"$WORK/config/interrupted.conf") == VALUE=partial-interruption ]] \
    || fail "interruption did not occur after the partial write"
[[ -f $WORK/state/migration.pending ]] \
    || fail "interrupted migration left no durable recovery record"

: > "$WORK/state/resume-interrupted"
run_migrations 0.5.0
[[ $(<"$WORK/state/interrupted-observed") == VALUE=before-interruption ]] \
    || fail "retry did not restore the backup before applying again"
[[ $(<"$WORK/config/interrupted.conf") == VALUE=after-interruption ]] \
    || fail "interrupted migration did not complete on retry"
[[ ! -e $WORK/state/migration.pending ]] \
    || fail "successful retry retained the pending recovery record"
pass "interrupted migrations restore before retrying"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PVE_TOOLBOX_SYSTEMCTL_LOG"
case $1 in
    is-enabled) [[ ${PVE_TOOLBOX_FAIL_DISABLE:-0} == 1 ]] && exit 1; exit 0 ;;
    is-active) exit 0 ;;
    disable) [[ ${PVE_TOOLBOX_FAIL_DISABLE:-0} == 1 ]] && exit 1; exit 0 ;;
    stop|daemon-reload|enable|start) exit 0 ;;
    *) exit 1 ;;
esac
SYSTEMCTL
chmod 0755 "$WORK/bin/systemctl"
export PVE_TOOLBOX_SYSTEMCTL_LOG="$WORK/systemctl.log"
PATH="$WORK/bin:$PATH"
export PATH

printf 'VALUE=unit-original\n' > "$WORK/config/unit.conf"
cat > "$WORK/migrations/040-unit-failure.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=("$PVE_TOOLBOX_CONF_DIR/unit.conf")
MIGRATION_UNITS=(pve-toolbox-example.timer)
migration_apply() {
    printf 'apply\n' >> "$PVE_TOOLBOX_SYSTEMCTL_LOG"
    printf 'VALUE=unit-partial\n' > "$PVE_TOOLBOX_CONF_DIR/unit.conf"
    return 1
}
MIGRATION
chmod 0644 "$WORK/migrations/040-unit-failure.sh"

if run_migrations 0.5.0 >/dev/null 2>&1; then
    fail "unit migration failure was reported as successful"
fi
[[ $(<"$WORK/config/unit.conf") == VALUE=unit-original ]] \
    || fail "unit migration did not restore configuration"
expected_calls=$'is-enabled --quiet pve-toolbox-example.timer\nis-active --quiet pve-toolbox-example.timer\nstop pve-toolbox-example.timer\napply\ndaemon-reload\nenable pve-toolbox-example.timer\nstart pve-toolbox-example.timer'
[[ $(<"$WORK/systemctl.log") == "$expected_calls" ]] \
    || fail "unit state was not quiesced and restored around rollback"
pass "failed migrations restore declared unit state"

rm -f -- "$WORK/migrations/040-unit-failure.sh"
cat > "$WORK/migrations/045-unit-success.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=("$PVE_TOOLBOX_CONF_DIR/unit.conf")
MIGRATION_UNITS=(pve-toolbox-example.timer)
migration_apply() {
    printf 'apply\n' >> "$PVE_TOOLBOX_SYSTEMCTL_LOG"
    printf 'VALUE=unit-current\n' > "$PVE_TOOLBOX_CONF_DIR/unit.conf"
}
MIGRATION
chmod 0644 "$WORK/migrations/045-unit-success.sh"
: > "$WORK/systemctl.log"
run_migrations 0.5.0 >/dev/null
[[ $(<"$WORK/config/unit.conf") == VALUE=unit-current ]] \
    || fail "successful unit migration did not retain configuration"
[[ $(<"$WORK/systemctl.log") == "$expected_calls" ]] \
    || fail "unit state was not restored after a successful migration"
pass "successful migrations restore declared unit state"

rm -f -- "$WORK/migrations/045-unit-success.sh"
printf 'VALUE=restore-original\n' > "$WORK/config/restore-unit.conf"
cat > "$WORK/migrations/047-unit-restore-failure.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=("$PVE_TOOLBOX_CONF_DIR/restore-unit.conf")
MIGRATION_UNITS=(pve-toolbox-disabled.timer)
migration_apply() {
    printf 'VALUE=restore-partial\n' > "$PVE_TOOLBOX_CONF_DIR/restore-unit.conf"
}
MIGRATION
chmod 0644 "$WORK/migrations/047-unit-restore-failure.sh"
export PVE_TOOLBOX_FAIL_DISABLE=1
if run_migrations 0.5.0 >/dev/null 2>&1; then
    fail "a unit restoration failure was reported as successful"
fi
unset PVE_TOOLBOX_FAIL_DISABLE
[[ $(<"$WORK/config/restore-unit.conf") == VALUE=restore-original ]] \
    || fail "unit restoration failure did not restore configuration"
pass "unit restoration failures stop and roll back migration"

rm -f -- "$WORK/migrations/047-unit-restore-failure.sh"
cat > "$WORK/migrations/050-lock.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=()
MIGRATION_UNITS=()
migration_apply() {
    : > "$PVE_TOOLBOX_STATE_DIR/lock-ready"
    while [[ ! -f $PVE_TOOLBOX_STATE_DIR/release-lock ]]; do sleep 0.05; done
}
MIGRATION
chmod 0644 "$WORK/migrations/050-lock.sh"

env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 >/dev/null 2>&1 &
locking_pid=$!
for _ in {1..100}; do
    [[ -e $WORK/state/lock-ready ]] && break
    sleep 0.05
done
[[ -e $WORK/state/lock-ready ]] \
    || { kill "$locking_pid" 2>/dev/null || true; fail "locking fixture never entered migration"; }
mkdir -p "$WORK/second-migrations"
cat > "$WORK/second-migrations/001-noop.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=()
MIGRATION_UNITS=()
migration_apply() { :; }
MIGRATION
chmod 0644 "$WORK/second-migrations/001-noop.sh"
lock_output=""
lock_rc=0
lock_output=$(env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/second-migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/second-config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/second-state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/second-backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 2>&1) || lock_rc=$?
: > "$WORK/state/release-lock"
wait "$locking_pid"
[[ $lock_rc -ne 0 ]] || fail "a concurrent migration runner acquired the same transaction"
[[ $lock_output == *'migration run is already active'* ]] \
    || fail "concurrent migration failure was not actionable"
pass "concurrent migration runners are rejected"

mkdir -p "$WORK/order-migrations"
cat > "$WORK/order-migrations/070-later.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=()
MIGRATION_UNITS=()
migration_apply() { printf 'later\n' >> "$PVE_TOOLBOX_STATE_DIR/order"; }
MIGRATION
cat > "$WORK/order-migrations/060-earlier.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=()
MIGRATION_UNITS=()
migration_apply() { printf 'earlier\n' >> "$PVE_TOOLBOX_STATE_DIR/order"; }
MIGRATION
chmod 0644 "$WORK/order-migrations/"*.sh
env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/order-migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/order-config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/order-state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/order-backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/order-run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 >/dev/null
[[ $(<"$WORK/order-state/order") == $'earlier\nlater' ]] \
    || fail "migrations did not run in filename order"
pass "pending migrations run in filename order"

mkdir -p "$WORK/unsafe-migrations"
cat > "$WORK/unsafe-migrations/080-writable.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=()
MIGRATION_UNITS=()
migration_apply() { : > "$PVE_TOOLBOX_STATE_DIR/unsafe-applied"; }
MIGRATION
chmod 0664 "$WORK/unsafe-migrations/080-writable.sh"
unsafe_output=""
unsafe_rc=0
unsafe_output=$(env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/unsafe-migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/unsafe-config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/unsafe-state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/unsafe-backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/unsafe-run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 2>&1) || unsafe_rc=$?
[[ $unsafe_rc -ne 0 && $unsafe_output == *'group/world writable'* ]] \
    || fail "a group-writable migration was accepted"
[[ ! -e $WORK/unsafe-state/unsafe-applied ]] \
    || fail "an unsafe migration was executed"
pass "writable migration fragments are rejected"

chmod 0644 "$WORK/unsafe-migrations/080-writable.sh"
mkdir -p "$WORK/unsafe-backup-target"
chmod 0755 "$WORK/unsafe-backup-target"
ln -s "$WORK/unsafe-backup-target" "$WORK/unsafe-backups"
unsafe_output=""
unsafe_rc=0
unsafe_output=$(env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/unsafe-migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/unsafe-config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/unsafe-state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/unsafe-backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/unsafe-run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 2>&1) || unsafe_rc=$?
[[ $unsafe_rc -ne 0 && $unsafe_output == *'unsafe directory'* ]] \
    || fail "a symlinked backup directory was accepted"
[[ $(stat -c '%a' "$WORK/unsafe-backup-target") == 755 ]] \
    || fail "an unsafe backup target was mutated"
pass "unsafe transaction directories are rejected"

mkdir -p "$WORK/result-migrations" "$WORK/result-config"
printf 'outside\n' > "$WORK/outside-result"
cat > "$WORK/result-migrations/090-unsafe-result.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=("$PVE_TOOLBOX_CONF_DIR/result.conf")
MIGRATION_UNITS=()
migration_apply() { ln -s "$WORK/outside-result" "$PVE_TOOLBOX_CONF_DIR/result.conf"; }
MIGRATION
chmod 0644 "$WORK/result-migrations/090-unsafe-result.sh"
result_output=""
result_rc=0
result_output=$(env \
    WORK="$WORK" \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/result-migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/result-config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/result-state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/result-backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/result-run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 2>&1) || result_rc=$?
[[ $result_rc -ne 0 && $result_output == *'unsafe migration result'* \
    && ! -e $WORK/result-config/result.conf ]] \
    || fail "an unsafe migration result was accepted or not rolled back"
pass "unsafe migration results are rejected and rolled back"

mkdir -p "$WORK/real-migration-parent/migrations"
cat > "$WORK/real-migration-parent/migrations/100-symlinked-directory.sh" <<'MIGRATION'
MIGRATION_TARGET_VERSION=0.6.0
MIGRATION_FILES=()
MIGRATION_UNITS=()
migration_apply() { : > "$PVE_TOOLBOX_STATE_DIR/symlinked-dir-applied"; }
MIGRATION
chmod 0644 "$WORK/real-migration-parent/migrations/100-symlinked-directory.sh"
ln -s "$WORK/real-migration-parent" "$WORK/symlinked-migration-parent"
directory_output=""
directory_rc=0
directory_output=$(env \
    PVE_TOOLBOX_MIGRATION_DIR="$WORK/symlinked-migration-parent/migrations" \
    PVE_TOOLBOX_CONF_DIR="$WORK/directory-config" \
    PVE_TOOLBOX_STATE_DIR="$WORK/directory-state" \
    PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$WORK/directory-backups" \
    PVE_TOOLBOX_RUN_DIR="$WORK/directory-run" \
    "$ROOT/scripts/run-migrations.sh" 0.5.0 2>&1) || directory_rc=$?
[[ $directory_rc -ne 0 && $directory_output == *'unsafe migration directory'* \
    && ! -e $WORK/directory-state/symlinked-dir-applied ]] \
    || fail "a migration directory with a symlinked ancestor was accepted"
pass "symlinked migration directory paths are rejected"
