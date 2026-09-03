#!/usr/bin/env bash
# Exercise real host and guest runners with isolated Proxmox/APT/Discord doubles.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
if [[ $EUID != 0 ]] || ! command -v expect >/dev/null; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'LXC execution tests require root and expect'
    printf 'skip LXC execution tests, require root and expect\n'
    exit 0
fi
LX_TEST=$(mktemp -d)
trap 'rm -rf -- "$LX_TEST"' EXIT
export LX_TEST
mkdir -p "$LX_TEST/bin" "$LX_TEST/conf" "$LX_TEST/state"
for cmd in pveversion pvesh pct apt-get apt-mark dpkg awk curl; do
    ln -s "$ROOT/tests/fixtures/lxc-update/command.sh" "$LX_TEST/bin/$cmd"
done
export PATH="$LX_TEST/bin:$PATH"
export TOOLBOX_CONF_DIR="$LX_TEST/conf" TOOLBOX_STATE_DIR="$LX_TEST/state"
# shellcheck source=lib/common.sh
source lib/common.sh
conf_set lxc-update LX_EXCLUDE 103
conf_set lxc-update DISCORD_WEBHOOK https://discord.com/api/webhooks/123/test-webhook
cat > "$LX_TEST/inventory.json" <<'JSON'
[{"vmid":101,"name":"web","status":"running"},
 {"vmid":102,"name":"db","status":"running"},
 {"vmid":103,"name":"excluded","status":"running"},
 {"vmid":104,"name":"off","status":"stopped"},
 {"vmid":105,"name":"template","status":"stopped","template":1},
 {"vmid":106,"name":"alpine","status":"running"}]
JSON
printf '{"ostype":"alpine"}' > "$LX_TEST/106.config"
reset_calls() { : > "$LX_TEST/calls"; }
execute() { expect tests/fixtures/lxc-update/drive.exp normal ./pve-toolbox lxc-update "$@"; }
reset_calls
output=$(./pve-toolbox lxc-update --dry-run --notify)
[[ $output == *'cached package indexes may be stale'* && $output == *'saved exclusion'* && $output == *'unsupported guest OS'* ]] || fail 'preview or skipped reasons missing'
[[ $(<"$LX_TEST/calls") != *'--assume-yes'* && $(<"$LX_TEST/calls") != *' update '* && $(<"$LX_TEST/calls") != *discord* ]] || fail 'preview performed mutations'
[[ $(state_get lxc-update last_summary) == *'preview completed'* ]] || fail 'preview report not saved'
[[ $(state_get lxc-update notification) == not-requested ]] || fail 'preview notification state was unexpected'
pass 'preview simulates without refreshing, mutating or notifying and saves its final report'

cat > "$LX_TEST/os-release" <<'OS_RELEASE'
ID=ubuntu
VERSION_CODENAME=noble
OS_RELEASE
cat > "$LX_TEST/targets" <<'TARGETS'
Origin: Ubuntu
Codename: noble-updates
Trusted: yes
Identifier: Packages
TARGETS
LX_TEST_CT=201 bash modules/lxc-update/guest.sh preview 0 > "$LX_TEST/ubuntu-output"
grep -q 'Guest: ubuntu noble' "$LX_TEST/ubuntu-output" || fail 'Ubuntu guest was not identified'
rm "$LX_TEST/os-release" "$LX_TEST/targets"
pass 'Ubuntu release identification and matching repository metadata'

reset_calls
execute --notify || fail 'default batch failed'
calls=$(<"$LX_TEST/calls")
[[ $calls == *'--assume-yes upgrade --with-new-pkgs --no-remove'* ]] || fail 'default policy missing'
[[ $calls != *' dist-upgrade '* && $calls != *' autoremove '* && $calls != *' autoclean '* ]] || fail 'default policy allowed cleanup'
[[ $calls != *'pct 103'* && $calls != *'pct 104'* && $calls != *'pct 105'* && $calls != *'pct 106'* ]] || fail 'ineligible container entered'
[[ $(state_get lxc-update notification) == delivered ]] || fail 'notification not recorded'
[[ $(<"$TOOLBOX_STATE_DIR/lxc-update.state") != *fixture-secret* ]] || fail 'report leaked credential'
jq -e '.embeds[0].description | contains("held-app") and contains("reboot=")' "$LX_TEST/discord.json" >/dev/null || fail 'Discord missing outcomes'
pass 'default update respects selection, package safeguards, redaction and optional Discord outcomes'

reset_calls
execute --allow-removals 101 || fail 'removal mode failed'
calls=$(<"$LX_TEST/calls")
[[ $calls == *'--assume-yes dist-upgrade'* && $calls == *'--assume-yes autoremove'* && $calls == *' autoclean '* ]] || fail 'removal flag omitted required actions'
[[ $calls != *'--purge'* && $calls != *'pct 102'* ]] || fail 'removal mode widened selection or purged'
pass 'explicit removals mode runs full upgrade, autoremove and autoclean on selected IDs only'

reset_calls
: > "$LX_TEST/fail-autoremove-101"
if execute --allow-removals --notify 101; then fail 'cleanup failure returned success'; fi
jq -e '.embeds[0].description | contains("held-app") and contains("reboot=") and contains("failed")' \
    "$LX_TEST/discord.json" >/dev/null || fail 'cleanup failure Discord summary lost known results'
