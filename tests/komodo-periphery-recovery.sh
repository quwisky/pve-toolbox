#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 ]]; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'guest recovery tests require root'
    printf 'skip Periphery recovery tests (root required)\n'; exit 0
fi
source tests/fixtures/komodo-periphery/harness.sh
kp_fixture absent
kp_request install
: > "$KP_TEST_ROOT/fail-key-mode"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'filesystem failure succeeded'; fi
jq -e '.rollback == "restored"' "$KP_TEST_ROOT/out" >/dev/null || fail 'absent-unit rollback failed'
[[ ! -e $KP_TEST_BINARY ]] || fail 'failed fresh install left executable'
kp_fixture upstream-v2
kp_request update
: > "$KP_TEST_ROOT/wrapper-main"
mkdir -p "$KP_TEST_ROOT/proc/123/task/123" "$KP_TEST_ROOT/proc/124"
printf '124\n' > "$KP_TEST_ROOT/proc/123/task/123/children"
printf 'PPid:\t123\n' > "$KP_TEST_ROOT/proc/124/status"
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'upstream shell wrapper health rejected'
printf 'ok missing-unit rollback and upstream service wrapper health\n'
kp_fixture upstream-v2
printf 'inactive\n' > "$KP_TEST_ROOT/active"
chown 0:1234 "$KP_TEST_BINARY"
chmod 0750 "$KP_TEST_BINARY"
kp_request update
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'custom-group update failed'
[[ $(stat -c '%u:%g:%a' "$KP_TEST_BINARY") == 0:1234:750 ]] || fail 'replacement lost executable access metadata'
kp_fixture upstream-v2
printf 'NeedDaemonReload=yes\n' > "$KP_TEST_ROOT/stale-unit"
result=$(kp_guest inspect)
jq -e '.layout == "unsupported"' <<<"$result" >/dev/null || fail 'stale effective command accepted'
kp_fixture upstream-v2
kp_request update
: > "$KP_TEST_ROOT/fail-destination-copy"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'destination-full install succeeded'; fi
kp_assert_no_guest_mutation
printf 'ok permissions, stale unit and destination staging safeguards\n'
kp_fixture upstream-v2
kp_request update
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'ownership setup failed'
printf '\n# administrator change\n' >> "$KP_TEST_ROOT/etc/systemd/system/periphery.service"
kp_request update
: > "$KP_TEST_LOG"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'owned service drift overwritten'; fi
kp_assert_no_guest_mutation
kp_fixture custom-direct-v2
mkdir -p "$KP_TEST_ROOT/etc/systemd/system/periphery.service.d"
printf '[Service]\nNice=10\n' > "$KP_TEST_ROOT/etc/systemd/system/periphery.service.d/priority.conf"
: > "$KP_TEST_ROOT/with-dropin"
kp_request update
before=$(sha256sum "$KP_TEST_ROOT/etc/systemd/system/periphery.service.d/priority.conf")
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'supported drop-in update failed'
[[ $(sha256sum "$KP_TEST_ROOT/etc/systemd/system/periphery.service.d/priority.conf") == "$before" ]] || fail 'drop-in changed'
printf 'ok ownership drift refusal and custom drop-in retention\n'

# Type=simple can be active before the child execs the agent binary.
kp_fixture absent
kp_request install
printf 'delayed-exec\n' > "$KP_TEST_ROOT/health-mode"
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'active service rejected before its agent executable was ready'
[[ -f $KP_TEST_BINARY && $(cat "$KP_TEST_ROOT/health-sample") -ge 12 ]] || fail 'startup wait skipped the full stability check'
printf 'ok active service waits for the agent executable before stability checks\n'
for scenario in activating zero-pid delayed-wrapper; do
    if [[ $scenario == delayed-wrapper ]]; then
        kp_fixture upstream-v2
        kp_request update
        : > "$KP_TEST_ROOT/wrapper-main"
        mkdir -p "$KP_TEST_ROOT/proc/123/task/123" "$KP_TEST_ROOT/proc/124"
        printf '124\n' > "$KP_TEST_ROOT/proc/123/task/123/children"
        printf 'PPid:\t123\n' > "$KP_TEST_ROOT/proc/124/status"
    else
        kp_fixture absent
        kp_request install
    fi
    printf '%s\n' "$scenario" > "$KP_TEST_ROOT/health-mode"
    kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail "$scenario startup readiness rejected"
    [[ $(cat "$KP_TEST_ROOT/health-sample") -ge 12 ]] || fail 'readiness wait shortened the stability check'
done
printf 'ok startup readiness handles activation, pending MainPID and shell wrappers\n'
for scenario in unreadable-exe wrong-exe restart pid-change lost-exe; do
    kp_fixture absent
    kp_request install
    printf '%s\n' "$scenario" > "$KP_TEST_ROOT/health-mode"
    if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail "$scenario startup incorrectly accepted"; fi
    [[ ! -e $KP_TEST_BINARY ]] || fail 'failed health check did not roll back installation'
    case $scenario in
        unreadable-exe) reason='cannot read the service MainPID executable' ;;
        wrong-exe) reason='not running the expected agent executable' ;;
        restart) reason='service restarted' ;;
        pid-change) reason='PID changed' ;;
        lost-exe) reason='cannot read the service MainPID executable' ;;
    esac
    jq -e --arg reason "$reason" '.rollback=="restored" and (.diagnostics.health|contains($reason))' "$KP_TEST_ROOT/out" >/dev/null || fail "$scenario did not explain its failed health check"
    [[ $(cat "$KP_TEST_ROOT/health-sample") -le 11 ]] || fail 'startup failure exceeded its bounded wait'
done
printf 'ok executable verification, PID stability and restart checks fail with precise diagnostics\n'
kp_fixture absent
kp_request install
: > "$KP_TEST_ROOT/fail-new-start"
: > "$KP_TEST_ROOT/silent-start-failure"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'silent start-command failure reported success'; fi
jq -e '.rollback=="restored" and .diagnostics.health=="systemctl start failed"' "$KP_TEST_ROOT/out" >/dev/null || fail 'silent start-command failure has no diagnostic reason'
printf 'ok silent start-command failure identifies the failed command\n'
