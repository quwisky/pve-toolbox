#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 ]]; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'configuration tests require root'
    printf 'skip Periphery configuration tests (root required)\n'; exit 0
fi
source tests/fixtures/komodo-periphery/harness.sh
config_fixture() {
    kp_fixture upstream-v2
    kp_guest_python
    cat > "$KP_TEST_CONFIG" <<'CONFIG'
# operator comment
core_address = "https://old.example.invalid"  # operator URL note
connect_as = 'old#name' # operator name note
onboarding_key = "existing-secret" # enrollment note
root_directory = "/etc/komodo"
server_enabled = false
[logging]
level = "debug"
CONFIG
    chmod 0600 "$KP_TEST_CONFIG"
}
config_request() {
    local inspected
    kp_request update
    inspected=$(kp_guest inspect)
    jq --arg hash "$(jq -r .config_fingerprint <<<"$inspected")" \
        '.action="configure" | .version="2.3.2" | .config_fingerprint=$hash |
         .core_url="http://new.example.invalid:9120/path" | .server_name="new-name" |
         .onboarding_key_action="keep" | .onboarding_key=""' \
        "$KP_TEST_ROOT$KP_TEST_REQUEST" > "$KP_TEST_ROOT/new-request.json"
    mv "$KP_TEST_ROOT/new-request.json" "$KP_TEST_ROOT$KP_TEST_REQUEST"
    chmod 0600 "$KP_TEST_ROOT$KP_TEST_REQUEST"
}
patch_request() {
    jq "$@" "$KP_TEST_ROOT$KP_TEST_REQUEST" > "$KP_TEST_ROOT/new-request.json"
    mv "$KP_TEST_ROOT/new-request.json" "$KP_TEST_ROOT$KP_TEST_REQUEST"
    chmod 0600 "$KP_TEST_ROOT$KP_TEST_REQUEST"
}
config_fixture
config_request
binary_before=$(sha256sum "$KP_TEST_BINARY")
unit_before=$(sha256sum "$KP_TEST_ROOT/etc/systemd/system/periphery.service")
key_before=$(sha256sum "$KP_TEST_ROOT/etc/komodo/keys/periphery.key")
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'configuration-only update failed'
grep -Fq 'core_address = "http://new.example.invalid:9120/path"' "$KP_TEST_CONFIG" || fail 'Core URL not updated'
grep -Fq 'connect_as = "new-name"' "$KP_TEST_CONFIG" || fail 'server name not updated'
grep -Fq 'onboarding_key = "existing-secret"' "$KP_TEST_CONFIG" || fail 'existing onboarding key not preserved'
grep -Fq '# operator comment' "$KP_TEST_CONFIG" || fail 'comment lost'
grep -Fq '  # operator URL note' "$KP_TEST_CONFIG" || fail 'inline URL comment lost'
grep -Fq '# operator name note' "$KP_TEST_CONFIG" || fail 'quoted hash confused inline comment parsing'
grep -Fq 'level = "debug"' "$KP_TEST_CONFIG" || fail 'unrelated setting lost'
[[ $(stat -c %a "$KP_TEST_CONFIG") == 600 ]] || fail 'configuration permissions changed'
[[ $(sha256sum "$KP_TEST_BINARY") == "$binary_before" && $(sha256sum "$KP_TEST_ROOT/etc/systemd/system/periphery.service") == "$unit_before" && $(sha256sum "$KP_TEST_ROOT/etc/komodo/keys/periphery.key") == "$key_before" ]] || fail 'configuration update changed agent files'
printf 'ok configuration-only update preserves agent, identity and unrelated settings\n'
config_fixture
kp_host_fixture
binary_before=$(sha256sum "$KP_TEST_BINARY")
KP_CORE_URL=http://host-flow.example.invalid:9120 kp_confirm configure install komodo-periphery > "$KP_WORK/session" || { cat "$KP_WORK/session"; fail 'host configuration update failed'; }
[[ $(sha256sum "$KP_TEST_BINARY") == "$binary_before" ]] || fail 'host configuration updated executable'
grep -Fq 'core_address = "http://host-flow.example.invalid:9120"' "$KP_TEST_CONFIG" || fail 'host configuration URL not saved'
if grep -q '^curl ' "$KP_HOST_CALLS"; then fail 'configuration update downloaded a release'; fi
if grep -Rq existing-secret "$KP_WORK/session" "$TOOLBOX_STATE_DIR"; then fail 'configuration flow exposed existing credentials'; fi
printf 'ok configuration-only host flow avoids binary downloads\n'
for action in replace remove; do
    config_fixture
    config_request
    patch_request --arg action "$action" '.onboarding_key_action=$action | .onboarding_key="replacement-secret"'
    kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'onboarding key edit failed'
    if [[ $action == replace ]]; then
        grep -Fq 'onboarding_key = "replacement-secret"' "$KP_TEST_CONFIG" || fail 'replacement key missing'
    elif grep -q onboarding_key "$KP_TEST_CONFIG"; then fail 'onboarding key not removed'; fi
    grep -Fq '# enrollment note' "$KP_TEST_CONFIG" || fail 'key edit removed inline comment'
    grep -Fq private-identity "$KP_TEST_ROOT/etc/komodo/keys/periphery.key" || fail 'key edit changed agent identity'
