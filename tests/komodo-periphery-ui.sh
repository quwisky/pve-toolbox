#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 ]] || ! command -v expect >/dev/null || ! command -v whiptail >/dev/null; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'Periphery UI tests require root, expect, whiptail'
    printf 'skip Periphery terminal tests (root/expect/whiptail required)\n'; exit 0
fi
export TERM=xterm
source tests/fixtures/komodo-periphery/harness.sh
export KP_ROW
KP_ROW=$(./pve-toolbox _complete modules | awk '$0=="komodo-periphery" { print NR }')
for mode in plain ui; do
    kp_fixture absent
    kp_host_fixture
    command=menu
    [[ $mode != ui ]] || command=ui
    if [[ -n ${KP_CAPTURE_DIR:-} ]]; then mkdir -p "$KP_CAPTURE_DIR"; export KP_CAPTURE="$KP_CAPTURE_DIR/$mode.log"; fi
    expect tests/fixtures/komodo-periphery/drive.exp "$mode" ./pve-toolbox "$command" > "$KP_WORK/ui-output" || { cat "$KP_WORK/ui-output"; fail "$mode install failed"; }
    [[ -f $KP_TEST_BINARY ]] || { cat "$KP_WORK/ui-output"; fail "$mode did not install agent"; }
done
if [[ -n ${KP_CAPTURE_DIR:-} ]]; then export KP_CAPTURE="$KP_CAPTURE_DIR/update-default.log"; fi
# One installed guest module: pressing Enter on update must not select it.
expect tests/fixtures/komodo-periphery/drive.exp ui-default ./pve-toolbox ui > "$KP_WORK/ui-output" || { cat "$KP_WORK/ui-output"; fail 'default update selection unsafe'; }
printf 'ok Periphery plain and full-screen flows, explicit update selection\n'
