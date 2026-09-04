#!/usr/bin/env bash
# Package cleanup must preserve the legacy module until migration succeeds.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
run_retirement() {
    local root=$1 mode=$2
    shift 2
    PVE_TOOLBOX_MAINTAINER_ROOT=$root \
        "$ROOT/scripts/retire-native-notifications.sh" "$mode" "$@"
}
make_layout() {
    local root=$1
    mkdir -p "$root/usr/lib/pve-toolbox/modules/native-notifications" \
        "$root/usr/bin" "$root/usr/local/bin" "$root/usr/share/pve-toolbox/notification-templates" \
        "$root/etc/pve-toolbox" "$root/etc/pve/notification-templates/default" \
        "$root/etc/pve/priv" "$root/var/lib/pve-toolbox/native-notifications-backups"
    printf 'legacy module\n' > "$root/usr/lib/pve-toolbox/modules/native-notifications/module.sh"
    printf 'helper\n' > "$root/usr/bin/pve-toolbox-native-notify"
    cp -- "$root/usr/bin/pve-toolbox-native-notify" \
        "$root/usr/local/bin/pve-toolbox-native-notify"
    printf 'template\n' > "$root/etc/pve/notification-templates/default/pve-toolbox-body.txt.hbs"
    printf 'protected\n' > "$root/etc/pve/priv/notifications.cfg"
    printf 'backup\n' > "$root/var/lib/pve-toolbox/native-notifications-backups/notifications.cfg"
}

fresh="$WORK/fresh"
make_layout "$fresh"
run_retirement "$fresh" fresh
[[ ! -e $fresh/usr/lib/pve-toolbox/modules/native-notifications \
    && -f $fresh/usr/local/bin/pve-toolbox-native-notify \
    && -f $fresh/etc/pve/notification-templates/default/pve-toolbox-body.txt.hbs ]] \
    || fail "fresh install cleanup removed non-module notification assets"
pass "fresh installs do not retain notification provisioning"

future="$WORK/future"
mkdir -p "$future/usr/lib/pve-toolbox/modules/native-notifications" \
    "$future/usr/bin"
printf 'legacy module\n' \
    > "$future/usr/lib/pve-toolbox/modules/native-notifications/module.sh"
printf 'helper\n' > "$future/usr/bin/pve-toolbox-native-notify"
run_retirement "$future" upgrade 0.7.0
[[ ! -e $future/usr/lib/pve-toolbox/modules/native-notifications \
    && -f $future/usr/bin/pve-toolbox-native-notify ]] \
    || fail "later clean upgrade retained the compatibility module"
pass "later clean upgrades discard only the compatibility module"

blocked="$WORK/blocked"
make_layout "$blocked"
blocked_output=""
blocked_rc=0
blocked_output=$(run_retirement "$blocked" upgrade 0.7.0 2>&1) || blocked_rc=$?
[[ $blocked_rc -ne 0 && $blocked_output == *'migration is not recorded'* \
    && -f $blocked/usr/lib/pve-toolbox/modules/native-notifications/module.sh \
    && -f $blocked/var/lib/pve-toolbox/native-notifications-backups/notifications.cfg ]] \
    || fail "cleanup ran without the migration marker"
pass "upgrade cleanup waits for the notification migration"

migrated="$WORK/migrated"
make_layout "$migrated"
printf '010-native-notification-ownership\n' \
    > "$migrated/var/lib/pve-toolbox/migrations.state"
chmod 0644 "$migrated/var/lib/pve-toolbox/migrations.state"
run_retirement "$migrated" upgrade
[[ ! -e $migrated/usr/lib/pve-toolbox/modules/native-notifications \
    && ! -e $migrated/usr/local/bin/pve-toolbox-native-notify \
    && ! -e $migrated/var/lib/pve-toolbox/native-notifications-backups \
    && -f $migrated/usr/bin/pve-toolbox-native-notify \
    && -f $migrated/etc/pve/notification-templates/default/pve-toolbox-body.txt.hbs \
    && -f $migrated/etc/pve/priv/notifications.cfg ]] \
    || fail "completed cleanup removed active PVE notification data"
pass "completed upgrades remove only obsolete provisioning files"

ambiguous="$WORK/ambiguous"
make_layout "$ambiguous"
printf '010-native-notification-ownership\n' \
    > "$ambiguous/var/lib/pve-toolbox/migrations.state"
printf 'legacy config\n' > "$ambiguous/etc/pve-toolbox/native-notifications.conf"
chmod 0600 "$ambiguous/etc/pve-toolbox/native-notifications.conf"
if run_retirement "$ambiguous" upgrade >/dev/null 2>&1; then
    fail "cleanup accepted legacy ownership files after migration"
fi
[[ -f $ambiguous/usr/lib/pve-toolbox/modules/native-notifications/module.sh \
    && -f $ambiguous/etc/pve-toolbox/native-notifications.conf ]] \
    || fail "ambiguous cleanup changed the fallback installation"
pass "ambiguous post-migration state fails closed"
