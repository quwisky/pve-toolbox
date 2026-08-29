#!/usr/bin/env bash
# Destructive-boundary fixtures for the isolated restore drill helper.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/mock" "$WORK/state" "$WORK/conf" "$WORK/lock"
cp -- "$ROOT/tests/fixtures/restore-drill-mock.sh" "$WORK/bin/mock"
chmod 0755 "$WORK/bin/mock"
for name in qm pct qmrestore; do ln -s mock "$WORK/bin/$name"; done

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

HELPER="$ROOT/modules/restore-drill/pve-toolbox-restore-drill"
MOCK_STATE="$WORK/mock"
MOCK_LOG="$WORK/mock.log"
RD_CONF="$WORK/conf/restore-drill.conf"
RD_RUN_STATE="$WORK/state/run.state"
RD_LAST_REPORT="$WORK/state/last.state"
RD_LOCK="$WORK/lock/drill.lock"
RD_NODE=pve1
PATH="$WORK/bin:$PATH"
export MOCK_STATE MOCK_LOG RD_CONF RD_RUN_STATE RD_LAST_REPORT RD_LOCK RD_NODE PATH
printf '%s\n' "RD_STORAGE='test-store'" "RD_VMID_START='900000'" \
    "RD_BOOT_PROBE='1'" "RD_BOOT_TIMEOUT='1'" "RD_ALLOW_UNATTENDED='1'" > "$RD_CONF"

backup='local:backup/vzdump-qemu-100-2026_08_29-01_00_00.vma.zst'
: > "$MOCK_LOG"
: > "$MOCK_STATE/900000.exists"
printf 'stopped' > "$MOCK_STATE/900000.status"
output=$($HELPER --backup "$backup")
[[ $output == *'VMID=900001'* && $output == *'Dry run only'* ]] \
    || fail "default invocation did not show the collision-free plan"
[[ ! -e $RD_RUN_STATE && $(<"$MOCK_LOG") != *qmrestore* ]] \
    || fail "dry run changed restore state"
pass "default invocation is a collision-aware dry run"

if $HELPER --backup "$backup" --vmid 900000 --execute --unattended >/dev/null 2>&1; then
    fail "explicit VMID collision was accepted"
fi
pass "existing guest VMIDs cannot be overwritten"

: > "$MOCK_LOG"
export MOCK_RESTORE_FAIL=1
if $HELPER --backup "$backup" --vmid 900002 --execute --unattended >/dev/null 2>&1; then
    fail "restore failure returned success"
fi
unset MOCK_RESTORE_FAIL
grep -q '^PHASE=restore-failed$' "$RD_RUN_STATE" || fail "restore failure state was not retained"
[[ $(<"$MOCK_LOG") != *'qm destroy 900002'* ]] || fail "failed restore triggered deletion"
rm -f -- "$RD_RUN_STATE"
pass "restore failures preserve recoverable state without inferred deletion"

: > "$MOCK_LOG"
export MOCK_CONFIG_FAIL=1
if $HELPER --backup "$backup" --vmid 900002 --execute --unattended >/dev/null 2>&1; then
    fail "failed isolation inspection returned success"
fi
unset MOCK_CONFIG_FAIL
grep -q '^PHASE=isolation-failed$' "$RD_RUN_STATE" || fail "isolation failure state was not retained"
[[ -f $MOCK_STATE/900002.exists && $(<"$MOCK_LOG") != *'qm destroy 900002'* ]] \
    || fail "unproven partial restore was deleted"
rm -f -- "$RD_RUN_STATE" "$MOCK_STATE/900002.exists" "$MOCK_STATE/900002.status" \
    "$MOCK_STATE/900002.marker"
pass "configuration inspection failures stop before ownership is asserted"

: > "$MOCK_LOG"
export MOCK_PROBE_FAIL=1
if $HELPER --backup "$backup" --vmid 900003 --execute --unattended >/dev/null 2>&1; then
    fail "failed boot probe returned success"
