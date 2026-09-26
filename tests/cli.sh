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

# Colour has to be decided before anything else can go wrong: a usage error
# raised while parsing arguments (an invalid flag combination, an unknown
# flag, or an LXC flag on the wrong command) must honour the same --color,
# --json and --quiet as the command that would otherwise have run.
out=$(pty "cd '$ROOT' && ./pve-toolbox --color=never --json --quiet" || true)
[[ $out != *"$ESC"* ]] || fail "--color=never ignored by the --json+--quiet conflict error"
out=$(launch --color=always --json --quiet 2>&1 || true)
[[ $out != *"$ESC"* ]] || fail "--json/--quiet did not force never over --color=always"
out=$(launch --color=always --bogus-flag 2>&1 || true)
[[ $out == *"${ESC}31"* ]] || fail "--color=always did not colour the unknown-flag error"
out=$(pty "cd '$ROOT' && ./pve-toolbox --color=never --bogus-flag" || true)
[[ $out != *"$ESC"* ]] || fail "--color=never did not silence the unknown-flag error"
out=$(launch --color=always --dry-run status 2>&1 || true)
[[ $out == *"${ESC}31"* ]] || fail "--color=always did not colour the LXC-flag error"
pass "colour is decided before any argument-parsing usage error"

# --- help ---------------------------------------------------------------------

help=$(launch --help)
for c in menu ui list install update check status doctor lxc-update uninstall link self-update help; do
    [[ $help == *"  $c "* ]] || fail "--help does not list $c"
done
[[ $help == *"pve-toolbox help <command>"* ]] || fail "--help lacks the per-command hint"
[[ $help != *"set -euo"* && $help != *"#"* ]] || fail "--help leaked source text"
[[ $(launch help) == "$help" ]] || fail "'help' and '--help' differ"
for c in list install status lxc-update; do
    a=$(launch help "$c") || fail "help $c failed"
    b=$(launch "$c" --help) || fail "$c --help failed"
    [[ $a == "$b" ]] || fail "help $c and $c --help differ"
    [[ $a == *"Usage: pve-toolbox $c"* ]] || fail "help $c lacks its usage line"
done
[[ $(launch help install) == *"Requires root"* ]] || fail "help install does not say it needs root"
[[ $(launch help lxc-update) == *"--dry-run"* ]] || fail "help lxc-update lacks its flags"
rc=0; launch help definitely-not >/dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "help <unknown> exited $rc, want 64"
pass "top-level and per-command help"

# --- flags and suggestions ----------------------------------------------------

expect_usage() { # expect_usage <want-substring> <args...>
    local want=$1 rc=0 out; shift
    out=$(launch "$@" 2>&1) || rc=$?
    [[ $rc -eq 64 ]] || fail "'$*' exited $rc, want 64: $out"
    [[ $out == *"$want"* ]] || fail "'$*' did not say '$want': $out"
}
expect_usage "did you mean: install" instal zfs-scrub
expect_usage "did you mean: status" stauts
expect_usage "did you mean: --json" status --jsn
expect_usage "--json is not supported by 'install'" install --json zfs-scrub
expect_usage "--dry-run is not supported by 'status'" status --dry-run
expect_usage "did you mean: zfs-scrub" status zfs-scrubb
expect_usage "did you mean: storage" list storag
expect_usage "run 'pve-toolbox help install'" install --json zfs-scrub
expect_usage "cannot be used together" status --json --quiet
# Accepted combinations that must keep working (flags anywhere).
out=$(launch status --json zfs-scrub) ; jq -e .schema_version <<<"$out" >/dev/null || fail "flag after arguments broke status"
out=$(launch --json status zfs-scrub) ; jq -e .schema_version <<<"$out" >/dev/null || fail "flag before the command broke status"
launch -y list >/dev/null || fail "-y list rejected"
launch list --color=never >/dev/null || fail "--color after the command rejected"
# '--' ends flags: a flag-looking argument is a (bad) module name, not a flag.
expect_usage "unknown module" install -- --weird-name
pass "per-command flags, suggestions and accepted combinations"

# The error keeps its first line and exit status; the hint lines follow it.
out=$(launch stauts 2>&1 || true)
first=$(head -n 1 <<<"$out")
[[ ${first# } == "error: unknown command: stauts" ]] || fail "first line changed: $out"
[[ $out == *$'\n'"did you mean: status?"$'\n'"run 'pve-toolbox help' for usage" ]] \
    || fail "unknown command lacks the suggestion and help lines: $out"
expect_usage "did you mean: status" help stauts
expect_usage "did you mean: status" stauts --help
expect_usage "run 'pve-toolbox help install'" install
expect_usage "run 'pve-toolbox help doctor'" doctor extra
expect_usage "did you mean: --color" --colr=never list
expect_usage "unknown tag: nope" list nope
# Nothing close enough: no suggestion line, still the help line.
out=$(launch zzzzzzzzzz 2>&1 || true)
[[ $out != *"did you mean"* && $out == *"run 'pve-toolbox help' for usage"* ]] \
    || fail "an unrelated word got a suggestion: $out"
# Help is answered before flags are checked against the command.
launch status --dry-run --help >/dev/null || fail "help refused because of an unsupported flag"
# Hidden commands are not unknown commands.
[[ $(launch _complete tags) == *storage* ]] || fail "_complete rejected as an unknown command"
launch list storage >/dev/null || fail "a known tag was rejected"
pass "usage errors carry suggestions and a help line"

# A hidden command (used by the completion scripts, never typed by an
# operator) has no help topic: its usage errors must not point at a
# "pve-toolbox help _complete" that would not resolve.
out=$(launch _complete tags --json 2>&1 || true)
[[ $out == *"run 'pve-toolbox help' for usage"* ]] \
    || fail "hidden command's usage error lacks the general help line: $out"
[[ $out != *"help _complete"* ]] || fail "hidden command's usage error named itself as a topic: $out"
pass "hidden commands carry no help topic"

# A pathological word must not make suggestion matching slow: the length
# difference alone rules most candidates out before the edit-distance
# comparison runs.
bogus=$(printf 'x%.0s' $(seq 1 3000))
for args in "$bogus" "install $bogus" "status --$bogus" "list $bogus"; do
    start=$SECONDS
    rc=0; launch $args >/dev/null 2>&1 || rc=$?
    elapsed=$((SECONDS - start))
    [[ $rc -eq 64 ]] || fail "'$args' exited $rc, want 64"
    [[ $elapsed -le 3 ]] || fail "'$args' took ${elapsed}s, suggestion matching is too slow"
done
pass "a 3000-character bogus word stays fast"