done
config_fixture
config_request
patch_request '.core_url="" | .server_name=""'
before=$(sha256sum "$KP_TEST_CONFIG")
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'unchanged configuration rejected'
[[ $(sha256sum "$KP_TEST_CONFIG") == "$before" ]] || fail 'unchanged configuration rewritten'
kp_assert_no_guest_mutation
config_fixture
config_request
printf 'inactive\n' > "$KP_TEST_ROOT/active"
printf 'disabled\n' > "$KP_TEST_ROOT/enabled"
chown 0:1234 "$KP_TEST_CONFIG"
chmod 0640 "$KP_TEST_CONFIG"
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'inactive configuration update failed'
[[ $(stat -c '%u:%g:%a' "$KP_TEST_CONFIG") == 0:1234:640 ]] || fail 'configuration access metadata changed'
[[ $(cat "$KP_TEST_ROOT/active") == inactive && $(cat "$KP_TEST_ROOT/enabled") == disabled ]] || fail 'configuration edit changed service policy'
kp_assert_no_guest_mutation
printf 'ok key replacement/removal, unchanged config and service policy\n'
for scenario in malformed ambiguous stale missing-python; do
    config_fixture
    case $scenario in
        malformed) printf '\nbroken = [\n' >> "$KP_TEST_CONFIG" ;;
        ambiguous) printf '\n[nested]\ncore_address = "nested-value"\n' >> "$KP_TEST_CONFIG" ;;
        missing-python) rm "$KP_TEST_ROOT/usr/bin/python3" ;;
    esac
    config_request
    if [[ $scenario == stale ]]; then printf '\n# changed since preview\n' >> "$KP_TEST_CONFIG"; fi
    before=$(sha256sum "$KP_TEST_CONFIG")
    if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail "$scenario configuration accepted"; fi
    [[ $(sha256sum "$KP_TEST_CONFIG") == "$before" ]] || fail 'rejected edit changed configuration'
    kp_assert_no_guest_mutation
done
printf 'ok unsafe or stale configuration edits leave service and files untouched\n'
config_fixture
config_request
before=$(sha256sum "$KP_TEST_CONFIG")
: > "$KP_TEST_ROOT/fail-config-start"
printf '{"MESSAGE":"Configuration rejected by agent"}\n' > "$KP_TEST_ROOT/startup-journal"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'failed config restart succeeded'; fi
[[ $(sha256sum "$KP_TEST_CONFIG") == "$before" && $(cat "$KP_TEST_ROOT/active") == active ]] || fail 'configuration restart failure did not restore service'
jq -e '.rollback=="restored" and (.diagnostics.journal|index("Configuration rejected by agent")!=null)' "$KP_TEST_ROOT/out" >/dev/null || fail 'configuration failure lost diagnostics or rollback result'
printf 'ok configuration restart failure restores prior config and reports original diagnostics\n'
config_fixture
mkdir -p "$KP_TEST_ROOT/opt/periphery"
mv "$KP_TEST_CONFIG" "$KP_TEST_ROOT/opt/periphery/config.toml"
KP_TEST_CONFIG=$KP_TEST_ROOT/opt/periphery/config.toml
sed -i 's@/etc/komodo/periphery.config.toml@/opt/periphery/config.toml@g' "$KP_TEST_ROOT/etc/systemd/system/periphery.service"
: > "$KP_TEST_ROOT/custom-config"
config_request
before=$(sha256sum "$KP_TEST_CONFIG")
: > "$KP_TEST_ROOT/crash-start"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" 2>/dev/null; then fail 'configuration crash succeeded'; fi
[[ -f $KP_TEST_ROOT/var/lib/pve-toolbox/komodo-periphery/pending.json ]] || fail 'configuration crash lost recovery record'
rm "$KP_TEST_ROOT/crash-start"
kp_guest recover aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || fail 'custom configuration recovery failed'
[[ $(sha256sum "$KP_TEST_CONFIG") == "$before" && $(cat "$KP_TEST_ROOT/active") == active ]] || fail 'custom configuration was not restored after crash'
printf 'ok crash recovery restores the original custom configuration path\n'