fi
unset MOCK_PROBE_FAIL
grep -q '^PHASE=probe-failed$' "$RD_RUN_STATE" || fail "probe failure state was not retained"
[[ -f $MOCK_STATE/900003.exists && $(<"$MOCK_LOG") != *'qm destroy 900003'* ]] \
    || fail "failed probe was not preserved"
grep -Eq '^qm set 900003 --net0 .*link_down=1' "$MOCK_LOG" \
    || fail "restored VM networking was not disabled"
grep -Eq '^qm set 900003 --scsi0 .*backup=0' "$MOCK_LOG" \
    || fail "restored VM disks were not excluded from scheduled backups"
grep -q '^qmrestore .* 900003 --storage test-store --unique 1$' "$MOCK_LOG" \
    || fail "restore did not use collision-safe unique mode and target storage"
pass "failed probes preserve an isolated, ownership-marked guest"

export MOCK_DESTROY_FAIL=1
if $HELPER --cleanup --unattended >/dev/null 2>&1; then fail "failed cleanup returned success"; fi
unset MOCK_DESTROY_FAIL
grep -q '^PHASE=cleanup-failed$' "$RD_RUN_STATE" || fail "interrupted cleanup state was not recoverable"
$HELPER --cleanup --unattended >/dev/null
[[ ! -e $RD_RUN_STATE && ! -e $MOCK_STATE/900003.exists ]] \
    || fail "cleanup retry did not safely complete"
grep -q '^CLEANUP=success$' "$RD_LAST_REPORT" || fail "cleanup result was not recorded"
pass "interrupted cleanup resumes only for the marked drill guest"

: > "$MOCK_LOG"
$HELPER --backup "$backup" --vmid 900004 --execute --unattended >/dev/null
[[ ! -e $RD_RUN_STATE && ! -e $MOCK_STATE/900004.exists ]] \
    || fail "successful drill did not tear down"
grep -q "^BACKUP=$backup$" "$RD_LAST_REPORT" || fail "exact backup was not recorded"
grep -q '^PROBE=passed$' "$RD_LAST_REPORT" || fail "probe result was not recorded"
grep -Eq '^DURATION_SECONDS=[0-9]+$' "$RD_LAST_REPORT" || fail "duration was not recorded"
grep -q '^qm destroy 900004 --purge 1 --destroy-unreferenced-disks 1$' "$MOCK_LOG" \
    || fail "successful teardown did not use the guarded destroy path"
pass "successful drill records evidence and tears down the temporary guest"

: > "$MOCK_LOG"
ct_backup='local:backup/vzdump-lxc-101-2026_08_29-01_00_00.tar.zst'
$HELPER --backup "$ct_backup" --vmid 900005 --execute --unattended >/dev/null
grep -q '^pct set 900005 --delete net0$' "$MOCK_LOG" \
    || fail "restored container networking was not removed"
grep -Eq '^pct set 900005 --rootfs .*backup=0' "$MOCK_LOG" \
    || fail "restored container rootfs was not excluded from scheduled backups"
grep -q '^pct destroy 900005 --purge 1$' "$MOCK_LOG" \
    || fail "container teardown did not use the guarded destroy path"
pass "container drills apply the same isolation and teardown boundary"

# A valid state with a different marker must never authorize deletion.
sed 's/^VMID=.*/VMID=900000/; s/^RUN_ID=.*/RUN_ID=foreign-run/; s/^PHASE=.*/PHASE=probe-passed/' \
    "$RD_LAST_REPORT" > "$RD_RUN_STATE"
if $HELPER --cleanup --unattended >/dev/null 2>&1; then fail "foreign guest marker was accepted"; fi
[[ -f $MOCK_STATE/900000.exists ]] || fail "foreign guest was deleted"
pass "cleanup fails closed when ownership proof does not match"
