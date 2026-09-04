#!/usr/bin/env bash
# Exercise the public scheduled-update lifecycle without touching host systemd.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
    if command -v unshare >/dev/null 2>&1 && unshare -Ur true 2>/dev/null; then
        exec unshare -Ur "$0" "$@"
    fi
    printf 'skip LXC schedule test, root or an unprivileged user namespace is required\n'
    exit 0
fi

LX_TEST=$(mktemp -d)
trap 'rm -rf -- "$LX_TEST"' EXIT
export LX_TEST
mkdir -p "$LX_TEST/bin" "$LX_TEST/conf" "$LX_TEST/state" "$LX_TEST/systemd" \
    "$LX_TEST/toolbox-bin" "$LX_TEST/toolbox-lib"
for cmd in pveversion pvesh pct apt-get apt-mark dpkg awk curl systemctl systemd-analyze; do
    ln -s "$ROOT/tests/fixtures/lxc-update/command.sh" "$LX_TEST/bin/$cmd"
done
export PATH="$LX_TEST/bin:$PATH"
export TOOLBOX_CONF_DIR="$LX_TEST/conf" TOOLBOX_STATE_DIR="$LX_TEST/state" \
    TOOLBOX_SYSTEMD_DIR="$LX_TEST/systemd" TOOLBOX_BIN_DIR="$LX_TEST/toolbox-bin" \
    TOOLBOX_LIB_DIR="$LX_TEST/toolbox-lib"
scheduled_runner() {
    PVE_TOOLBOX_LIB="$TOOLBOX_LIB_DIR" \
    LX_GUEST_HELPER="$TOOLBOX_LIB_DIR/lxc-update-guest.sh" \
        "$TOOLBOX_BIN_DIR/pve-toolbox-lxc-update" --scheduled "$@"
}

# shellcheck source=lib/common.sh
source lib/common.sh
conf_set lxc-update LX_EXCLUDE 103
conf_set lxc-update DISCORD_WEBHOOK https://discord.com/api/webhooks/123/test-webhook
cat > "$LX_TEST/inventory.json" <<'JSON'
[{"vmid":101,"name":"web","status":"running"},
 {"vmid":102,"name":"db","status":"running"},
 {"vmid":103,"name":"excluded","status":"running"},
 {"vmid":104,"name":"off","status":"stopped"}]
JSON
: > "$LX_TEST/calls"

./pve-toolbox update lxc-update >/dev/null
[[ ! -e $LX_TEST/systemd/pve-toolbox-lxc-update.timer ]] \
    || fail 'upgrading a legacy configuration enabled automatic updates'
[[ $(./pve-toolbox status lxc-update) == *'configured (manual updates)'* ]] \
    || fail 'legacy configuration did not remain manual'

LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=weekly LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null
[[ $(conf_get lxc-update LX_SCHEDULE_ENABLED) == 1 ]] \
    || fail 'automatic updates were not enabled in configuration'
[[ $(conf_get lxc-update LX_SCHEDULE) == 'Sun *-*-* 04:00:00' ]] \
    || fail 'weekly schedule was not saved'

service="$TOOLBOX_SYSTEMD_DIR/pve-toolbox-lxc-update.service"
timer="$TOOLBOX_SYSTEMD_DIR/pve-toolbox-lxc-update.timer"
[[ -f $service && -f $timer ]] || fail 'scheduled service or timer was not installed'
grep -q '^ExecStart=.*pve-toolbox-lxc-update --scheduled$' "$service" \
    || fail 'service does not use the scheduled runner mode'
