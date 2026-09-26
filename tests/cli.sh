#!/usr/bin/env bash
#
# Command-line interface: help, flag validation, suggestions, colour,
# listing and configuration display. Everything runs against throwaway
# directories; nothing reaches the host.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
tmp() { mktemp -d "$WORK/XXXXXX"; }

launch() { # launch [args...] -> runs ./pve-toolbox against throwaway dirs
    TOOLBOX_BIN_DIR=$(tmp) TOOLBOX_STATE_DIR=$(tmp) \
    TOOLBOX_SYSTEMD_DIR=$(tmp) TOOLBOX_CONF_DIR=$(tmp) \
    ./pve-toolbox "$@"
}

ESC=$'\e['

# pty <command-string> -> run inside script(1) so stdout and stderr are ttys
pty() { script -qec "$1" /dev/null; }

# --- colour -------------------------------------------------------------------

out=$(launch definitely-not-a-command 2>&1 || true)
[[ $out != *"$ESC"* ]] || fail "colour escapes reached a pipe"
out=$(pty "cd '$ROOT' && TOOLBOX_CONF_DIR='$(tmp)' ./pve-toolbox definitely-not-a-command" || true)
[[ $out == *"$ESC"* ]] || fail "no colour on a terminal"
out=$(pty "cd '$ROOT' && NO_COLOR=1 ./pve-toolbox definitely-not-a-command" || true)
[[ $out != *"$ESC"* ]] || fail "NO_COLOR ignored"
out=$(pty "cd '$ROOT' && NO_COLOR=1 ./pve-toolbox --color=always definitely-not-a-command" || true)
[[ $out == *"$ESC"* ]] || fail "--color=always did not beat NO_COLOR"
out=$(pty "cd '$ROOT' && ./pve-toolbox --color=never definitely-not-a-command" || true)
[[ $out != *"$ESC"* ]] || fail "--color=never ignored"
out=$(pty "cd '$ROOT' && TERM=dumb ./pve-toolbox definitely-not-a-command" || true)
[[ $out != *"$ESC"* ]] || fail "TERM=dumb still coloured"
# stdout redirected away, stderr still the terminal: the error line is coloured.
out=$(pty "cd '$ROOT' && ./pve-toolbox definitely-not-a-command >/dev/null" || true)
[[ $out == *"${ESC}31"* ]] || fail "stderr colour followed stdout instead of stderr"
out=$(launch --color=sometimes list 2>&1 && fail "--color=sometimes accepted" || true)
[[ $out == *"--color"* ]] || fail "bad --color value not reported: $out"
pass "colour follows each stream, NO_COLOR, --color and TERM=dumb"
