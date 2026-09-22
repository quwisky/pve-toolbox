#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 ]]; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'guest tests require root/chroot'
    printf 'skip Periphery guest tests (root/chroot required)\n'; exit 0
fi
[[ -f modules/komodo-periphery/guest.sh ]] || fail 'guest inspection missing'
source tests/fixtures/komodo-periphery/harness.sh
kp_fixture absent
out=$(kp_guest inspect)
jq -e '.layout == "absent"' <<<"$out" >/dev/null || fail 'absent layout not detected'
kp_fixture upstream-v2
out=$(kp_guest inspect)
jq -e '.layout == "supported" and .version == "2.3.2" and .binary == "/usr/local/bin/periphery"' <<<"$out" >/dev/null || fail "upstream layout rejected: $out"
kp_assert_no_guest_mutation
for scenario in shell-injection package-owned v1; do
    kp_fixture "$scenario"
    out=$(kp_guest inspect)
    jq -e '.layout == "unsupported"' <<<"$out" >/dev/null || fail "$scenario accepted"
    [[ ! -e $KP_TEST_ROOT/tmp/injected ]] || fail 'unit executed'
done
kp_fixture custom-direct-v2
out=$(kp_guest inspect)
jq -e '.layout == "supported" and .binary == "/opt/custom path/periphery"' <<<"$out" >/dev/null || fail "custom path rejected: $out"
printf 'ok Periphery guest inspection\n'
kp_fixture upstream-v2
kp_request update
old_config=$(sha256sum "$KP_TEST_CONFIG")
old_key=$(sha256sum "$KP_TEST_ROOT/etc/komodo/keys/periphery.key")
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'existing update failed'
[[ $(sha256sum "$KP_TEST_CONFIG") == "$old_config" ]] || fail 'config changed'
[[ $(sha256sum "$KP_TEST_ROOT/etc/komodo/keys/periphery.key") == "$old_key" ]] || fail 'identity changed'
grep -q 2.3.3 "$KP_TEST_BINARY" || fail 'binary not updated'
jq -e '.result == "success"' "$KP_TEST_ROOT/out" >/dev/null || fail 'missing success outcome'
kp_fixture upstream-v2
kp_request update
: > "$KP_TEST_ROOT/fail-new-start"
old_binary=$(sha256sum "$KP_TEST_BINARY")
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'failed startup succeeded'; fi
[[ $(sha256sum "$KP_TEST_BINARY") == "$old_binary" ]] || fail 'previous binary not restored'
jq -e '.rollback == "restored"' "$KP_TEST_ROOT/out" >/dev/null || fail 'rollback not reported'
kp_fixture absent
kp_request install
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'fresh install failed'
[[ $(stat -c %a "$KP_TEST_CONFIG") == 600 ]] || fail 'configuration not protected'
grep -q 'server_enabled = false' "$KP_TEST_CONFIG" || fail 'inbound mode not disabled'
kp_request uninstall
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'uninstall failed'
[[ ! -e $KP_TEST_BINARY && -f $KP_TEST_CONFIG ]] || fail 'uninstall retention violated'
printf 'ok guest installation, update, rollback and uninstall\n'
# A binary checksum error must occur before the service stops.
kp_fixture upstream-v2
kp_request update
printf 'tampered' >> "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/periphery"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'tampered release accepted'; fi
kp_assert_no_guest_mutation
for active in active inactive; do
    for enabled in enabled disabled; do
        kp_fixture upstream-v2
        printf '%s\n' "$active" > "$KP_TEST_ROOT/active"
        printf '%s\n' "$enabled" > "$KP_TEST_ROOT/enabled"
        kp_request update
        kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" || fail 'policy-preserving update failed'
        [[ $(cat "$KP_TEST_ROOT/active") == "$active" && $(cat "$KP_TEST_ROOT/enabled") == "$enabled" ]] || fail 'service policy changed'
    done
done
kp_fixture upstream-v2
kp_request update
: > "$KP_TEST_ROOT/crash-start"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" 2>/dev/null; then fail 'simulated crash returned success'; fi
[[ -f $KP_TEST_ROOT/var/lib/pve-toolbox/komodo-periphery/pending.json ]] || fail 'crash lost journal'
rm "$KP_TEST_ROOT/crash-start"
kp_guest recover aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa || fail 'crash recovery failed'
grep -q 2.3.2 "$KP_TEST_BINARY" || fail 'recovery did not restore old version'
# Ownership manifest must roll back with binary after a later write fails.
kp_fixture upstream-v2
kp_request update
kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"
owner_before=$(sha256sum "$KP_TEST_ROOT/var/lib/pve-toolbox/komodo-periphery/owner.json")
kp_request update
sed -i s/2.3.3/2.3.4/ "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/periphery"
sha=$(sha256sum "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/periphery" | cut -d ' ' -f1)
jq --arg sha "$sha" '.version="2.3.4"|.asset_sha256=$sha' "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json" > "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/new.json"
mv "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/new.json" "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
chmod 600 "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
: > "$KP_TEST_ROOT/fail-commit"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'commit fault not propagated'; fi
[[ $(sha256sum "$KP_TEST_ROOT/var/lib/pve-toolbox/komodo-periphery/owner.json") == "$owner_before" ]] || fail 'owner manifest not rolled back'
printf 'ok guest checksum, service policies and crash recovery\n'
# Refuse executable paths introduced through a tampered request.
kp_fixture upstream-v2
kp_request update
jq '.staged_binary="/usr/local/bin/periphery" | .version="2.3.2"' "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json" > "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/new.json"
mv "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/new.json" "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
chmod 0600 "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
sha=$(sha256sum "$KP_TEST_BINARY" | cut -d ' ' -f1)
jq --arg sha "$sha" '.asset_sha256=$sha' "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json" > "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/new.json"
mv "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/new.json" "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
chmod 0600 "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out"; then fail 'unstaged candidate accepted'; fi
kp_assert_no_guest_mutation
# Corruption of a required backup must not be mistaken for original absence.
kp_fixture upstream-v2
kp_request update
: > "$KP_TEST_ROOT/crash-start"
if kp_guest apply "$KP_TEST_REQUEST" > "$KP_TEST_ROOT/out" 2>/dev/null; then fail 'crash did not occur'; fi
rm "$KP_TEST_ROOT/crash-start" "$KP_TEST_ROOT/var/lib/pve-toolbox/komodo-periphery/transaction/unit"
: > "$KP_TEST_LOG"
unit_before=$(sha256sum "$KP_TEST_ROOT/etc/systemd/system/periphery.service")
if kp_guest recover aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then fail 'missing required backup accepted'; fi
[[ $(sha256sum "$KP_TEST_ROOT/etc/systemd/system/periphery.service") == "$unit_before" ]] || fail 'backup corruption deleted unit'
kp_assert_no_guest_mutation