grep -q '^Nice=10$' "$service" || fail 'scheduled service has no reduced CPU priority'
grep -q '^IOSchedulingClass=idle$' "$service" || fail 'scheduled service has no idle I/O priority'
grep -q '^TimeoutStartSec=infinity$' "$service" || fail 'scheduled service can terminate apt'
grep -q '^TimeoutStopSec=infinity$' "$service" || fail 'systemd can time out a stopping apt transaction'
grep -q '^KillMode=process$' "$service" || fail 'systemd can signal the active pct transaction directly'
grep -q '^OnCalendar=Sun \*-\*-\* 04:00:00$' "$timer" || fail 'timer lost its calendar'
grep -q '^RandomizedDelaySec=1800$' "$timer" || fail 'timer has no 30 minute staggering'
grep -q '^AccuracySec=1s$' "$timer" || fail 'timer delay accuracy is not bounded'
grep -q '^Persistent=false$' "$timer" || fail 'timer catches up outside the maintenance window'
grep -q '^enable --now pve-toolbox-lxc-update.timer$' "$LX_TEST/calls" \
    || fail 'timer was not enabled'
[[ $(<"$LX_TEST/calls") != *'pct '* ]] \
    || fail 'enabling the timer immediately entered a container'
[[ -f $TOOLBOX_LIB_DIR/common.sh && -f $TOOLBOX_LIB_DIR/report.sh \
    && -f $TOOLBOX_LIB_DIR/discord.sh && -f $TOOLBOX_LIB_DIR/lxc-update-guest.sh ]] \
    || fail 'scheduled runner dependencies were not installed'
if grep -q 'TOOLBOX_ROOT=' "$service"; then
    fail 'scheduled service still depends on the toolbox checkout'
fi

: > "$LX_TEST/calls"
scheduled_runner >/dev/null \
    || fail 'configured scheduled runner failed'
calls=$(<"$LX_TEST/calls")
[[ $calls == *'--assume-yes upgrade --with-new-pkgs --no-remove'* ]] \
    || fail 'scheduled runner did not use the safe upgrade policy'
[[ $calls != *' dist-upgrade '* && $calls != *' autoremove '* && $calls != *' autoclean '* ]] \
    || fail 'scheduled runner allowed removals or cleanup'
[[ $(state_get lxc-update invocation) == scheduled ]] \
    || fail 'scheduled report did not identify its invocation'
[[ -n $(state_get lxc-update started_at) && -n $(state_get lxc-update completed_at) ]] \
    || fail 'scheduled report omitted execution times'
[[ $(state_get lxc-update container_ids) == *101* ]] \
    || fail 'scheduled report did not retain result IDs through the state API'

: > "$LX_TEST/calls"
if scheduled_runner --allow-removals >/dev/null 2>&1; then
    fail 'scheduled mode accepted removals'
fi
[[ ! -s $LX_TEST/calls ]] || fail 'invalid scheduled policy entered a guest'

exec {busy_lock}>"$TOOLBOX_STATE_DIR/lxc-update.lock"
flock -n "$busy_lock"
: > "$LX_TEST/calls"
busy_output=""
busy_rc=0
busy_output=$(scheduled_runner 2>&1) || busy_rc=$?
[[ $busy_rc == 0 && $busy_output == *'scheduled batch skipped'* ]] \
    || fail 'overlapping scheduled batch was not reported as busy'
[[ ! -s $LX_TEST/calls ]] || fail 'overlapping scheduled batch entered a guest'
[[ $(state_get lxc-update-overlap result) == busy \
    && -n $(state_get lxc-update-overlap skipped_at) ]] \
    || fail 'overlapping scheduled batch was not retained as a skip'
flock -u "$busy_lock"
exec {busy_lock}>&-
pass 'configured timer runs unattended with the safe scheduled policy'

status=$(./pve-toolbox status lxc-update)
[[ $status == *'Automatic updates: enabled'* \
    && $status == *'Schedule: Sun *-*-* 04:00:00'* \
    && $status == *'Next run: Sun 2026-09-06 04:17:00 CEST'* \
    && $status == *'Last timer trigger: Sun 2026-08-30 04:11:00 CEST'* \
    && $status == *'Start now: systemctl start pve-toolbox-lxc-update.service'* \
    && $status == *'Invocation: scheduled'* ]] \
    || fail "scheduled status is incomplete: $status"

