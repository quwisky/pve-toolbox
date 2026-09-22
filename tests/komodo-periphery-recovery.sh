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
