#!/usr/bin/env bash
# Compatibility-module transactions, including pmxcfs template writes and rollback.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

TOOLBOX_CONF_DIR="$WORK/conf"
TOOLBOX_STATE_DIR="$WORK/state"
TOOLBOX_BIN_DIR="$WORK/bin"
TOOLBOX_ROOT="$ROOT"
NT_TEMPLATE_DIR="$WORK/templates"
NT_PVE_DIR="$WORK/pve"
API_ROOT="$WORK/api"
TEST_COUNT_FILE="$WORK/test-count"
export TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR TOOLBOX_BIN_DIR TOOLBOX_ROOT NT_TEMPLATE_DIR \
    NT_PVE_DIR API_ROOT TEST_COUNT_FILE
mkdir -p "$TOOLBOX_CONF_DIR" "$TOOLBOX_STATE_DIR" "$TOOLBOX_BIN_DIR" \
    "$NT_TEMPLATE_DIR" "$NT_PVE_DIR/priv" "$API_ROOT/endpoints" "$API_ROOT/matchers"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/report.sh
source "$ROOT/lib/report.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"
# shellcheck source=debian/legacy/native-notifications/module.sh
source "$ROOT/debian/legacy/native-notifications/module.sh"

# pmxcfs allows content writes but rejects install's permission changes.
install() {
    local destination=${!#}
    if [[ $destination == "$NT_TEMPLATE_DIR/"* ]]; then
        printf 'install: setting permissions for %s: Operation not permitted\n' "$destination" >&2
        return 1
    fi
    command install "$@"
}

cat() {
    if [[ ${FAIL_TEMPLATE_COPY:-0} == 1 && ${!#} == "$ROOT/share/notification-templates/${NT_TEMPLATE_FILES[0]}" ]]; then
        printf 'partial template\n'
        return 1
    fi
    command cat "$@"
}

_fixture_value() { # _fixture_value <option> <args...>
    local wanted=$1
    shift
    while [[ $# -gt 0 ]]; do
        if [[ $1 == "$wanted" ]]; then printf '%s' "${2:-}"; return 0; fi
        shift
    done
    return 1
}

_fixture_write_endpoint() { # _fixture_write_endpoint <type> <name> <args...>
    local type=$1 name=$2
    shift 2
    local comment disable url server
    comment=$(_fixture_value --comment "$@" || true)
    disable=$(_fixture_value --disable "$@" || printf 0)
    url=$(_fixture_value --url "$@" || true)
    server=$(_fixture_value --server "$@" || true)
    jq -n --arg name "$name" --arg type "$type" --arg comment "$comment" \
        --arg disable "$disable" --arg url "$url" --arg server "$server" \
        '{name:$name,type:$type,comment:$comment,disable:($disable|tonumber),url:$url,server:$server}' \
        > "$API_ROOT/endpoints/$type.$name.json"
    local token password secret
    token=$(_fixture_value --token "$@" || true)
    password=$(_fixture_value --password "$@" || true)
    secret=$(_fixture_value --secret "$@" || true)
    if [[ -n $token$password$secret ]]; then
        ( umask 077; printf '%s%s%s' "$token" "$password" "$secret" \
            > "$API_ROOT/endpoints/$type.$name.private" )
    fi
}

_fixture_write_matcher() { # _fixture_write_matcher <name> <args...>
    local name=$1
    shift
    local comment disable target severity field mode
    comment=$(_fixture_value --comment "$@" || true)
    disable=$(_fixture_value --disable "$@" || printf 0)
    target=$(_fixture_value --target "$@" || true)
    severity=$(_fixture_value --match-severity "$@" || true)
    field=$(_fixture_value --match-field "$@" || true)
    mode=$(_fixture_value --mode "$@" || true)
    jq -n --arg name "$name" --arg comment "$comment" --arg disable "$disable" \
        --arg target "$target" --arg severity "$severity" --arg field "$field" \
        --arg mode "$mode" \
        '{name:$name,comment:$comment,disable:($disable|tonumber),target:[$target],
          "match-severity":($severity|split(",")),"match-field":
          (if $field == "" then [] else [$field] end),mode:$mode}' \
        > "$API_ROOT/matchers/$name.json"
}

pvesh() {
    local action=${1:-} path=${2:-}
    shift 2 || true
    local rest name type file count
    case "$action:$path" in
        get:/cluster/notifications/endpoints/*/*)
            rest=${path#/cluster/notifications/endpoints/}
            type=${rest%%/*}; name=${rest#*/}
            file="$API_ROOT/endpoints/$type.$name.json"
            [[ -f $file ]] || return 2
            cat "$file"
            ;;
        get:/cluster/notifications/matchers/*)
            name=${path##*/}; file="$API_ROOT/matchers/$name.json"
            [[ -f $file ]] || return 2
            cat "$file"
            ;;
        create:/cluster/notifications/endpoints/*)
            type=${path##*/}; name=$(_fixture_value --name "$@")
            [[ ! -e $API_ROOT/endpoints/$type.$name.json ]] || return 3
            _fixture_write_endpoint "$type" "$name" "$@"
            ;;
        set:/cluster/notifications/endpoints/*/*)
            rest=${path#/cluster/notifications/endpoints/}
            type=${rest%%/*}; name=${rest#*/}
            [[ -e $API_ROOT/endpoints/$type.$name.json ]] || return 4
            _fixture_write_endpoint "$type" "$name" "$@"
            ;;
        delete:/cluster/notifications/endpoints/*/*)
            rest=${path#/cluster/notifications/endpoints/}
            type=${rest%%/*}; name=${rest#*/}
            [[ ${FAIL_TARGET_DELETE:-0} -eq 0 ]] || return 6
            rm -f -- "$API_ROOT/endpoints/$type.$name.json" \
                "$API_ROOT/endpoints/$type.$name.private"
            ;;
        create:/cluster/notifications/matchers)
            name=$(_fixture_value --name "$@")
            [[ ! -e $API_ROOT/matchers/$name.json ]] || return 3
            _fixture_write_matcher "$name" "$@"
            ;;
        set:/cluster/notifications/matchers/*)
            name=${path##*/}; [[ -e $API_ROOT/matchers/$name.json ]] || return 4
            _fixture_write_matcher "$name" "$@"
            ;;
        delete:/cluster/notifications/matchers/*)
            name=${path##*/}; rm -f -- "$API_ROOT/matchers/$name.json"
            ;;
        create:/cluster/notifications/targets/*/test)
            [[ ${FAIL_TEST_DELIVERY:-0} -eq 0 ]] || {
                printf 'delivery failed token=%s\n' "${NT_DISCORD_WEBHOOK:-none}" >&2
                return 5
            }
            count=0; [[ ! -f $TEST_COUNT_FILE ]] || count=$(<"$TEST_COUNT_FILE")
            printf '%s\n' "$((count + 1))" > "$TEST_COUNT_FILE"
            ;;
        *) fail "unexpected pvesh call: $action $path $*" ;;
    esac
}

printf 'public-before\n' > "$NT_PVE_DIR/notifications.cfg"
printf 'private-before\n' > "$NT_PVE_DIR/priv/notifications.cfg"
chmod 0600 "$NT_PVE_DIR/priv/notifications.cfg"

_nt_defaults
NT_KIND=discord
NT_TARGET_NAME=pve-toolbox-discord
NT_MATCHER_NAME=pve-toolbox-discord
NT_MATCH_SEVERITY=warning,error
NT_MATCH_FIELD='exact:type=vzdump'
NT_MATCH_MODE=all
NT_DISCORD_WEBHOOK='https://discord.com/api/webhooks/123456/super-secret-token'
_nt_validate || fail "valid Discord configuration was rejected: $NT_ERROR"
rc=0
initial_failure=$(FAIL_TEST_DELIVERY=1 _nt_configure 2>&1) || rc=$?
[[ $rc -ne 0 ]] || fail "initial failed delivery was accepted"
[[ ! -e $API_ROOT/endpoints/webhook.pve-toolbox-discord.json \
    && ! -e $API_ROOT/matchers/pve-toolbox-discord.json ]] \
    || fail "initial failure retained API objects"
[[ ! -e $TOOLBOX_BIN_DIR/pve-toolbox-native-notify \
    && ! -e $NT_TEMPLATE_DIR/pve-toolbox-body.txt.hbs ]] \
    || fail "initial failure retained helper assets"
[[ ! -e $(conf_file native-notifications) \
    && ! -e $TOOLBOX_STATE_DIR/native-notifications.state ]] \
    || fail "initial failure claimed module ownership"
[[ $initial_failure != *super-secret-token* ]] || fail "initial failure leaked a credential"
pass "initial delivery failure rolls back every owned artifact"

rc=0
copy_failure=$(FAIL_TEMPLATE_COPY=1 _nt_configure 2>&1) || rc=$?
[[ $rc -ne 0 ]] || fail "partial template copy failure was accepted"
[[ $copy_failure == *'previous owned objects were restored'* ]] \
    || fail "template copy failure did not report rollback"
[[ ! -e $API_ROOT/endpoints/webhook.pve-toolbox-discord.json \
    && ! -e $API_ROOT/matchers/pve-toolbox-discord.json \
    && ! -e $TOOLBOX_BIN_DIR/$NT_HELPER \
    && ! -e $(conf_file native-notifications) \
    && ! -e $TOOLBOX_STATE_DIR/native-notifications.state ]] \
    || fail "template copy failure retained objects or claimed ownership"
for file in "${NT_TEMPLATE_FILES[@]}"; do
    [[ ! -e $NT_TEMPLATE_DIR/$file ]] || fail "template copy failure retained $file"
done
pass "first template copy failure aborts configuration and removes partial assets"

output=$(_nt_configure) || fail "initial notification configuration failed"
_nt_assets_current || fail "installed template contents differ from source"
[[ $(stat -c '%a' "$TOOLBOX_BIN_DIR/$NT_HELPER") == 755 ]] \
    || fail "notification helper is not executable"
[[ -f $API_ROOT/endpoints/webhook.pve-toolbox-discord.json ]] \
    || fail "Discord target was not created"
[[ -f $API_ROOT/matchers/pve-toolbox-discord.json ]] || fail "matcher was not created"
[[ $(<"$TEST_COUNT_FILE") == 1 ]] || fail "test delivery did not run"
[[ $(find "$API_ROOT/endpoints" -name '*.json' | wc -l) -eq 1 ]] \
    || fail "initial install duplicated endpoints"
public=$(<"$API_ROOT/endpoints/webhook.pve-toolbox-discord.json")
[[ $public != *super-secret-token* && $public == *'{{ secrets.token }}'* ]] \
    || fail "Discord token entered public endpoint configuration"
[[ $(<"$TOOLBOX_STATE_DIR/native-notifications.state") != *super-secret-token* ]] \
    || fail "Discord token entered module state"
[[ $(stat -c '%a' "$(conf_file native-notifications)") == 600 ]] \
    || fail "credential config is not mode 0600"
[[ $output != *super-secret-token* ]] || fail "install output leaked the Discord token"
backup=$(find "$TOOLBOX_STATE_DIR/native-notifications-backups" -mindepth 1 -maxdepth 1 -type d | head -n1)
[[ -n $backup && $(stat -c '%a' "$backup") == 700 ]] || fail "config backup is not private"
[[ $(<"$backup/priv/notifications.cfg") == private-before ]] \
    || fail "private native config was not backed up"
pass "Discord secrets stay protected and config is backed up"

_nt_configure >/dev/null || fail "repeated configuration failed"
[[ $(find "$API_ROOT/endpoints" -name '*.json' | wc -l) -eq 1 \
    && $(find "$API_ROOT/matchers" -name '*.json' | wc -l) -eq 1 ]] \
    || fail "repeated install duplicated owned objects"
[[ $(<"$TEST_COUNT_FILE") == 2 ]] || fail "repeated install skipped delivery testing"
pass "repeated configuration is idempotent"

before_target=$(<"$API_ROOT/endpoints/webhook.pve-toolbox-discord.json")
before_matcher=$(<"$API_ROOT/matchers/pve-toolbox-discord.json")
for file in "${NT_TEMPLATE_FILES[@]}"; do
    printf 'previous contents of %s\n' "$file" > "$NT_TEMPLATE_DIR/$file"
done
NT_MATCH_SEVERITY=info,warning,error
rc=0
failure_output=$(FAIL_TEST_DELIVERY=1 _nt_configure 2>&1) || rc=$?
[[ $rc -ne 0 ]] || fail "failed test delivery was accepted"
[[ $(<"$API_ROOT/endpoints/webhook.pve-toolbox-discord.json") == "$before_target" ]] \
    || fail "target was not rolled back after test failure"
[[ $(<"$API_ROOT/matchers/pve-toolbox-discord.json") == "$before_matcher" ]] \
    || fail "matcher was not rolled back after test failure"
[[ $failure_output != *super-secret-token* ]] || fail "failure output leaked a credential"
for file in "${NT_TEMPLATE_FILES[@]}"; do
    [[ $(<"$NT_TEMPLATE_DIR/$file") == "previous contents of $file" ]] \
        || fail "failed delivery did not restore $file"
done
_nt_install_assets || fail "could not resynchronize fixture assets"
pass "failed delivery restores owned endpoint, matcher, and previous template contents"

rc=0
rollback_failure=$(
    _nt_restore_assets() { return 1; }
    FAIL_TEST_DELIVERY=1 _nt_configure 2>&1
) || rc=$?
[[ $rc -ne 0 && $rollback_failure == *'asset rollback failed; asset backup retained at '* ]] \
    || fail "asset rollback failure was not reported"
[[ $rollback_failure != *'previous owned objects were restored'* ]] \
    || fail "asset rollback failure claimed successful restoration"
retained_backup=${rollback_failure##*asset backup retained at }
[[ -d $retained_backup && $(stat -c '%a' "$retained_backup") == 700 ]] \
    || fail "failed asset rollback did not retain a private backup"
for file in "${NT_TEMPLATE_FILES[@]}"; do
    cmp -s "$retained_backup/templates/$file" "$NT_TEMPLATE_DIR/$file" \
        || fail "retained backup is missing previous $file contents"
done
[[ $retained_backup == "${TMPDIR:-/tmp}/tmp."* && ! -L $retained_backup ]] \
    || fail "unexpected retained backup path"
rm -r -- "$retained_backup"
pass "asset rollback failure reports and retains its recovery backup"

# A same-named object without the module's ownership state must remain intact.
user_api="$WORK/user-api"
mkdir -p "$user_api/endpoints" "$user_api/matchers"
API_ROOT=$user_api
export API_ROOT
jq -n '{name:"pve-toolbox-discord",type:"webhook",comment:"created by operator",disable:0}' \
    > "$API_ROOT/endpoints/webhook.pve-toolbox-discord.json"
old_conf_dir=$TOOLBOX_CONF_DIR old_state_dir=$TOOLBOX_STATE_DIR old_bin_dir=$TOOLBOX_BIN_DIR
TOOLBOX_CONF_DIR="$WORK/user-conf" TOOLBOX_STATE_DIR="$WORK/user-state" TOOLBOX_BIN_DIR="$WORK/user-bin"
NT_TEMPLATE_DIR="$WORK/user-templates"
export TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR TOOLBOX_BIN_DIR NT_TEMPLATE_DIR
mkdir -p "$TOOLBOX_CONF_DIR" "$TOOLBOX_STATE_DIR" "$TOOLBOX_BIN_DIR" "$NT_TEMPLATE_DIR"
rc=0
( _nt_configure >/dev/null 2>&1 ) || rc=$?
[[ $rc -ne 0 ]] || fail "pre-existing user target was overwritten"
[[ $(jq -r .comment "$API_ROOT/endpoints/webhook.pve-toolbox-discord.json") == 'created by operator' ]] \
    || fail "pre-existing user target changed"
[[ ! -e $API_ROOT/matchers/pve-toolbox-discord.json ]] \
    || fail "matcher was created beside a conflicting target"
pass "pre-existing user-managed targets are preserved"

TOOLBOX_CONF_DIR=$old_conf_dir TOOLBOX_STATE_DIR=$old_state_dir TOOLBOX_BIN_DIR=$old_bin_dir
NT_TEMPLATE_DIR="$WORK/templates" API_ROOT="$WORK/api"
export TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR TOOLBOX_BIN_DIR NT_TEMPLATE_DIR API_ROOT
NT_MATCH_SEVERITY=warning,error

# Uninstall verifies ownership markers and leaves unrelated objects alone.
jq -n '{name:"operator-webhook",type:"webhook",comment:"created by operator",disable:0}' \
    > "$API_ROOT/endpoints/webhook.operator-webhook.json"
require_root() { :; }
rc=0
( FAIL_TARGET_DELETE=1 module_uninstall >/dev/null 2>&1 ) || rc=$?
[[ $rc -ne 0 ]] || fail "failed target deletion was accepted"
[[ -e $API_ROOT/endpoints/webhook.pve-toolbox-discord.json \
    && -e $API_ROOT/matchers/pve-toolbox-discord.json ]] \
    || fail "failed target deletion did not restore its matcher"
[[ -e $(conf_file native-notifications) \
    && -e $TOOLBOX_STATE_DIR/native-notifications.state ]] \
    || fail "failed uninstall cleared ownership records"
module_uninstall >/dev/null || fail "owned notification uninstall failed"
[[ ! -e $API_ROOT/endpoints/webhook.pve-toolbox-discord.json \
    && ! -e $API_ROOT/matchers/pve-toolbox-discord.json ]] \
    || fail "uninstall retained owned API objects"
[[ -e $API_ROOT/endpoints/webhook.operator-webhook.json ]] \
    || fail "uninstall removed a user-managed target"
pass "uninstall removes only owned objects"

NT_KIND=webhook NT_TARGET_NAME=pve-toolbox-hook NT_MATCHER_NAME=pve-toolbox-hook
NT_MATCH_SEVERITY=warning,error NT_MATCH_FIELD='' NT_MATCH_MODE=all
NT_WEBHOOK_URL='https://user:password@example.invalid/hook'
_nt_validate && fail "webhook URL credentials were accepted"
NT_WEBHOOK_URL='https://hooks.example.invalid/event' NT_WEBHOOK_SECRET_NAME='' \
    NT_WEBHOOK_SECRET_VALUE='secret'
_nt_validate && fail "generic webhook without a protected secret template was accepted"
NT_KIND=gotify NT_GOTIFY_SERVER='https://gotify.example.invalid' NT_GOTIFY_TOKEN=''
_nt_validate && fail "empty Gotify token was accepted"
NT_KIND=smtp NT_SMTP_SERVER='smtp.example.invalid' NT_SMTP_PORT=70000 \
    NT_SMTP_MODE=starttls NT_SMTP_MAILTO=ops@example.invalid NT_SMTP_FROM=pve@example.invalid
_nt_validate && fail "invalid SMTP port was accepted"
pass "invalid endpoints fail closed before API changes"
