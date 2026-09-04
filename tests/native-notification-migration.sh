#!/usr/bin/env bash
# Upgrade fixtures for transferring legacy notification objects to PVE ownership.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

write_fake_pvesh() {
    local bin=$1
    cat > "$bin/pvesh" <<'PVESH'
#!/usr/bin/env bash
set -euo pipefail
action=${1:-} path=${2:-}
shift 2 || true
printf '%s\t%s\n' "$action" "$path" >> "$PVE_TOOLBOX_PVESH_LOG"
case "$action:$path" in
    get:/cluster/notifications/endpoints/*/*)
        rest=${path#/cluster/notifications/endpoints/}
        type=${rest%%/*}
        name=${rest#*/}
        cat -- "$PVE_TOOLBOX_API_ROOT/endpoints/$type.$name.json"
        ;;
    get:/cluster/notifications/matchers/*)
        name=${path##*/}
        cat -- "$PVE_TOOLBOX_API_ROOT/matchers/$name.json"
        ;;
    create:/cluster/notifications/targets/*/test)
        [[ ${PVE_TOOLBOX_FAIL_TARGET_TEST:-0} -eq 0 ]] || exit 5
        count=0
        [[ ! -f $PVE_TOOLBOX_TEST_COUNT ]] || count=$(<"$PVE_TOOLBOX_TEST_COUNT")
        printf '%s\n' "$((count + 1))" > "$PVE_TOOLBOX_TEST_COUNT"
        ;;
    *) exit 64 ;;
esac
PVESH
    chmod 0755 "$bin/pvesh"
}

asset_sum() {
    local helper=$1 template_dir=$2 file
    {
        sha256sum "$helper"
        for file in pve-toolbox-subject.txt.hbs pve-toolbox-body.txt.hbs \
            pve-toolbox-body.html.hbs; do
            sha256sum "$template_dir/$file"
        done
    } | sha256sum | awk '{print $1}'
}

setup_case() { # setup_case <case-dir> <kind> <api-type> <disable>
    local case_dir=$1 kind=$2 api_type=$3 disable=$4 file sum
    local target="pve-toolbox-$kind" matcher="pve-toolbox-$kind"
    mkdir -p "$case_dir"/{api/endpoints,api/matchers,bin,config,state,backups,run,migrations,templates}
    cp -- "$ROOT/migrations/010-native-notification-ownership.sh" "$case_dir/migrations/"
    chmod 0644 "$case_dir/migrations/010-native-notification-ownership.sh"
    write_fake_pvesh "$case_dir/bin"
    cat > "$case_dir/bin/pve-toolbox-native-notify" <<'NOTIFY'
#!/usr/bin/env bash
set -euo pipefail
[[ ${PVE_TOOLBOX_FAIL_CUSTOM_EVENT:-0} -eq 0 ]] || exit 7
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$PVE_TOOLBOX_HELPER_LOG"
NOTIFY
    chmod 0755 "$case_dir/bin/pve-toolbox-native-notify"
    cp -- "$case_dir/bin/pve-toolbox-native-notify" "$case_dir/bin/legacy-native-notify"
    chmod 0755 "$case_dir/bin/legacy-native-notify"
    for file in pve-toolbox-subject.txt.hbs pve-toolbox-body.txt.hbs \
        pve-toolbox-body.html.hbs; do
        printf '%s\n' "template $file" > "$case_dir/templates/$file"
    done
    sum=$(asset_sum "$case_dir/bin/legacy-native-notify" "$case_dir/templates")
    {
        printf 'NT_KIND=%q\n' "$kind"
        printf 'NT_TARGET_NAME=%q\n' "$target"
        printf 'NT_MATCHER_NAME=%q\n' "$matcher"
        printf 'NT_DISCORD_WEBHOOK=%q\n' 'https://discord.com/api/webhooks/123/protected-token'
        printf 'NT_GOTIFY_TOKEN=%q\n' 'protected-gotify-token'
        printf 'NT_SMTP_PASSWORD=%q\n' 'protected-smtp-password'
        printf 'NT_WEBHOOK_SECRET_VALUE=%q\n' 'protected-webhook-secret'
    } > "$case_dir/config/native-notifications.conf"
    chmod 0600 "$case_dir/config/native-notifications.conf"
    {
        printf 'TARGET_TYPE=%q\n' "$api_type"
        printf 'TARGET_NAME=%q\n' "$target"
        printf 'MATCHER_NAME=%q\n' "$matcher"
        printf 'ASSET_SUM=%q\n' "$sum"
        printf 'INSTALLED_AT=%q\n' '2026-09-01T12:00:00+00:00'
    } > "$case_dir/state/native-notifications.state"
    chmod 0644 "$case_dir/state/native-notifications.state"
    case $kind in
        discord|webhook)
            jq -n --arg name "$target" --argjson disable "$disable" \
                '{name:$name,comment:"managed by pve-toolbox/native-notifications",
                  disable:$disable,url:"https://example.invalid/{{ secrets.token }}",
                  method:"post",header:["name=Authorization,value=protected-reference"]}'
            ;;
        gotify)
            jq -n --arg name "$target" --argjson disable "$disable" \
                '{name:$name,comment:"managed by pve-toolbox/native-notifications",
                  disable:$disable,server:"https://gotify.example.invalid"}'
            ;;
        smtp)
            jq -n --arg name "$target" --argjson disable "$disable" \
                '{name:$name,comment:"managed by pve-toolbox/native-notifications",
                  disable:$disable,server:"smtp.example.invalid",port:587,
                  mode:"starttls",mailto:["ops@example.invalid"],
                  "from-address":"pve@example.invalid",username:"pve"}'
            ;;
    esac > "$case_dir/api/endpoints/$api_type.$target.json"
    jq -n --arg name "$matcher" --arg target "$target" --argjson disable "$disable" \
        '{name:$name,comment:"managed by pve-toolbox/native-notifications",
          disable:$disable,target:[$target],"match-severity":["warning","error"],
          "match-field":["exact:type=pve-toolbox"],mode:"all"}' \
        > "$case_dir/api/matchers/$matcher.json"
    printf '%s\n' "protected credential for $kind" \
        > "$case_dir/api/endpoints/$api_type.$target.private"
    chmod 0600 "$case_dir/api/endpoints/$api_type.$target.private"
}

run_case() { # run_case <case-dir> [runner environment...]
    local case_dir=$1
    shift
    env \
        PATH="$case_dir/bin:$PATH" \
        PVE_TOOLBOX_MIGRATION_DIR="$case_dir/migrations" \
        PVE_TOOLBOX_CONF_DIR="$case_dir/config" \
        PVE_TOOLBOX_STATE_DIR="$case_dir/state" \
        PVE_TOOLBOX_MIGRATION_BACKUP_DIR="$case_dir/backups" \
        PVE_TOOLBOX_RUN_DIR="$case_dir/run" \
        PVE_TOOLBOX_NATIVE_NOTIFY_BIN="$case_dir/bin/pve-toolbox-native-notify" \
        PVE_TOOLBOX_LEGACY_NATIVE_NOTIFY_BIN="$case_dir/bin/legacy-native-notify" \
        PVE_TOOLBOX_NOTIFICATION_TEMPLATE_DIR="$case_dir/templates" \
        PVE_TOOLBOX_API_ROOT="$case_dir/api" \
        PVE_TOOLBOX_PVESH_LOG="$case_dir/pvesh.log" \
        PVE_TOOLBOX_TEST_COUNT="$case_dir/test-count" \
        PVE_TOOLBOX_HELPER_LOG="$case_dir/helper.log" \
        "$@" "$ROOT/scripts/run-migrations.sh" 0.6.0
}

for fixture in discord:webhook:0 webhook:webhook:1 gotify:gotify:0 smtp:smtp:1; do
    IFS=: read -r kind api_type disable <<<"$fixture"
    case_dir="$WORK/$kind"
    setup_case "$case_dir" "$kind" "$api_type" "$disable"
    target="pve-toolbox-$kind"
    before_endpoint=$(sha256sum "$case_dir/api/endpoints/$api_type.$target.json")
    before_matcher=$(sha256sum "$case_dir/api/matchers/$target.json")
    before_private=$(sha256sum "$case_dir/api/endpoints/$api_type.$target.private")
    run_case "$case_dir" >/dev/null || fail "$kind ownership migration failed"
    [[ ! -e $case_dir/config/native-notifications.conf \
        && ! -e $case_dir/state/native-notifications.state ]] \
        || fail "$kind migration retained toolbox ownership files"
    [[ $(sha256sum "$case_dir/api/endpoints/$api_type.$target.json") == "$before_endpoint" \
        && $(sha256sum "$case_dir/api/matchers/$target.json") == "$before_matcher" \
        && $(sha256sum "$case_dir/api/endpoints/$api_type.$target.private") == "$before_private" ]] \
        || fail "$kind migration changed native PVE notification data"
    [[ $(<"$case_dir/test-count") == 1 ]] || fail "$kind migration skipped target delivery"
    grep -Fq $'notice\tpve-toolbox migration\t' "$case_dir/helper.log" \
        || fail "$kind migration skipped the package-owned custom sender"
    grep -Fxq 010-native-notification-ownership "$case_dir/state/migrations.state" \
        || fail "$kind migration was not recorded"
    run_case "$case_dir" >/dev/null || fail "$kind repeat execution failed"
    [[ $(<"$case_dir/test-count") == 1 \
        && $(wc -l < "$case_dir/helper.log") -eq 1 ]] \
        || fail "$kind migration reran after completion"
done
pass "all legacy endpoint types transfer without changing PVE data or credentials"
pass "completed notification migration is idempotent"

conflict="$WORK/conflict"
setup_case "$conflict" discord webhook 0
jq '.comment = "managed by operator"' \
    "$conflict/api/endpoints/webhook.pve-toolbox-discord.json" \
    > "$conflict/api/foreign.json"
mv -- "$conflict/api/foreign.json" \
    "$conflict/api/endpoints/webhook.pve-toolbox-discord.json"
before_conflict=$(sha256sum "$conflict/api/endpoints/webhook.pve-toolbox-discord.json")
conflict_output=""
conflict_rc=0
conflict_output=$(run_case "$conflict" 2>&1) || conflict_rc=$?
[[ $conflict_rc -ne 0 && $conflict_output == *'foreign or ambiguous'* ]] \
    || fail "foreign target did not stop with operator guidance"
[[ -f $conflict/config/native-notifications.conf \
    && -f $conflict/state/native-notifications.state \
    && $(sha256sum "$conflict/api/endpoints/webhook.pve-toolbox-discord.json") == "$before_conflict" ]] \
    || fail "foreign target conflict changed legacy or PVE data"
[[ ! -e $conflict/test-count && ! -e $conflict/helper.log ]] \
    || fail "foreign target conflict attempted delivery"
pass "foreign notification objects stop without mutation"

identity="$WORK/identity"
setup_case "$identity" smtp smtp 0
sed -i 's/^TARGET_TYPE=.*/TARGET_TYPE=gotify/' \
    "$identity/state/native-notifications.state"