touch "$LX_TEST/timer-inactive"
status=$(./pve-toolbox status lxc-update)
[[ $status == *'degraded'* && $status == *'timer is inactive'* \
    && $status == *'Next run: Sun 2026-09-06 04:17:00 CEST'* \
    && $status == *'Last timer trigger: Sun 2026-08-30 04:11:00 CEST'* ]] \
    || fail "inactive timer lost degraded status or timer history: $status"
rm "$LX_TEST/timer-inactive"
touch "$LX_TEST/timer-failed"
status=$(./pve-toolbox status lxc-update)
[[ $status == *'degraded'* && $status == *'automatic update timer failed'* ]] \
    || fail "failed timer was reported healthy: $status"
rm "$LX_TEST/timer-failed"

rm "$timer"
status=$(./pve-toolbox status lxc-update)
[[ $status == *'degraded'* && $status == *'timer file is missing'* ]] \
    || fail "missing timer was reported healthy: $status"
if ./pve-toolbox --quiet status lxc-update; then
    fail 'quiet status returned success for a degraded timer'
fi
LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=weekly LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null
sed -i 's/^OnCalendar=.*/OnCalendar=Mon *-*-* 01:00:00/' "$timer"
status=$(./pve-toolbox status lxc-update)
[[ $status == *'degraded'* && $status == *'timer schedule differs from configuration'* ]] \
    || fail "timer schedule drift was reported healthy: $status"
LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=weekly LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null
pass 'status exposes schedule timing, execution origin and timer drift'

# Scheduled notification policy is read from configuration. It reports every
# batch, while preflight and delivery failures keep the package result rules of
# the confirmed manual path.
LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=weekly LX_SCHEDULE_NOTIFY=y \
    ./pve-toolbox --yes install lxc-update >/dev/null
: > "$LX_TEST/calls"
scheduled_runner >/dev/null \
    || fail 'Discord-enabled scheduled run failed'
jq -e '.embeds[0].description | contains("Invocation: scheduled") and contains("ct.101")' \
    "$LX_TEST/discord.json" >/dev/null || fail 'scheduled Discord report lost its identity or results'
[[ $(state_get lxc-update notification) == delivered ]] \
    || fail 'scheduled Discord delivery was not recorded'

: > "$LX_TEST/fail-notify"
: > "$LX_TEST/calls"
scheduled_runner >/dev/null \
    || fail 'Discord delivery failure changed the scheduled package result'
[[ $(state_get lxc-update notification) == failed ]] \
    || fail 'scheduled Discord failure was not recorded'
rm "$LX_TEST/fail-notify"

conf_set lxc-update DISCORD_WEBHOOK ''
: > "$LX_TEST/calls"
status=$(./pve-toolbox status lxc-update)
[[ $status == *'degraded'* && $status == *'automatic Discord webhook is invalid'* ]] \
    || fail "invalid automatic webhook was reported healthy: $status"
if scheduled_runner >/dev/null 2>&1; then
    fail 'scheduled run accepted a missing requested webhook'
fi
if grep -Eq '^(pct|apt|discord) ' "$LX_TEST/calls"; then
    fail 'missing scheduled webhook did not fail before guest work'
fi
conf_set lxc-update DISCORD_WEBHOOK https://discord.com/api/webhooks/123/test-webhook

: > "$LX_TEST/fail-refresh-101"
: > "$LX_TEST/calls"
if scheduled_runner >/dev/null; then
    fail 'scheduled container failure returned success'
fi
grep -q '^pct 102 refresh$' "$LX_TEST/calls" \
    || fail 'scheduled batch stopped after one container failed'
[[ $(state_get lxc-update exit_code) == 1 ]] \
    || fail 'scheduled failure was not retained'
rm "$LX_TEST/fail-refresh-101"

cat > "$LX_TEST/inventory.json" <<'JSON'
[{"vmid":103,"name":"excluded","status":"running"},
 {"vmid":104,"name":"off","status":"stopped"}]
JSON
: > "$LX_TEST/calls"
scheduled_runner >/dev/null \
    || fail 'all-skipped scheduled batch returned failure'
