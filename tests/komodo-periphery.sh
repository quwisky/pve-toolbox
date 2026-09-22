#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
[[ -f modules/komodo-periphery/module.sh ]] || fail 'module discovery missing'
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
export TOOLBOX_CONF_DIR="$WORK/conf" TOOLBOX_STATE_DIR="$WORK/state" TOOLBOX_BIN_DIR="$WORK/bin" TOOLBOX_SYSTEMD_DIR="$WORK/systemd"
mkdir -p "$WORK/doubles"
cat > "$WORK/doubles/pct" <<'CMD'
#!/bin/bash
printf 'unexpected guest call\n' >&2
exit 99
CMD
chmod +x "$WORK/doubles/pct"
export PATH="$WORK/doubles:$PATH"
[[ $(./pve-toolbox _complete modules) == *komodo-periphery* ]] || fail 'module missing from discovery'
[[ $(./pve-toolbox list lxc) == *komodo-periphery* ]] || fail 'module missing from tag'
if ./pve-toolbox -y install komodo-periphery > "$WORK/out" 2>&1; then fail 'noninteractive mutation permitted'; fi
if ./pve-toolbox --force update komodo-periphery > "$WORK/out" 2>&1; then fail 'force mutation permitted'; fi
if [[ $EUID == 0 ]]; then
    ./pve-toolbox check komodo-periphery > "$WORK/out"
    [[ $(cat "$WORK/out") == *'no managed containers'* ]] || fail 'empty check should be informative'
else
    if ./pve-toolbox check komodo-periphery > "$WORK/out" 2>&1; then
        fail 'check accepted a non-root-owned configuration directory'
    fi
fi
TOOLBOX_UPDATE_EXPLICIT=1 ./pve-toolbox update > "$WORK/out"
[[ ! -e $TOOLBOX_BIN_DIR/periphery ]] || fail 'installed agent on host'
printf 'ok Periphery discovery and noninteractive safeguards\n'
if [[ $EUID != 0 ]] || ! command -v expect >/dev/null; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'host integration requires root and expect'
    printf 'skip guest transport integration (root/expect required)\n'; exit 0
fi
source tests/fixtures/komodo-periphery/harness.sh
kp_fixture upstream-v2
kp_host_fixture
kp_confirm accept update komodo-periphery > "$KP_WORK/session" || { cat "$KP_WORK/session"; fail 'host update failed'; }
grep -q 2.3.3 "$KP_TEST_BINARY" || fail 'host did not update selected guest'
[[ -f $TOOLBOX_CONF_DIR/komodo-periphery.conf ]] || fail 'managed inventory not saved'
./pve-toolbox check komodo-periphery > "$KP_WORK/check"
./pve-toolbox --json status komodo-periphery > "$KP_WORK/status"
jq -e . "$KP_WORK/status" >/dev/null || fail 'invalid status JSON'
if grep -RFq fixture-secret "$TOOLBOX_STATE_DIR"; then fail 'secret in public state'; fi
kp_fixture absent
kp_host_fixture
kp_confirm decline install komodo-periphery > "$KP_WORK/session" || { cat "$KP_WORK/session"; fail 'decline failed'; }
[[ ! -e $KP_TEST_BINARY && ! -e $KP_TEST_ROOT/var/lib/pve-toolbox ]] || fail 'decline changed guest'
kp_confirm accept install komodo-periphery > "$KP_WORK/session" || { cat "$KP_WORK/session"; fail 'host installation failed'; }
[[ -f $KP_TEST_CONFIG ]] || fail 'configuration missing'
if grep -Rq fixture-secret "$KP_WORK/session" "$TOOLBOX_STATE_DIR"; then fail 'secret leaked'; fi
kp_confirm accept uninstall komodo-periphery > "$KP_WORK/session" || { cat "$KP_WORK/session"; fail 'host uninstall failed'; }
[[ ! -e $KP_TEST_BINARY && -f $KP_TEST_CONFIG ]] || fail 'host uninstall violated retention'
kp_fixture upstream-v2
kp_host_fixture
: > "$KP_TEST_ROOT/move-after-push"
if kp_confirm accept update komodo-periphery > "$KP_WORK/session"; then fail 'moved guest updated'; fi
if grep -q '^apply' "$KP_HOST_CALLS"; then fail 'apply ran after migration'; fi
printf 'ok real launcher through controlled PVE transport\n'
kp_fixture upstream-v2
kp_host_fixture
mkdir -p "$TOOLBOX_CONF_DIR"
printf 'touch %q\n' "$KP_WORK/unsafe-source" > "$TOOLBOX_CONF_DIR/komodo-periphery-101.conf"
chown 1000:1000 "$TOOLBOX_CONF_DIR/komodo-periphery-101.conf"
if kp_confirm accept update komodo-periphery > "$KP_WORK/session"; then fail 'untrusted host config accepted'; fi
[[ ! -e $KP_WORK/unsafe-source ]] || fail 'untrusted host config was sourced'
printf "KP_IDS='101'\n" > "$TOOLBOX_CONF_DIR/komodo-periphery.conf"
./pve-toolbox check komodo-periphery > "$KP_WORK/check-unsafe" 2>&1 || true
[[ ! -e $KP_WORK/unsafe-source ]] || fail 'read-only check sourced untrusted host config'
# A host-write failure can leave a completed guest transaction to reconcile.
kp_fixture upstream-v2
kp_host_fixture
kp_confirm accept update komodo-periphery > "$KP_WORK/session" || fail 'reconciliation setup failed'
transaction=$(jq -r .transaction_id "$KP_TEST_ROOT/var/lib/pve-toolbox/komodo-periphery/committed.json")
source lib/common.sh
conf_set komodo-periphery-101 KP_PENDING "$transaction"
kp_confirm accept update komodo-periphery > "$KP_WORK/session" || fail 'reconciliation failed'
[[ -z $(conf_get komodo-periphery-101 KP_PENDING) ]] || fail 'completed reconciliation left host pending forever'
kp_confirm accept uninstall komodo-periphery > "$KP_WORK/session" || fail 'operation after reconciliation failed'
[[ ! -f $KP_TEST_BINARY ]] || fail 'reconciliation blocked later uninstall'

kp_fixture absent
kp_host_fixture
if kp_confirm cancel install komodo-periphery > "$KP_WORK/session"; then fail 'cancelled install succeeded'; fi
[[ ! -e $KP_TEST_BINARY ]] || fail 'cancelled preview installed binary'
printf 'ok host reconciliation, trust checks and cancellation\n'
# Updating or removing one guest's registration must retain the other guest.
kp_fixture absent
kp_host_fixture
source modules/komodo-periphery/host.sh
kp_host_save 101 2.3.3 identity-one fingerprint-one install
kp_host_save 102 2.3.2 identity-two fingerprint-two install
kp_host_save 101 2.3.3 identity-one fingerprint-one uninstall
[[ $(conf_get komodo-periphery KP_IDS) == 102 ]] || fail 'uninstall removed another managed target'
[[ $(conf_get komodo-periphery-102 KP_VERSION) == 2.3.2 && $(state_get komodo-periphery-102 fingerprint) == fingerprint-two ]] || fail 'other guest state changed'
printf 'ok independent managed-container records\n'