identity_output=""
identity_rc=0
identity_output=$(run_case "$identity" 2>&1) || identity_rc=$?
[[ $identity_rc -ne 0 && $identity_output == *'recorded ownership does not match'* \
    && -f $identity/config/native-notifications.conf \
    && -f $identity/state/native-notifications.state \
    && ! -e $identity/test-count ]] \
    || fail "mismatched ownership identity did not stop before delivery"
pass "recorded ownership identity must match before migration"

rollback="$WORK/rollback"
setup_case "$rollback" gotify gotify 0
before_config=$(sha256sum "$rollback/config/native-notifications.conf")
before_state=$(sha256sum "$rollback/state/native-notifications.state")
before_api=$(find "$rollback/api" -type f -exec sha256sum {} + | LC_ALL=C sort)
rollback_output=""
rollback_rc=0
rollback_output=$(run_case "$rollback" PVE_TOOLBOX_FAIL_TARGET_TEST=1 2>&1) || rollback_rc=$?
[[ $rollback_rc -ne 0 && $rollback_output == *'test delivery'* \
    && $rollback_output == *'legacy ownership was preserved'* ]] \
    || fail "delivery failure did not report preserved ownership"
[[ $(sha256sum "$rollback/config/native-notifications.conf") == "$before_config" \
    && $(sha256sum "$rollback/state/native-notifications.state") == "$before_state" \
    && $(find "$rollback/api" -type f -exec sha256sum {} + | LC_ALL=C sort) == "$before_api" ]] \
    || fail "delivery failure did not restore the pre-migration state"
[[ ! -e $rollback/state/migrations.state ]] \
    || fail "failed notification migration was recorded as complete"
backup_config=$(find "$rollback/backups" \
    -path '*/files/*/native-notifications.conf' -type f -print -quit)
[[ -n $backup_config \
    && $(sha256sum "$backup_config" | awk '{print $1}') == "${before_config%% *}" ]] \
    || fail "failed notification migration did not retain its config backup"
[[ $rollback_output != *protected-gotify-token* ]] \
    || fail "failed migration leaked a protected credential"
pass "delivery failure rolls back without exposing credentials"

custom_failure="$WORK/custom-failure"
setup_case "$custom_failure" smtp smtp 1
custom_output=""
custom_rc=0
custom_output=$(run_case "$custom_failure" PVE_TOOLBOX_FAIL_CUSTOM_EVENT=1 2>&1) || custom_rc=$?
[[ $custom_rc -ne 0 && $custom_output == *'custom-event sender failed'* \
    && -f $custom_failure/config/native-notifications.conf \
    && -f $custom_failure/state/native-notifications.state ]] \
    || fail "custom sender failure retired legacy ownership"
pass "custom sender must work before ownership is retired"