[[ $(state_get lxc-update exit_code) == 0 ]] \
    || fail 'all-skipped scheduled result was not successful'
jq -e '.embeds[0].description | contains("ct.103: skipped") and contains("ct.104: skipped")' \
    "$LX_TEST/discord.json" >/dev/null || fail 'all-skipped scheduled report was not delivered'
pass 'scheduled reporting and partial failures retain the manual batch contract'

# A module refresh keeps the exact configured calendar and refuses to replace
# its runner while a package batch owns the shared lock.
LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=custom \
LX_SCHEDULE='Tue *-*-* 02:30:00' LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null
cp "$(conf_file lxc-update)" "$LX_TEST/conf-before-identical-active-change"
exec {identical_lock}>"$TOOLBOX_STATE_DIR/lxc-update.lock"
flock -n "$identical_lock"
if LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=daily LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null 2>&1; then
    fail 'reconfiguration replaced an identical runner during an active batch'
fi
cmp -s "$(conf_file lxc-update)" "$LX_TEST/conf-before-identical-active-change" \
    || fail 'active-batch refusal changed configuration with an identical runner'
flock -u "$identical_lock"
exec {identical_lock}>&-
printf '# stale runner\n' > "$TOOLBOX_BIN_DIR/pve-toolbox-lxc-update"
status=$(./pve-toolbox status lxc-update)
[[ $status == *'degraded'* && $status == *'scheduled runner differs from this toolbox'* ]] \
    || fail "stale scheduled runner was reported healthy: $status"
cp "$(conf_file lxc-update)" "$LX_TEST/conf-before-active-change"
exec {schedule_lock}>"$TOOLBOX_STATE_DIR/lxc-update.lock"
flock -n "$schedule_lock"
if LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=daily LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null 2>&1; then
    fail 'reconfiguration replaced a stale runner during an active batch'
fi
cmp -s "$(conf_file lxc-update)" "$LX_TEST/conf-before-active-change" \
    || fail 'failed active-batch reconfiguration changed the schedule'
if ./pve-toolbox update lxc-update >/dev/null 2>&1; then
    fail 'module update replaced the runner during an active batch'
fi
grep -q '^# stale runner$' "$TOOLBOX_BIN_DIR/pve-toolbox-lxc-update" \
    || fail 'active-batch refusal changed the runner'
flock -u "$schedule_lock"
exec {schedule_lock}>&-
./pve-toolbox update lxc-update >/dev/null || fail 'idle module update failed'
cmp -s modules/lxc-update/run.sh "$TOOLBOX_BIN_DIR/pve-toolbox-lxc-update" \
    || fail 'module update did not refresh the scheduled runner'
grep -q '^OnCalendar=Tue \*-\*-\* 02:30:00$' "$timer" \
    || fail 'module update changed the configured schedule'
pass 'module updates preserve schedules and cannot race a package batch'

# Invalid reconfiguration leaves the working schedule intact. Disabling stops
# future runs without discarding operator settings or the last report.
conf_set lxc-update LX_SCHEDULE_NOTIFY 1
cp "$timer" "$LX_TEST/timer-before-invalid"
cp "$(conf_file lxc-update)" "$LX_TEST/conf-before-invalid"
if LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=custom LX_SCHEDULE=nonsense \
    ./pve-toolbox --yes install lxc-update >/dev/null 2>&1; then
    fail 'invalid custom schedule was accepted'
fi
cmp -s "$timer" "$LX_TEST/timer-before-invalid" \
    || fail 'invalid schedule changed the working timer'
cmp -s "$(conf_file lxc-update)" "$LX_TEST/conf-before-invalid" \
    || fail 'invalid schedule changed configuration'
if LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=custom LX_SCHEDULE='*-02-30 04:00:00' \
    ./pve-toolbox --yes install lxc-update >/dev/null 2>&1; then
    fail 'custom schedule with no future elapse was accepted'
fi
cmp -s "$(conf_file lxc-update)" "$LX_TEST/conf-before-invalid" \
    || fail 'dead schedule changed configuration'