rm "$LX_TEST/fail-autoremove-101"
pass 'cleanup failure retains known held-package and reboot results in Discord summary'

reset_calls
: > "$LX_TEST/fail-refresh-101"
if execute; then fail 'refresh failure returned success'; fi
calls=$(<"$LX_TEST/calls")
[[ $calls == *'pct 102 refresh'* ]] || fail 'batch did not continue safely'
# Inspect individual log lines, not a glob spanning both containers.
if grep -E '^apt 101 .*--assume-yes' "$LX_TEST/calls" >/dev/null; then fail 'upgrade followed failed refresh'; fi
rm "$LX_TEST/fail-refresh-101"
pass 'refresh failure blocks that upgrade and later containers continue with failing batch status'

printf 'Origin: Debian\nCodename: forky\nTrusted: yes\nIdentifier: Packages\n' > "$LX_TEST/targets"
reset_calls
if execute 101; then fail 'cross-release repositories accepted'; fi
[[ $(<"$LX_TEST/calls") != *'--assume-yes'* ]] || fail 'release mismatch reached mutation'
rm "$LX_TEST/targets"
printf 'Origin: Debian derivative\nCodename: trixie\nTrusted: yes\nIdentifier: Packages\n' > "$LX_TEST/targets"
reset_calls
if execute 101; then fail 'noncanonical base repository accepted'; fi
[[ $(<"$LX_TEST/calls") != *'--assume-yes'* ]] || fail 'noncanonical origin reached mutation'
rm "$LX_TEST/targets"
: > "$LX_TEST/broken"
if execute 101; then fail 'broken dpkg accepted'; fi
rm "$LX_TEST/broken"
pass 'release mismatch, noncanonical origins and broken package state fail without repairs or upgrades'

reset_calls
if ./pve-toolbox lxc-update 101 >/dev/null 2>&1; then fail 'noninteractive execution accepted'; fi
if ./pve-toolbox --yes lxc-update 101 >/dev/null 2>&1; then fail '--yes bypassed confirmation'; fi
if ./pve-toolbox --dry-run status >/dev/null 2>&1; then fail 'LXC flag accepted for another command'; fi
if ./pve-toolbox lxc-update --dry-run 999 >/dev/null 2>&1; then fail 'nonlocal ID accepted'; fi
[[ ! -s $LX_TEST/calls ]] || fail 'invalid request entered guests'
pass 'confirmation and exact local targets cannot be bypassed'

reset_calls
execute 103 || fail 'explicit excluded container should remain a documented skip'
[[ ! -s $LX_TEST/calls ]] || fail 'explicit selection bypassed saved exclusion'
./pve-toolbox update lxc-update >/dev/null
[[ ! -s $LX_TEST/calls ]] || fail 'toolkit update ran guest updates'
pass 'exclusions stay authoritative and toolkit module updates do not enter guests'

reset_calls
: > "$LX_TEST/fail-notify"
execute --notify 101 || fail 'notification failure changed update exit status'
[[ $(state_get lxc-update notification) == failed ]] || fail 'delivery failure not saved'
rm "$LX_TEST/fail-notify"
conf_set lxc-update DISCORD_WEBHOOK ''
reset_calls
if execute --notify 101; then fail 'missing webhook accepted'; fi
[[ ! -s $LX_TEST/calls ]] || fail 'missing webhook did not block before guest changes'
pass 'Discord errors preserve package outcome and missing configuration blocks execution'

reset_calls
: > "$LX_TEST/delay"
conf_set lxc-update DISCORD_WEBHOOK https://discord.com/api/webhooks/123/test-webhook
rc=0
expect tests/fixtures/lxc-update/drive.exp cancel ./pve-toolbox lxc-update --allow-removals --notify || rc=$?
[[ $rc == 130 ]] || fail "cancellation returned $rc"
[[ $(<"$LX_TEST/calls") == *transaction-finished* && $(<"$LX_TEST/calls") != *'pct 102 refresh'* ]] || fail 'cancellation killed transaction or started another guest'
[[ $(<"$LX_TEST/calls") != *'--assume-yes autoremove'* ]] || fail 'cancellation started a later cleanup transaction'
jq -e '.embeds[0].description | contains("held-app") and contains("reboot=") and contains("cancelled")' \
    "$LX_TEST/discord.json" >/dev/null || fail 'cancellation Discord summary lost known results'
rm "$LX_TEST/delay"
pass 'Ctrl+C waits for the active transaction and prevents subsequent guests'

# Check state and mutation serialization independently of APT's own locks.
exec {test_lock}>"$TOOLBOX_STATE_DIR/lxc-update.lock"
flock -n "$test_lock"
reset_calls
if execute 101; then fail 'overlapping batch lock accepted'; fi
[[ ! -s $LX_TEST/calls ]] || fail 'overlapping batch reached guests'
flock -u "$test_lock"
exec {test_lock}>&-
pass 'overlapping batch execution fails before entering any guest'

conf_set lxc-update DISCORD_WEBHOOK https://discord.com/api/webhooks/123/test-webhook
if command -v whiptail >/dev/null; then
    expect tests/fixtures/lxc-update/menu.exp || fail 'LXC menu flow failed'
    pass 'driven terminal preview and confirmed Discord-enabled execution'
elif [[ ${TUI_TEST_REQUIRED:-0} == 1 ]]; then
    fail 'LXC menu test requires whiptail'
else
    printf 'skip LXC menu test, no whiptail\n'
fi