: > "$LX_TEST/fail-enable"
if LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=daily LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null 2>&1; then
    fail 'timer enable failure returned success'
fi
rm -f "$LX_TEST/fail-enable"
cmp -s "$timer" "$LX_TEST/timer-before-invalid" \
    || fail 'timer enable failure did not restore the working unit'
cmp -s "$(conf_file lxc-update)" "$LX_TEST/conf-before-invalid" \
    || fail 'timer enable failure did not restore configuration'
grep -q '^enable --now pve-toolbox-lxc-update.timer$' "$LX_TEST/calls" \
    || fail 'working timer was not restored after enable failure'

: > "$LX_TEST/fail-disable"
if LX_SCHEDULE_ENABLED=n ./pve-toolbox --yes install lxc-update >/dev/null 2>&1; then
    fail 'timer stop failure returned success'
fi
cmp -s "$timer" "$LX_TEST/timer-before-invalid" \
    || fail 'timer stop failure did not retain the working unit'
cmp -s "$(conf_file lxc-update)" "$LX_TEST/conf-before-invalid" \
    || fail 'timer stop failure did not restore configuration'

last_report=$(<"$TOOLBOX_STATE_DIR/lxc-update.state")
LX_SCHEDULE_ENABLED=n ./pve-toolbox --yes install lxc-update >/dev/null
[[ $(conf_get lxc-update LX_SCHEDULE_ENABLED) == 0 ]] \
    || fail 'automatic updates remained enabled'
[[ $(conf_get lxc-update LX_SCHEDULE) == 'Tue *-*-* 02:30:00' ]] \
    || fail 'disabling discarded the configured calendar'
[[ $(conf_get lxc-update LX_EXCLUDE) == 103 ]] \
    || fail 'disabling discarded exclusions'
[[ $(conf_get lxc-update LX_SCHEDULE_NOTIFY) == 1 ]] \
    || fail 'disabling discarded the scheduled notification preference'
[[ ! -e $service && ! -e $timer ]] || fail 'disabling retained systemd units'
[[ $(<"$TOOLBOX_STATE_DIR/lxc-update.state") == "$last_report" ]] \
    || fail 'disabling changed the last report'
touch "$LX_TEST/timer-failed"
status=$(./pve-toolbox status lxc-update)
[[ $status == *'degraded'* \
    && $status == *'scheduler files remain while automatic updates are disabled'* ]] \
    || fail "orphan failed timer was hidden while scheduling was disabled: $status"
./pve-toolbox update lxc-update >/dev/null \
    || fail 'disabled module did not clear the orphan failed timer state'
[[ ! -e $LX_TEST/timer-failed ]] || fail 'failed timer state was not cleared'
: > "$LX_TEST/calls"
if scheduled_runner >/dev/null 2>&1; then
    fail 'disabled automatic runner still updated containers'
fi
[[ ! -s $LX_TEST/calls ]] || fail 'disabled automatic runner entered a guest'
status=$(./pve-toolbox status lxc-update)
[[ $status == *'Automatic updates: disabled'* ]] \
    || fail "disabled schedule status is wrong: $status"
pass 'invalid and disabled schedules preserve the last working operator state'

# Re-enable so uninstall has a complete scheduled installation to remove.
LX_SCHEDULE_ENABLED=y LX_SCHEDULE_PRESET=weekly LX_SCHEDULE_NOTIFY=n \
    ./pve-toolbox --yes install lxc-update >/dev/null
./pve-toolbox --yes uninstall lxc-update >/dev/null
[[ ! -e $(conf_file lxc-update) && ! -e $service && ! -e $timer \
    && ! -e $TOOLBOX_BIN_DIR/pve-toolbox-lxc-update \
    && ! -e $TOOLBOX_LIB_DIR/lxc-update-guest.sh ]] \
    || fail 'uninstall retained schedule configuration or runtime files'
[[ -f $TOOLBOX_STATE_DIR/lxc-update.state ]] \
    || fail 'uninstall removed the last report'
pass 'uninstall removes scheduler files and retains the report'
