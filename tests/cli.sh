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
# Set only by the root branch of the "_man needs no root" check below, for a
# world-readable copy that an unprivileged user must be able to traverse;
# $WORK itself stays mode 0700, so that copy cannot live inside it.
UNPRIV_ROOT=""
# The same, for the config show "needs root" check's fixture copy.
UNPRIV_CONF_ROOT=""
trap 'rm -rf -- "$WORK" "$UNPRIV_ROOT" "$UNPRIV_CONF_ROOT"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
tmp() { mktemp -d "$WORK/XXXXXX"; }

launch() { # launch [args...] -> runs ./pve-toolbox against throwaway dirs
    TOOLBOX_BIN_DIR=$(tmp) TOOLBOX_STATE_DIR=$(tmp) \
    TOOLBOX_SYSTEMD_DIR=$(tmp) TOOLBOX_CONF_DIR=$(tmp) \
    ./pve-toolbox "$@"
}

ESC=$'\e['

# The colour cases below assume a capable terminal and no inherited colour
# preference; CI runs with TERM unset or dumb, so pin them here.
export TERM=xterm
unset NO_COLOR TOOLBOX_COLOR

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
# The other direction, in one invocation that writes to both streams: stderr
# redirected to a file, stdout still the terminal. The launcher's step
# heading on stdout is coloured; the module's error line in the file is not.
both_root=$(tmp)
mkdir -p "$both_root/lib" "$both_root/modules/both"
cp "$ROOT"/lib/*.sh "$both_root/lib/"
printf '%s\n' \
    'MODULE_NAME="both"' \
    'MODULE_TITLE="Both streams fixture"' \
    'MODULE_DESC="writes to stdout and fails on stderr"' \
    'MODULE_TAGS="test"' \
    'module_status() { printf installed; }' \
    'module_update() { die "deliberate failure"; }' \
    > "$both_root/modules/both/module.sh"
both_err=$(tmp)/stderr
out=$(pty "cd '$ROOT' && PVE_TOOLBOX_ROOT='$both_root' TOOLBOX_CONF_DIR='$(tmp)' \
    TOOLBOX_STATE_DIR='$(tmp)' ./pve-toolbox update both 2>'$both_err'" || true)
err=$(<"$both_err")
[[ $out == *"${ESC}1mBoth streams fixture"* ]] \
    || fail "stdout lost its colour when only stderr was redirected: $out"
[[ $err == *"error:"*"deliberate failure"* ]] || fail "the module error did not reach stderr: $err"
[[ $err != *"$ESC"* ]] || fail "stderr was coloured for stdout's terminal: $err"
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
for c in menu ui list install update check status doctor config lxc-update uninstall link self-update help; do
    [[ $help == *"  $c "* ]] || fail "--help does not list $c"
done
[[ $help == *"pve-toolbox help <command>"* ]] || fail "--help lacks the per-command hint"
[[ $help == *"--json, --quiet"*"status, check, doctor"* ]] \
    || fail "--help no longer mentions --json/--quiet and where they apply"
[[ $help == *"--json, --quiet"*"--json"*"also for list"* ]] \
    || fail "--help does not say --json also works for list: $help"
[[ $help == *"--json, --quiet"*"--json"*"also for list and config"* ]] \
    || fail "--help does not say --json also works for config: $help"
[[ $help != *"set -euo"* && $help != *"#"* ]] || fail "--help leaked source text"
[[ $(launch help) == "$help" ]] || fail "'help' and '--help' differ"
for c in list install status config lxc-update; do
    a=$(launch help "$c") || fail "help $c failed"
    b=$(launch "$c" --help) || fail "$c --help failed"
    [[ $a == "$b" ]] || fail "help $c and $c --help differ"
    [[ $a == *"Usage: pve-toolbox $c"* ]] || fail "help $c lacks its usage line"
done
list_help=$(launch help list)
[[ $list_help == *"Usage: pve-toolbox list [--json] [tag]"* ]] \
    || fail "help list lacks the --json usage: $list_help"
[[ $list_help == *"--json"*"emit versioned, machine-readable JSON"* ]] \
    || fail "help list does not document --json: $list_help"
[[ $list_help == *"pve-toolbox list --json"* ]] \
    || fail "help list lacks a --json example: $list_help"
[[ $(launch help install) == *"Requires root"* ]] || fail "help install does not say it needs root"
config_help=$(launch help config)
[[ $config_help == *"Usage: pve-toolbox config show [--json] <module>"* ]] \
    || fail "help config lacks its usage line: $config_help"
[[ $config_help == *"Requires root"* ]] || fail "help config does not say it needs root: $config_help"
[[ $config_help == *"--json"*"emit versioned, machine-readable JSON"* ]] \
    || fail "help config does not document --json: $config_help"
[[ $config_help == *"pve-toolbox config show zfs-scrub"* \
    && $config_help == *"pve-toolbox config show --json config-backup"* ]] \
    || fail "help config lacks its examples: $config_help"
[[ $(launch help lxc-update) == *"--dry-run"* ]] || fail "help lxc-update lacks its flags"
lxc_help=$(launch help lxc-update)
lxc_root_count=$(grep -o "Requires root" <<<"$lxc_help" | wc -l)
[[ $lxc_root_count -eq 1 ]] \
    || fail "help lxc-update should say 'Requires root' exactly once, got $lxc_root_count"
# Wrapped description lines carry no trailing spaces, in any command's help.
for c in "" menu ui list install update check status doctor config lxc-update uninstall link self-update help; do
    ! launch help ${c:+"$c"} | grep -n ' $' \
        || fail "'help $c' has a line ending in a space"
done
rc=0; launch help definitely-not >/dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "help <unknown> exited $rc, want 64"
pass "top-level and per-command help"

# Long option/flag facts (--color=WHEN, --quiet) wrap inside the Options
# block rather than running off the terminal: no options-block line exceeds
# 78 columns (the same width CLI_DESC already folds at), and a continuation
# line - one whose label column is blank - is indented to line up under
# where the description text starts, 19 columns in.
check_options_wrap() { # check_options_wrap <name> <help-text>
    local name=$1 text=$2 line inopts=0
    while IFS= read -r line; do
        if [[ $inopts -eq 0 ]]; then
            [[ $line == "Options:" ]] && inopts=1
            continue
        fi
        [[ -n $line ]] || break
        [[ ${#line} -le 78 ]] \
            || fail "'$name' options block has a line over 78 columns (${#line}): $line"
        if [[ ${line:2:1} == " " ]]; then
            [[ ${line:0:19} == "$(printf '%19s' '')" && -n ${line:19} && ${line:19:1} != " " ]] \
                || fail "'$name' continuation line is not indented to column 20: '$line'"
        fi
    done <<<"$text"
}
check_options_wrap "help status" "$(launch help status)"
check_options_wrap "help lxc-update" "$lxc_help"
check_options_wrap "help" "$help"
[[ $(launch help status) == *"--color=WHEN"*$'\n'*"also disables it"* ]] \
    || fail "help status's --color=WHEN description did not wrap onto a second line"
[[ $(launch help status) == *"--quiet"*$'\n'*"This cannot be combined with --json"* ]] \
    || fail "help status's --quiet description did not wrap onto a second line"
pass "help wraps long option descriptions with a hanging indent, no line over 78 columns"

# lxc-update's runner refuses --yes and --force, so neither its help nor its
# completion offers them; every other global still applies. The launcher
# itself keeps accepting them, so the runner is what explains the refusal.
for flag in "-y, --yes" "-f, --force"; do
    [[ $lxc_help != *"$flag"* ]] || fail "help lxc-update offers $flag, which it refuses"
    [[ $(launch help status) == *"$flag"* ]] || fail "help status lost $flag"
done
[[ $lxc_help == *"--color=WHEN"* && $lxc_help == *"-h, --help"* ]] \
    || fail "help lxc-update lost the globals that do apply"
got=" $(launch _complete flags lxc-update | tr '\n' ' ') "
for flag in -y --yes -f --force; do
    [[ $got != *" $flag "* ]] || fail "'_complete flags lxc-update' offers $flag: $got"
done
[[ $got == *" --dry-run "* && $got == *" --color= "* ]] \
    || fail "'_complete flags lxc-update' lost a flag that applies: $got"
got=$(launch _complete flag-help lxc-update)
[[ $got != *$'\n-y:'* && $got != -y:* && $got != *$'\n--force:'* ]] \
    || fail "'_complete flag-help lxc-update' offers a refused global: $got"
[[ $got == *$'\n--dry-run:'* ]] || fail "'_complete flag-help lxc-update' lost --dry-run: $got"
[[ " $(launch _complete flags status | tr '\n' ' ') " == *" --yes "* ]] \
    || fail "'_complete flags status' lost --yes"
[[ " $(launch _complete flags list | tr '\n' ' ') " == *" --json "* ]] \
    || fail "'_complete flags list' lost --json"
pass "help and completion leave out the globals lxc-update refuses"

# The launcher still accepts --yes and --force for lxc-update and passes them
# on, so the runner remains the one that refuses them. A stub runner under a
# fixture root records what reaches it; the real run.sh never runs here.
stub_root=$(tmp)
mkdir -p "$stub_root/modules/lxc-update"
cp -r "$ROOT/lib" "$ROOT/VERSION" "$ROOT/pve-toolbox" "$stub_root/"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "ASSUME_YES=%s FORCE=%s ARGS=%s\n" "${ASSUME_YES:-unset}" "${FORCE:-unset}" "$*"' \
    > "$stub_root/modules/lxc-update/run.sh"
launch_bin() { # launch_bin <launcher> [args...]
    local bin=$1; shift
    TOOLBOX_BIN_DIR=$(tmp) TOOLBOX_STATE_DIR=$(tmp) \
    TOOLBOX_SYSTEMD_DIR=$(tmp) TOOLBOX_CONF_DIR=$(tmp) \
    "$bin" "$@"
}
stub() { # stub [args...] -> the fixture launcher, reaching only the stub runner
    PVE_TOOLBOX_ROOT="$stub_root" launch_bin "$stub_root/pve-toolbox" "$@"
}
out=$(stub -y lxc-update --dry-run 2>&1) || fail "-y lxc-update --dry-run rejected: $out"
[[ $out == "ASSUME_YES=1 FORCE=0 ARGS=--dry-run" ]] \
    || fail "-y lxc-update --dry-run did not reach the runner as given: $out"
out=$(stub lxc-update --yes --force --allow-removals 101 2>&1) \
    || fail "lxc-update --yes --force rejected: $out"
[[ $out == "ASSUME_YES=1 FORCE=1 ARGS=--allow-removals 101" ]] \
    || fail "lxc-update --yes --force did not reach the runner as given: $out"
pass "the launcher passes --yes and --force through to the lxc-update runner"

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
expect_usage "--quiet is not supported by 'list'" list --quiet
expect_usage "--quiet is not supported by 'list'" list --json --quiet
# Accepted combinations that must keep working (flags anywhere).
out=$(launch status --json zfs-scrub) ; jq -e .schema_version <<<"$out" >/dev/null || fail "flag after arguments broke status"
out=$(launch --json status zfs-scrub) ; jq -e .schema_version <<<"$out" >/dev/null || fail "flag before the command broke status"
launch -y list >/dev/null || fail "-y list rejected"
launch list --color=never >/dev/null || fail "--color after the command rejected"
out=$(launch list --json) ; jq -e '.schema_version == 1 and .command == "list"' <<<"$out" >/dev/null \
    || fail "list --json did not produce the expected envelope"
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
# Asking for its help says so accurately rather than calling it unknown.
for args in "_complete --help" "help _complete" "--help _complete tags"; do
    rc=0; out=$(launch $args 2>&1) || rc=$?
    [[ $rc -eq 64 ]] || fail "'$args' exited $rc, want 64: $out"
    [[ $out == *"'_complete' is internal and has no help"* ]] \
        || fail "'$args' did not say the command is internal: $out"
    [[ $out != *"unknown command"* ]] || fail "'$args' called _complete unknown: $out"
    [[ $out == *"run 'pve-toolbox help' for usage"* ]] \
        || fail "'$args' lacks the general help line: $out"
done
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

# --- completion drift ----------------------------------------------------------

# Every command the completion scripts can offer must actually work with
# 'help', so a command added to the table is never left uncompletable or
# undocumented.
while read -r c; do
    launch help "$c" >/dev/null || fail "'help $c' failed for a command _complete commands offers"
done < <(launch _complete commands)

# Every flag the command table lists for a command must be offered by that
# command's flags completion, read from the table itself so this catches a
# command added to CLI_FLAGS but not wired into completion.
declare -A drift_flags=()
eval "$(sed -n '/^declare -A CLI_FLAGS=/,/^)/p' ./pve-toolbox | sed 's/CLI_FLAGS/drift_flags/')"
for c in "${!drift_flags[@]}"; do
    got=$(launch _complete flags "$c" | tr '\n' ' ')
    for f in ${drift_flags[$c]}; do
        [[ " $got " == *" $f "* ]] || fail "'_complete flags $c' is missing $f from CLI_FLAGS"
    done
done
pass "completion targets track the command table"

# `_complete flags`/`flag-help` with no command, an empty command, or an
# unknown command is the most common completion of all - `pve-toolbox -<TAB>`
# before any command has been typed - and must not fail under `set -u`: only
# the globals, no stderr, exit 0.
for target in flags flag-help; do
    errfile=$(tmp)/stderr
    rc=0; out=$(launch _complete "$target" 2>"$errfile") || rc=$?
    err=$(<"$errfile")
    [[ $rc -eq 0 ]] || fail "'_complete $target' with no command exited $rc: $err"
    [[ -z $err ]] || fail "'_complete $target' with no command wrote to stderr: $err"
    [[ $out == *"-y"* ]] || fail "'_complete $target' with no command dropped the globals: $out"

    errfile=$(tmp)/stderr
    rc=0; out=$(launch _complete "$target" "" 2>"$errfile") || rc=$?
    err=$(<"$errfile")
    [[ $rc -eq 0 ]] || fail "'_complete $target \"\"' exited $rc: $err"
    [[ -z $err ]] || fail "'_complete $target \"\"' wrote to stderr: $err"
    [[ $out == *"-y"* ]] || fail "'_complete $target \"\"' dropped the globals: $out"

    errfile=$(tmp)/stderr
    rc=0; out=$(launch _complete "$target" bogus-command 2>"$errfile") || rc=$?
    err=$(<"$errfile")
    [[ $rc -eq 0 ]] || fail "'_complete $target bogus-command' exited $rc: $err"
    [[ -z $err ]] || fail "'_complete $target bogus-command' wrote to stderr: $err"
    [[ $out == *"-y"* ]] || fail "'_complete $target bogus-command' dropped the globals: $out"
done
pass "_complete flags and flag-help survive an absent, empty, or unknown command"

# --- man page -----------------------------------------------------------------

# Roff-escapes a string the same way _man_escape does, so an expectation
# containing a hyphen matches what the generator actually emits.
mroff() { local s=$1; s=${s//\\/\\\\}; s=${s//-/\\-}; printf '%s' "$s"; }

man=$(SOURCE_DATE_EPOCH=1790000000 ./pve-toolbox _man) || fail "_man failed"
[[ $man == .TH\ PVE-TOOLBOX\ 1\ \"September\ 2026\"* ]] || fail "_man date not taken from SOURCE_DATE_EPOCH"
[[ $man != *"@COMMANDS@"* && $man != *"@OPTIONS@"* && $man != *"@DATE@"* ]] || fail "_man left a placeholder"
while IFS= read -r c; do
    [[ $man == *".B $(mroff "$c")"* ]] || fail "man page lacks command $c"
done < <(./pve-toolbox _complete commands)
for f in --json --quiet --dry-run --allow-removals --notify --color; do
    [[ $man == *"$(mroff "$f")"* ]] || fail "man page lacks flag $f"
done
# list's own entry (not just --json somewhere else in the page, from status,
# check or doctor) documents --json in its usage and its own flag block.
# Isolate the text between list's usage line and the next command's (install)
# so the check cannot be satisfied by a later command's --json instead.
list_marker=".B $(mroff 'list [--json] [tag]')"
next_marker=".B $(mroff 'install <module>...')"
[[ $man == *"$list_marker"* ]] || fail "man page lacks list's usage with --json"
list_block=${man#*"$list_marker"}
list_block=${list_block%%"$next_marker"*}
[[ $list_block == *".RS"*".B $(mroff --json)"* ]] \
    || fail "man page's list entry lacks its own --json flag: $list_block"
# config's entry carries its usage, its own --json and "Requires root.".
config_marker=".B $(mroff 'config show [--json] <module>')"
[[ $man == *"$config_marker"* ]] || fail "man page lacks config's usage"
config_block=${man#*"$config_marker"}
config_block=${config_block%%".TP"$'\n'".B $(mroff 'lxc-update')"*}
[[ $config_block == *"Requires root."* ]] || fail "man page's config entry does not say Requires root.: $config_block"
[[ $config_block == *".RS"*".B $(mroff --json)"* ]] \
    || fail "man page's config entry lacks its own --json flag: $config_block"
[[ $(SOURCE_DATE_EPOCH=1790000000 ./pve-toolbox _man) == "$man" ]] || fail "_man is not reproducible"
if command -v groff >/dev/null 2>&1; then
    warn_out=$(printf '%s\n' "$man" | groff -man -ww -z 2>&1) || fail "groff failed: $warn_out"
    [[ -z $warn_out ]] || fail "groff warnings: $warn_out"
elif [[ ${PACKAGING_TEST_REQUIRED:-0} -eq 1 ]]; then
    fail "groff is required to lint the man page"
else
    printf 'skip man page lint, no groff\n'
fi
pass "generated man page covers every command and flag"

# _man_text's leading '.'/apostrophe guard, exercised directly rather than
# only through whatever CLI_* strings happen to start with today. Extracted
# straight from pve-toolbox (the range from _man_escape's definition through
# _man_text's closing brace) so this tests the real function, not a copy.
man_text_src=$(sed -n '/^_man_escape() {/,/^}/p' ./pve-toolbox)
[[ -n $man_text_src ]] || fail "could not extract _man_escape/_man_text from pve-toolbox"
out=$(eval "$man_text_src"; _man_text '.foo')
[[ $out == '\&.foo' ]] || fail "_man_text did not guard a line starting with '.': $out"
out=$(eval "$man_text_src"; _man_text "'foo")
[[ $out == "\\&'foo" ]] || fail "_man_text did not guard a line starting with an apostrophe: $out"
out=$(eval "$man_text_src"; _man_text 'plain text')
[[ $out == 'plain text' ]] || fail "_man_text changed ordinary text: $out"
out=$(eval "$man_text_src"; _man_text 'a-b')
[[ $out == 'a\-b' ]] || fail "_man_text did not escape a hyphen: $out"
pass "_man_text guards a leading '.' or apostrophe and leaves ordinary text alone"

# _man must not call discover: a checkout with zero modules would make
# discover die, so _man succeeding there proves it never ran.
empty_root=$(tmp)
mkdir -p "$empty_root/lib" "$empty_root/modules" "$empty_root/share/man"
cp "$ROOT"/lib/*.sh "$empty_root/lib/"
cp "$ROOT/VERSION" "$empty_root/VERSION"
cp "$ROOT/pve-toolbox" "$empty_root/pve-toolbox"
cp "$ROOT/share/man/pve-toolbox.1.in" "$empty_root/share/man/pve-toolbox.1.in"
out=$(PVE_TOOLBOX_ROOT="$empty_root" launch_bin "$empty_root/pve-toolbox" _man 2>&1) \
    || fail "_man died in a module-less checkout, so it must have called discover: $out"
[[ -n $out ]] || fail "_man produced nothing in a module-less checkout"
pass "_man does not call discover"

# _man needs no root. Unprivileged, a plain, successful call is the proof.
# The suite also runs as real root in CI, where "unprivileged" has to be
# manufactured: run _man as uid/gid 65534 from a world-readable copy of just
# what it needs (mirroring the module-less checkout built above), the same
# way a packaged, non-root invocation would see it. If the switch itself is
# impossible (e.g. user-namespace root, where 65534 is unmapped, or no
# setpriv), skip with the reason -- unless CLI_ROOT_TEST_REQUIRED=1, which
# fails instead: real root in CI has the mapping and must take the real
# path, so a required run silently skipping this check is not a pass.
if [[ $(id -u) -ne 0 ]]; then
    launch _man >/dev/null || fail "_man failed as a normal user"
    pass "_man works as a normal user"
elif command -v setpriv >/dev/null 2>&1 \
    && setpriv --reuid=65534 --regid=65534 --clear-groups true 2>/dev/null; then
    UNPRIV_ROOT=$(mktemp -d)
    chmod 0755 "$UNPRIV_ROOT"
    mkdir -p "$UNPRIV_ROOT/lib" "$UNPRIV_ROOT/modules" "$UNPRIV_ROOT/share/man"
    cp "$ROOT"/lib/*.sh "$UNPRIV_ROOT/lib/"
    cp "$ROOT/VERSION" "$UNPRIV_ROOT/VERSION"
    cp "$ROOT/pve-toolbox" "$UNPRIV_ROOT/pve-toolbox"
    cp "$ROOT/share/man/pve-toolbox.1.in" "$UNPRIV_ROOT/share/man/pve-toolbox.1.in"
    chmod -R a+rX "$UNPRIV_ROOT"
    out=$(PVE_TOOLBOX_ROOT="$UNPRIV_ROOT" HOME=/nonexistent-pve-toolbox-home \
        setpriv --reuid=65534 --regid=65534 --clear-groups \
        "$UNPRIV_ROOT/pve-toolbox" _man 2>&1) \
        || fail "_man failed for an unprivileged user while the suite ran as root: $out"
    [[ $out == .TH* ]] \
        || fail "_man did not print a .TH line for an unprivileged user: $out"
    pass "_man works as an unprivileged user while the suite runs as root"
else
    if [[ ${CLI_ROOT_TEST_REQUIRED:-0} -eq 1 ]]; then
        fail "_man unprivileged check required but cannot switch to uid 65534 (setpriv missing or the uid is unmapped in this namespace)"
    fi
    printf 'skip _man unprivileged check, cannot switch to uid 65534 (setpriv missing or the uid is unmapped in this namespace)\n'
fi

# _man is hidden: not offered by completion, not documented by help, but
# still recognised (not "unknown command").
got=" $(launch _complete commands | tr '\n' ' ') "
[[ $got != *" _man "* ]] || fail "_man is offered by completion"
out=$(launch help _man 2>&1 || true)
[[ $out == *"'_man' is internal and has no help"* ]] || fail "help _man does not call it internal: $out"
pass "_man is hidden from completion and help"

# P2-2: commands that require root say so in the generated page, and
# lxc-update names the globals its runner refuses.
[[ $man == *"Requires root."* ]] || fail "man page never says Requires root."
refused="The -y, --yes and -f, --force options are refused."
[[ $man == *"$(mroff "$refused")"* ]] || fail "man page lacks the lxc-update refused-globals sentence"

# P2-3: facts from the deleted static debian/pve-toolbox.1 must survive into
# the generated page, even though the wording is free to change.
[[ $man == *"refuse this command"* ]] || fail "man page dropped: packaged installs refuse 'link'"
[[ $man == *"cluster"* && $man == *"storage"* && $man == *"installed"* ]] \
    || fail "man page dropped doctor's audit scope (host, cluster, storage, installed modules)"
[[ $man == *"Exit status 0 when healthy"* ]] || fail "man page dropped doctor's exit-status sentence"
quiet_json="cannot be combined with $(mroff "--json")"
[[ $man == *"$quiet_json"* ]] || fail "man page dropped: --quiet cannot combine with --json"
color_force="$(mroff "--json") or $(mroff "--quiet") always force"
[[ $man == *"$color_force"* ]] || fail "man page dropped: --json/--quiet always force colour off"

# ENVIRONMENT: NO_COLOR and TOOLBOX_COLOR are both documented.
[[ $man == *"NO_COLOR"* ]] || fail "man page lacks the ENVIRONMENT section's NO_COLOR"
[[ $man == *".SH ENVIRONMENT"* ]] || fail "man page lacks an ENVIRONMENT section"
[[ $man == *".B TOOLBOX_COLOR"$'\n'*"auto (default), always, or never"* ]] \
    || fail "man page's TOOLBOX_COLOR entry is missing or lost its three values"
[[ $man == *".B TOOLBOX_COLOR"* ]] && [[ $man == *"overrides NO_COLOR"* ]] \
    || fail "man page's TOOLBOX_COLOR entry does not say it overrides NO_COLOR"
pass "generated man page carries every fact from the deleted static page"

# The TOOLBOX_COLOR entry keeps its operator-facing facts but drops the
# internal-mechanics sentence about the launcher exporting it from --color.
[[ $man != *"reaches the same decision"* ]] \
    || fail "man page's TOOLBOX_COLOR entry still explains launcher internals"

# The man-page summary reads as a capitalised sentence opener; 'help' keeps
# the lowercase, mid-sentence form used in its own table.
help_summary=$(launch help lxc-update | sed -n '3p')
[[ $help_summary == "${help_summary,}" ]] \
    || fail "test fixture assumption broken: lxc-update summary is already capitalised"
cap_summary="$(mroff "${help_summary^}")"

# The summary, CLI_DESC, "Requires root.", and the refused-globals sentence
# are each separated by .sp, matching help's blank-line separation, instead
# of running together as one paragraph.
[[ $man == *"$cap_summary."$'\n'".sp"$'\n'* ]] \
    || fail "man page does not capitalise the summary and separate it from CLI_DESC with .sp"
[[ $man == *".sp"$'\n'"Requires root."* ]] \
    || fail "man page does not separate Requires root. with .sp"
[[ $man == *".sp"$'\n'"$(mroff "$refused")"* ]] \
    || fail "man page does not separate the refused-globals sentence with .sp"
pass "man page capitalises the summary and separates it, CLI_DESC, root, and refused-globals facts with .sp"

# Missing template: fails closed rather than printing nothing. A fixture
# root with everything but share/man/ exercises that path without disturbing
# the real template used by every other assertion above.
no_template_root=$(tmp)
mkdir -p "$no_template_root/lib" "$no_template_root/modules"
cp "$ROOT"/lib/*.sh "$no_template_root/lib/"
cp "$ROOT/VERSION" "$ROOT/pve-toolbox" "$no_template_root/"
rc=0; err=$(PVE_TOOLBOX_ROOT="$no_template_root" launch_bin "$no_template_root/pve-toolbox" _man 2>&1) || rc=$?
[[ $rc -eq 1 ]] || fail "_man with a missing template exited $rc, want 1"
[[ $err == *"man page template missing"* ]] || fail "_man with a missing template did not say why: $err"
pass "_man fails closed when its template is missing"

# --- list module status (no cache) -----------------------------------------

# cmd_list never loads the MODULE_STATUS cache: each shown module's status is
# computed once, right where it is printed, and a module the tag filter
# discards never has its module_status run at all. a-one, b-two and d-four
# are installed; c-three carries the extra tag "solo" and exits non-zero with
# no output, so it must read as not installed, with an installed module on
# either side of it.
status_root=$(tmp)
mkdir -p "$status_root/lib" \
    "$status_root/modules/a-one" "$status_root/modules/b-two" \
    "$status_root/modules/c-three" "$status_root/modules/d-four"
cp "$ROOT"/lib/*.sh "$status_root/lib/"
cp "$ROOT/VERSION" "$status_root/VERSION"
cp "$ROOT/pve-toolbox" "$status_root/pve-toolbox"
chmod 0755 "$status_root/pve-toolbox"
# Each fixture's module_status appends its own name to $STATUS_CALLS (a file
# outside the checkout, so callers that do not set it are unaffected) before
# reporting, so a test can count how many times it actually ran. Each also
# has its own module_status_long, distinct from module_status, so the
# status/check status_long fallback (which calls module_status when a module
# has no dedicated long form) never adds a module_status call of its own.
printf '%s\n' \
    'MODULE_NAME="a-one"' 'MODULE_TITLE="A one"' 'MODULE_DESC="fixture a"' \
    'MODULE_TAGS="fixture"' 'MODULE_HOST_ONLY=0' \
    'module_status() { printf "a-one\n" >> "${STATUS_CALLS:-/dev/null}"; printf "installed a"; }' \
    'module_status_long() { printf "installed a (long)"; }' \
    > "$status_root/modules/a-one/module.sh"
printf '%s\n' \
    'MODULE_NAME="b-two"' 'MODULE_TITLE="B two"' 'MODULE_DESC="fixture b"' \
    'MODULE_TAGS="fixture"' 'MODULE_HOST_ONLY=0' \
    'module_status() { printf "b-two\n" >> "${STATUS_CALLS:-/dev/null}"; printf "installed b"; }' \
    'module_status_long() { printf "installed b (long)"; }' \
    > "$status_root/modules/b-two/module.sh"
printf '%s\n' \
    'MODULE_NAME="c-three"' 'MODULE_TITLE="C three"' 'MODULE_DESC="fixture c"' \
    'MODULE_TAGS="fixture solo"' 'MODULE_HOST_ONLY=0' \
    'module_status() { printf "c-three\n" >> "${STATUS_CALLS:-/dev/null}"; exit 3; }' \
    'module_status_long() { printf "c-three (long)"; }' \
    > "$status_root/modules/c-three/module.sh"
printf '%s\n' \
    'MODULE_NAME="d-four"' 'MODULE_TITLE="D four"' 'MODULE_DESC="fixture d"' \
    'MODULE_TAGS="fixture"' 'MODULE_HOST_ONLY=0' \
    'module_status() { printf "d-four\n" >> "${STATUS_CALLS:-/dev/null}"; printf "installed d"; }' \
    'module_status_long() { printf "installed d (long)"; }' \
    > "$status_root/modules/d-four/module.sh"

status_launch() { # status_launch [args...] -> the fixture launcher above
    PVE_TOOLBOX_ROOT="$status_root" launch_bin "$status_root/pve-toolbox" "$@"
}

list_out=$(status_launch list) || fail "list failed against the status fixture"
order=$(grep -oE '^(a-one|b-two|c-three|d-four)' <<<"$list_out" | tr '\n' ' ')
[[ $order == "a-one b-two c-three d-four " ]] \
    || fail "list did not keep discovery order over the status fixture: $order"
c_status=$(awk '/^c-three/{getline; print; exit}' <<<"$list_out")
[[ $c_status == *"status: not installed"* ]] \
    || fail "c-three (exit 3, no output) did not read as not installed: $c_status"
pass "list preserves discovery order and reads a failing status as not installed"

installed_out=$(status_launch _complete installed) || fail "_complete installed failed against the status fixture"
[[ $installed_out == $'a-one\nb-two\nd-four' ]] \
    || fail "_complete installed did not list a-one, b-two, d-four in order: $installed_out"
pass "_complete installed lists installed modules in discovery order"

# list --json's status for each fixture module matches calling that module's
# module_status directly, in its own shell (no output means not installed).
# list computes status itself rather than reading a cache, so this checks
# that computation directly; it is not a cache-safety test.
direct_json=$(status_launch list --json) || fail "list --json failed against the status fixture"
for m in a-one b-two c-three d-four; do
    want=$(bash -c 'source "$1"; module_status' _ "$status_root/modules/$m/module.sh" 2>/dev/null) || true
    want=${want:-not installed}
    want_installed=true
    [[ $want != "not installed" ]] || want_installed=false
    jq -e --arg m "$m" --arg st "$want" --argjson inst "$want_installed" \
        '.modules[] | select(.name == $m) | .status == $st and .installed == $inst' \
        <<<"$direct_json" >/dev/null \
        || fail "list --json status of $m differs from a direct module_status call (want '$want', installed $want_installed): $direct_json"
done
pass "list --json's status matches a direct module_status call for each fixture module"

# Each shown module's status is computed exactly once: a counter file gets
# exactly one line per module for 'list' and, separately, for 'list --json'.
calls_dir=$(tmp)
calls_file="$calls_dir/calls"
: > "$calls_file"
STATUS_CALLS="$calls_file" status_launch list >/dev/null \
    || fail "list failed while counting module_status calls"
for m in a-one b-two c-three d-four; do
    got=$(grep -cx "$m" "$calls_file")
    [[ $got -eq 1 ]] \
        || fail "list ran $m's module_status $got time(s), want exactly once: $(cat "$calls_file")"
done

: > "$calls_file"
STATUS_CALLS="$calls_file" status_launch list --json >/dev/null \
    || fail "list --json failed while counting module_status calls"
for m in a-one b-two c-three d-four; do
    got=$(grep -cx "$m" "$calls_file")
    [[ $got -eq 1 ]] \
        || fail "list --json ran $m's module_status $got time(s), want exactly once: $(cat "$calls_file")"
done
pass "list and list --json compute each shown module's status exactly once"

# A tag filter discards a module before its status is ever computed: c-three
# is the only fixture module tagged 'solo', so filtering by it must run only
# c-three's module_status, never a-one's, b-two's, or d-four's.
: > "$calls_file"
STATUS_CALLS="$calls_file" status_launch list solo >/dev/null \
    || fail "list solo failed while counting module_status calls"
[[ $(grep -cx c-three "$calls_file") -eq 1 ]] \
    || fail "list solo did not run c-three's module_status exactly once: $(cat "$calls_file")"
for m in a-one b-two d-four; do
    [[ $(grep -cx "$m" "$calls_file") -eq 0 ]] \
        || fail "list solo ran $m's module_status although it does not carry solo: $(cat "$calls_file")"
done

: > "$calls_file"
STATUS_CALLS="$calls_file" status_launch list --json solo >/dev/null \
    || fail "list --json solo failed while counting module_status calls"
[[ $(grep -cx c-three "$calls_file") -eq 1 ]] \
    || fail "list --json solo did not run c-three's module_status exactly once: $(cat "$calls_file")"
for m in a-one b-two d-four; do
    [[ $(grep -cx "$m" "$calls_file") -eq 0 ]] \
        || fail "list --json solo ran $m's module_status although it does not carry solo: $(cat "$calls_file")"
done
pass "list and list --json never compute a tag-filtered-out module's status"

# --- module status cache (status/check/update with no module names) --------

# load_statuses still matters for the no-module-names form of status/check/
# update and for _complete installed: those call is_installed on every
# module at least twice in one command (once to build the implicit module
# list, once more per module while acting on or reporting it). With the
# cache, an installed module's module_status runs exactly once for the whole
# command; each fixture's own module_status_long keeps the status report's
# fallback from calling module_status a second time on top of that.
: > "$calls_file"
STATUS_CALLS="$calls_file" status_launch status --json >/dev/null \
    || fail "status --json (no names) failed while counting module_status calls"
for m in a-one b-two d-four; do
    got=$(grep -cx "$m" "$calls_file")
    [[ $got -eq 1 ]] \
        || fail "status --json (no names) ran $m's module_status $got time(s), want exactly once: $(cat "$calls_file")"
done
pass "load_statuses caches status for the no-names form of status --json"

# --- list --json ------------------------------------------------------------

json_out=$(status_launch list --json) || fail "list --json failed against the status fixture"
[[ $json_out != *"$ESC"* ]] || fail "list --json contained colour escapes: $json_out"
[[ $json_out != *"error"* && $json_out != *"warn"* ]] \
    || fail "list --json printed something other than JSON: $json_out"
jq -e '.schema_version == 1' <<<"$json_out" >/dev/null \
    || fail "list --json schema_version is not 1: $json_out"
jq -e '.command == "list"' <<<"$json_out" >/dev/null \
    || fail "list --json command is not 'list': $json_out"
jq -e '[.modules[].name] == ["a-one","b-two","c-three","d-four"]' <<<"$json_out" >/dev/null \
    || fail "list --json module names/order wrong: $json_out"
jq -e '.modules[2].installed == false' <<<"$json_out" >/dev/null \
    || fail "list --json did not read c-three (exit 3, no output) as not installed: $json_out"
jq -e '.modules[0].installed == true' <<<"$json_out" >/dev/null \
    || fail "list --json did not read a-one as installed: $json_out"
jq -e '.modules[0].tags | type == "array"' <<<"$json_out" >/dev/null \
    || fail "list --json tags is not an array: $json_out"
jq -e '.modules[0].tags == ["fixture"]' <<<"$json_out" >/dev/null \
    || fail "list --json tags content wrong: $json_out"
pass "list --json matches the documented schema over the status fixture"

filtered_out=$(status_launch list --json solo) || fail "list --json <tag> failed"
jq -e '[.modules[].name] == ["c-three"]' <<<"$filtered_out" >/dev/null \
    || fail "list --json <tag> did not filter by tag: $filtered_out"
pass "list --json filters by tag"

rc=0; status_launch list --json nosuch >/dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "list --json nosuch exited $rc, want 64"
pass "list --json rejects an unknown tag with exit 64"

# JSON validity for any module metadata: quotes, backslashes, control
# characters (tab, newline) in title/description, and a module with no tags
# at all.
json_meta_root=$(tmp)
mkdir -p "$json_meta_root/lib" "$json_meta_root/modules/quirky"
cp "$ROOT"/lib/*.sh "$json_meta_root/lib/"
cp "$ROOT/VERSION" "$json_meta_root/VERSION"
cp "$ROOT/pve-toolbox" "$json_meta_root/pve-toolbox"
chmod 0755 "$json_meta_root/pve-toolbox"
cat > "$json_meta_root/modules/quirky/module.sh" <<'MODULE_EOF'
MODULE_NAME="quirky"
MODULE_TITLE='Weird "title" \with\ backslash'
MODULE_DESC=$'line one\tline two "quoted" \\ backslash\nline three'
MODULE_TAGS=""
MODULE_HOST_ONLY=0
module_status() { printf '%s' 'installed "v1" \only-once'; }
MODULE_EOF
quirky_json=$(PVE_TOOLBOX_ROOT="$json_meta_root" \
    launch_bin "$json_meta_root/pve-toolbox" list --json) \
    || fail "list --json failed for quirky metadata"
jq -e . <<<"$quirky_json" >/dev/null \
    || fail "list --json produced invalid JSON for quirky metadata: $quirky_json"
[[ $(jq -r '.modules[0].title' <<<"$quirky_json") == 'Weird "title" \with\ backslash' ]] \
    || fail "list --json mangled a title with quotes and backslashes: $quirky_json"
[[ $(jq -r '.modules[0].description' <<<"$quirky_json") \
    == 'line one line two "quoted" \ backslash; line three' ]] \
    || fail "list --json did not clean a description with tabs/newlines as report_clean_text does: $quirky_json"
[[ $(jq -r '.modules[0].tags | length' <<<"$quirky_json") == 0 ]] \
    || fail "list --json gave a nonempty tags array for an untagged module: $quirky_json"
[[ $(jq -r '.modules[0].installed' <<<"$quirky_json") == true ]] \
    || fail "list --json did not read the quirky module as installed: $quirky_json"
pass "list --json stays valid JSON for quotes, backslashes, control characters, and empty tags"

# Tags separated by a tab or by more than one space are split the way
# module_tags splits them, both in the JSON array and when filtering by tag.
mkdir -p "$json_meta_root/modules/spacey"
cat > "$json_meta_root/modules/spacey/module.sh" <<'MODULE_EOF'
MODULE_NAME="spacey"
MODULE_TITLE="Spacey"
MODULE_DESC="odd tag separators"
MODULE_TAGS=$'one\ttwo  three '
MODULE_HOST_ONLY=0
module_status() { return 1; }
MODULE_EOF
spacey_json=$(PVE_TOOLBOX_ROOT="$json_meta_root" \
    launch_bin "$json_meta_root/pve-toolbox" list --json) \
    || fail "list --json failed for tags with tabs and double spaces"
jq -e '.modules[] | select(.name == "spacey") | .tags == ["one","two","three"]' \
    <<<"$spacey_json" >/dev/null \
    || fail "list --json did not split tags on tabs and runs of spaces: $spacey_json"
spacey_json=$(PVE_TOOLBOX_ROOT="$json_meta_root" \
    launch_bin "$json_meta_root/pve-toolbox" list --json two) \
    || fail "list --json <tag> failed for a tab-separated tag"
jq -e '[.modules[].name] == ["spacey"]' <<<"$spacey_json" >/dev/null \
    || fail "list --json <tag> did not match a tab-separated tag: $spacey_json"
spacey_out=$(PVE_TOOLBOX_ROOT="$json_meta_root" \
    launch_bin "$json_meta_root/pve-toolbox" list two) \
    || fail "list <tag> failed for a tab-separated tag"
[[ $(grep -oE '^(quirky|spacey)' <<<"$spacey_out") == spacey ]] \
    || fail "list <tag> did not match a tab-separated tag: $spacey_out"
pass "list and list --json split tags on any whitespace, as module_tags does"

# list --json builds its tags array from the same bash split module_has_tag
# and module_tags use (module_tags_of), not a separate jq regex: a tag string
# with an embedded newline is split the same way by both, even though that
# way only keeps the first line. MODULE_TAGS=$'x\ny  z' means only "x" is a
# tag; "y" and "z" (after the newline) are not, in the JSON array or in what
# 'list <tag>' accepts.
mkdir -p "$json_meta_root/modules/newliney"
cat > "$json_meta_root/modules/newliney/module.sh" <<'MODULE_EOF'
MODULE_NAME="newliney"
MODULE_TITLE="Newliney"
MODULE_DESC="a tag string with an embedded newline"
MODULE_TAGS=$'x\ny  z'
MODULE_HOST_ONLY=0
module_status() { return 1; }
MODULE_EOF
newliney_json=$(PVE_TOOLBOX_ROOT="$json_meta_root" \
    launch_bin "$json_meta_root/pve-toolbox" list --json) \
    || fail "list --json failed for a tag string with an embedded newline"
jq -e '.modules[] | select(.name == "newliney") | .tags == ["x"]' \
    <<<"$newliney_json" >/dev/null \
    || fail "list --json tags for a newline-separated tag string were not just [\"x\"]: $newliney_json"
newliney_out=$(PVE_TOOLBOX_ROOT="$json_meta_root" \
    launch_bin "$json_meta_root/pve-toolbox" list x) \
    || fail "list x failed for a tag before the embedded newline"
[[ $(grep -oE '^newliney' <<<"$newliney_out") == newliney ]] \
    || fail "list x did not match the tag before the embedded newline: $newliney_out"
for cmd in "list y" "list --json y"; do
    rc=0
    # shellcheck disable=SC2086 # $cmd is a fixed two-word command above
    PVE_TOOLBOX_ROOT="$json_meta_root" launch_bin "$json_meta_root/pve-toolbox" $cmd >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 64 ]] \
        || fail "'$cmd' exited $rc, want 64: y is after the embedded newline and must not be a known tag"
done
pass "list --json builds tags from the same split module_has_tag uses, embedded newline included"

# --- config show ----------------------------------------------------------------

# A fixture root with modules whose configuration config show displays:
#   e-conf    declares E_DIR and E_JOB_*_SRC public and lists an extra file
#   f-none    keeps no configuration at all
#   g-hidden  declares nothing public, so every key is hidden
#   h-badname lists a configuration name that would escape the directory
#   i-fails   fails while listing its extra files
# Every planted secret contains SECRET, so one substring check covers them.
conf_root=$(tmp)
mkdir -p "$conf_root/lib" "$conf_root/modules"
cp "$ROOT"/lib/*.sh "$conf_root/lib/"
cp "$ROOT/VERSION" "$ROOT/pve-toolbox" "$conf_root/"
chmod 0755 "$conf_root/pve-toolbox"
conf_module() { # conf_module <name> <line>... -> writes a fixture module
    mkdir -p "$conf_root/modules/$1"
    local name=$1; shift
    printf '%s\n' "MODULE_NAME=\"$name\"" "MODULE_TITLE=\"$name\"" \
        'MODULE_DESC="config show fixture"' 'MODULE_TAGS="fixture"' \
        'MODULE_HOST_ONLY=0' 'module_status() { printf installed; }' "$@" \
        > "$conf_root/modules/$name/module.sh"
}
conf_module e-conf 'MODULE_CONFIG_PUBLIC="E_DIR E_JOB_*_SRC"' \
    'module_config_files() { printf "%s\n" e-conf-extra; }'
conf_module f-none
conf_module g-hidden
conf_module h-badname 'module_config_files() { printf "%s\n" "../escape"; }'
conf_module i-fails 'module_config_files() { return 3; }'

conf_launch() { # conf_launch <conf-dir> [args...] -> the fixture launcher
    local dir=$1; shift
    TOOLBOX_BIN_DIR=$(tmp) TOOLBOX_STATE_DIR=$(tmp) TOOLBOX_SYSTEMD_DIR=$(tmp) \
    TOOLBOX_CONF_DIR=$dir PVE_TOOLBOX_ROOT="$conf_root" "$conf_root/pve-toolbox" "$@"
}
conf_write() { # conf_write <dir> <name> <line>... -> <dir>/<name>.conf, mode 0600
    local dir=$1 name=$2; shift 2
    ( umask 077; printf '%s\n' "$@" > "$dir/$name.conf" )
    chmod 0600 "$dir/$name.conf"
}
# The planted configuration: a webhook and tokens that must stay hidden, a
# public directory and job source, an empty key, a key written twice, and a
# multi-line hidden value whose second line looks like a public key.
conf_plant() { # conf_plant <dir>
    conf_write "$1" e-conf \
        '# managed by pve-toolbox / e-conf' \
        "E_DIR='/srv/e'" \
        "E_WEBHOOK='https://discord.com/api/webhooks/1/SECRETVALUE'" \
        "E_DIR_TOKEN='tok-SECRET2'" \
        "E_JOB_A_SRC='tank/a'" \
        "E_EMPTY=''" \
        "E_MULTI='first line" \
        "E_JOB_B_SRC=SECRET4 inside a hidden value'" \
        "E_DIR='/srv/e'"
    conf_write "$1" e-conf-extra "E_DIR='/srv/x'" "E_KEY='SECRET3'"
}
no_secret() { # no_secret <what> <text>
    [[ $2 != *SECRET* ]] || fail "$1 leaked a hidden value: $2"
}
expect_config_fail() { # expect_config_fail <what> <want-substring> <conf-dir> [args...]
    local what=$1 want=$2 dir=$3 rc=0 out err errfile
    shift 3
    errfile=$(tmp)/stderr
    out=$(conf_launch "$dir" "$@" 2>"$errfile") || rc=$?
    err=$(<"$errfile")
    [[ $rc -eq 1 ]] || fail "$what: exited $rc, want 1: $out $err"
    [[ $err == *"$want"* ]] || fail "$what: the error did not say '$want': $err"
    [[ -z $out ]] || fail "$what: printed configuration before refusing: $out"
    no_secret "$what" "$out $err"
}

# Usage errors come before the root check, so they are the same for anyone.
expect_conf_usage() { # expect_conf_usage <want-substring> <args...>
    local want=$1 rc=0 out; shift
    out=$(conf_launch "$(tmp)" "$@" 2>&1) || rc=$?
    [[ $rc -eq 64 ]] || fail "'$*' exited $rc, want 64: $out"
    [[ $out == *"$want"* ]] || fail "'$*' did not say '$want': $out"
    [[ $out == *"run 'pve-toolbox help config' for usage"* ]] \
        || fail "'$*' did not point at 'help config': $out"
}
expect_conf_usage "config needs a subcommand" config
expect_conf_usage "did you mean: show" config shwo e-conf
expect_conf_usage "config show needs a module name" config show
expect_conf_usage "unknown module: nosuch" config show nosuch
expect_conf_usage "did you mean: e-conf" config show e-cnf
expect_conf_usage "unknown module: ../modules/e-conf" config show ../modules/e-conf
expect_conf_usage "unknown module: _template" config show _template
expect_conf_usage "takes one module name" config show e-conf f-none
expect_conf_usage "--quiet is not supported by 'config'" config show --quiet e-conf
pass "config show usage errors exit 64 with suggestions, before the root check"

# A here-string or here-document can need a temporary file, which config
# show must not: its section of the launcher, and report_clean_text, which
# cleans its public values, use neither.
config_code=$(sed -n '/^# -* config show --$/,/^# -* ui --$/p' "$ROOT/pve-toolbox")
[[ $config_code == *"cmd_config()"* ]] || fail "could not find the config show section of the launcher"
config_code+=$(sed -n '/^report_clean_text() {/,/^}/p' "$ROOT/lib/report.sh")
[[ $config_code == *"report_clean_text()"* ]] || fail "could not find report_clean_text"
if grep -nE '<<' <<<"$config_code" | grep -vE '^[0-9]+: *#'; then
    fail "config show code uses a here-string or here-document"
fi
pass "config show code uses no here-string or here-document"

# --- which keys each module declares public ----------------------------------------
#
# config show prints the value of every key a module's MODULE_CONFIG_PUBLIC
# matches, so a wrong declaration leaks a webhook, a token or a credential.
# The audit collects the keys every module writes -- conf_set with a literal
# key, the *_CONF_KEYS arrays however many lines they span, and
# zfs-replication's JOB_<name>_<field> keys, sampled with job names chosen
# to trip a careless pattern -- and holds them to the hidden lists below,
# which mirror the declaration table. Every key a module writes is either
# public by its declaration or listed here as hidden, so a new key cannot
# arrive unclassified, and no public pattern may match a hidden key.
declare -A audit_hidden=(
    [backup-audit]=""
    [certificate-watch]=""
    [config-backup]="DISCORD_WEBHOOK CB_AGE_RECIPIENT CB_GIT_REMOTE CB_GIT_SSH_KEY CB_GIT_TOKEN_FILE"
    [komodo-periphery]="KP_KEY_FILE KP_KNOWN_HOSTS"
    [lxc-update]="DISCORD_WEBHOOK"
    [restore-drill]=""
    [scrutiny-collectors]=""
    [storage-hygiene]=""
    [upgrade-readiness]=""
    [zfs-replication]="DISCORD_WEBHOOK JOB_A_OPTS JOB_SRC_OPTS JOB_A_SRC_OPTS JOB_PATH_OPTS JOB_A_PATH_OPTS JOB_DST_OPTS"
    [zfs-scrub]="DISCORD_WEBHOOK"
)
# Modules that keep no toolbox configuration file at all.
audit_noconf=" scrutiny-collectors "
# Key names that say they hold a secret or point at one. None may be public,
# whatever the table says.
audit_secretish='(TOKEN|WEBHOOK|PASSW|REMOTE|_KEY|KEY_|RECIPIENT|OPTS|KNOWN_HOSTS|CREDENTIAL)'

audit_keys() { # audit_keys <module> -> AUDIT_KEYS, every key the module writes
    local m=$1 f line rest key
    local -a arrays=() files=()
    AUDIT_KEYS=()
    mapfile -t files < <(find "$ROOT/modules/$m" -type f | sort)
    # *_CONF_KEYS=( ... ), on one line or many.
    mapfile -t arrays < <(awk '
        /^[[:space:]]*[A-Z][A-Z0-9_]*_CONF_KEYS=\(/ { on = 1; sub(/^[^(]*\(/, "") }
        on { line = $0; done = sub(/\).*$/, "", line); print line; if (done) on = 0 }
    ' "${files[@]}" | tr -s ' \t' '\n\n' | sed '/^$/d')
    for key in "${arrays[@]}"; do
        [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || fail "audit: $m has a *_CONF_KEYS entry that is not a key name: $key"
        AUDIT_KEYS+=("$key")
    done
    for f in "${files[@]}"; do
        while IFS= read -r line; do
            [[ $line =~ ^[[:space:]]*# ]] && continue
            while [[ $line == *conf_set* ]]; do
                line=${line#*conf_set}
                [[ $line =~ ^[[:space:]]+ ]] || continue
                rest=${line#"${BASH_REMATCH[0]}"}
                # The record: "..." or a bare word.
                if [[ $rest =~ ^\"[^\"]*\"[[:space:]]+ || $rest =~ ^[^[:space:]\"]+[[:space:]]+ ]]; then
                    rest=${rest#"${BASH_REMATCH[0]}"}
                else
                    fail "audit: $m: cannot read the record of a conf_set call in ${f#"$ROOT"/}: conf_set$line"
                fi
                if [[ $rest =~ ^([A-Z][A-Z0-9_]*)([[:space:]]|$) ]]; then
                    AUDIT_KEYS+=("${BASH_REMATCH[1]}")
                elif [[ $rest =~ ^\"\$\(_zr_key\ \"\$job\"\ ([A-Z]+)\)\" ]]; then
                    key=${BASH_REMATCH[1]}
                    AUDIT_KEYS+=("JOB_A_$key" "JOB_SRC_$key" "JOB_A_SRC_$key" "JOB_PATH_$key" "JOB_A_PATH_$key" "JOB_DST_$key")
                elif [[ $rest =~ ^\"\$(key|k)\" ]] && ((${#arrays[@]})); then
                    : # a loop over the module's *_CONF_KEYS, collected above
                else
                    fail "audit: $m: unrecognised conf_set key in ${f#"$ROOT"/}: conf_set$line"
                fi
            done
        done <"$f"
    done
}

audit_public() { # audit_public <module> -> AUDIT_PUBLIC, its MODULE_CONFIG_PUBLIC words
    local - raw
    set -f
    raw=$(TOOLBOX_ROOT=$ROOT bash -c 'set +u; source "$1" >/dev/null 2>&1; printf "%s" "${MODULE_CONFIG_PUBLIC-}"' _ \
        "$ROOT/modules/$1/module.sh")
    [[ $raw != *[$'\t\n']* ]] || fail "audit: $1's MODULE_CONFIG_PUBLIC is not space-separated"
    # shellcheck disable=SC2206 # the declaration is space-separated by contract
    AUDIT_PUBLIC=($raw)
}

audit_matches() { # audit_matches <key> <pattern>... -> true when any pattern matches
    local key=$1 p
    shift
    for p in "$@"; do
        # shellcheck disable=SC2053 # the patterns are globs on purpose
        [[ $key != $p ]] || return 0
    done
    return 1
}

audit_modules=()
for d in "$ROOT"/modules/*/; do
    d=${d%/}; d=${d##*/}
    [[ $d == _* ]] || audit_modules+=("$d")
done
[[ ${#audit_modules[@]} -gt 0 ]] || fail "audit: found no modules"
for m in "${audit_modules[@]}"; do
    [[ -n ${audit_hidden[$m]+x} ]] \
        || fail "audit: module $m is not in the declaration audit; classify every key it writes"
    audit_keys "$m"
    audit_public "$m"
    read -r -a hidden <<<"${audit_hidden[$m]}"
    if [[ $audit_noconf == *" $m "* ]]; then
        [[ ${#AUDIT_KEYS[@]} -eq 0 ]] || fail "audit: $m is listed as keeping no configuration but writes ${AUDIT_KEYS[*]}"
        [[ ${#AUDIT_PUBLIC[@]} -eq 0 ]] || fail "audit: $m keeps no configuration but declares ${AUDIT_PUBLIC[*]} public"
        continue
    fi
    [[ ${#AUDIT_KEYS[@]} -gt 0 ]] || fail "audit: found no keys written by $m"
    [[ ${#AUDIT_PUBLIC[@]} -gt 0 ]] || fail "audit: $m declares no MODULE_CONFIG_PUBLIC"
    for p in "${AUDIT_PUBLIC[@]}"; do
        # A letter first and only * as a wildcard: no bare *, no ? or [...].
        [[ $p =~ ^[A-Z][A-Z0-9_]*(\*[A-Z0-9_]*)*$ ]] \
            || fail "audit: $m declares a public pattern that is not a key name or a simple glob: $p"
        audit_matches DISCORD_WEBHOOK "$p" && fail "audit: $m's public pattern $p matches DISCORD_WEBHOOK"
        found=0
        for key in "${AUDIT_KEYS[@]}"; do
            audit_matches "$key" "$p" && { found=1; break; }
        done
        [[ $found -eq 1 ]] || fail "audit: $m's public pattern $p matches no key the module writes"
    done
    for key in "${hidden[@]}"; do
        audit_matches "$key" "${AUDIT_PUBLIC[@]}" && fail "audit: $m's MODULE_CONFIG_PUBLIC matches the hidden key $key"
    done
    for key in "${AUDIT_KEYS[@]}"; do
        if audit_matches "$key" "${AUDIT_PUBLIC[@]}"; then
            [[ ! $key =~ $audit_secretish ]] || fail "audit: $m declares $key public, but its name says it holds a secret"
        else
            [[ " ${audit_hidden[$m]} " == *" $key "* ]] \
                || fail "audit: $m writes $key, which is neither public nor in the audit's hidden list"
        fi
    done
done
pass "every module's MODULE_CONFIG_PUBLIC matches only keys it writes that hold no secret"

# komodo-periphery keeps a record per managed guest in files of their own,
# which its module_config_files names from the ID lists: read-only, with
# conf_get only, IDs matching KP_ID_RE (the same rule host.sh and
# transport-qga.sh use for a container or VM ID), invalid ones skipped.
(
    TOOLBOX_CONF_DIR=$(tmp)
    export TOOLBOX_CONF_DIR
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/komodo-periphery/module.sh
    source "$ROOT/modules/komodo-periphery/module.sh"
    declare -F module_config_files >/dev/null || fail "komodo-periphery has no module_config_files"
    [[ $KP_ID_RE == '^[1-9][0-9]{2,8}$' ]] \
        || fail "komodo-periphery KP_ID_RE changed unexpectedly: $KP_ID_RE"
    out=$(module_config_files) || fail "komodo-periphery module_config_files failed with no configuration"
    [[ $out == komodo-periphery-qemu ]] \
        || fail "komodo-periphery module_config_files with no configuration printed: $out"
    # 0 and a zero-padded ID are not valid container/VM IDs (KP_ID_RE forbids
    # a leading zero), so they must be skipped exactly like the other rejects.
    conf_set komodo-periphery KP_IDS '101 abc 102 -5 1e3 0x1 ../x * 0 099'
    conf_set komodo-periphery-qemu KP_VM_IDS $'201 x/y\n202 [0-9]*\n0\n099'
    # A saved * or [0-9]* must not match a file name in the working directory.
    cd "$(tmp)"
    : >"555"
    before=$(find "$TOOLBOX_CONF_DIR" -printf '%p %m %s %T@\n' | sort)
    out=$(module_config_files 2>&1) || fail "komodo-periphery module_config_files failed: $out"
    want=$'komodo-periphery-qemu\nkomodo-periphery-101\nkomodo-periphery-102\nkomodo-periphery-qemu-201\nkomodo-periphery-qemu-202'
    [[ $out == "$want" ]] || fail "komodo-periphery module_config_files printed '$out', want '$want' (0 and 099 must be skipped)"
    [[ $(find "$TOOLBOX_CONF_DIR" -printf '%p %m %s %T@\n' | sort) == "$before" ]] \
        || fail "komodo-periphery module_config_files changed the configuration directory"
)
pass "komodo-periphery lists its per-guest configuration files, skipping invalid, 0 and zero-padded IDs"

# host.sh and transport-qga.sh keep their own literal copies of the same
# container/VM ID rule instead of sourcing KP_ID_RE (their flows are
# real-root, CI-only paths that may run without module.sh ever being
# sourced), so nothing stops the copies drifting from module.sh's constant.
# Search those two files for the exact text of KP_ID_RE itself -- not a
# broader "^[1-9][0-9]{n,m}$" shape, which host.sh also uses for an unrelated
# port-number check with different bounds and would false-match -- and
# require at least as many hits as are known to exist today, so neither a
# changed bound in one of the copies nor a changed KP_ID_RE that the copies
# were not updated to match can pass vacuously.
(
    # shellcheck source=modules/komodo-periphery/module.sh
    source "$ROOT/modules/komodo-periphery/module.sh"
    mapfile -t copies < <(grep -ohF "$KP_ID_RE" \
        "$ROOT/modules/komodo-periphery/host.sh" "$ROOT/modules/komodo-periphery/transport-qga.sh")
    [[ ${#copies[@]} -ge 4 ]] \
        || fail "found only ${#copies[@]} occurrence(s) of KP_ID_RE ('$KP_ID_RE') in host.sh and transport-qga.sh, want at least 4: either a copy drifted to a different rule, or KP_ID_RE changed without updating them"
    for copy in "${copies[@]}"; do
        [[ $copy == "$KP_ID_RE" ]] \
            || fail "internal: grep -F returned a non-matching line: $copy"
    done
)
pass "host.sh and transport-qga.sh's container/VM ID regex copies match module.sh's KP_ID_RE"

if [[ $EUID -ne 0 ]]; then
    dir=$(tmp); conf_plant "$dir"
    rc=0; out=$(conf_launch "$dir" config show e-conf 2>&1) || rc=$?
    [[ $rc -eq 1 ]] || fail "config show as a normal user exited $rc, want 1: $out"
    [[ $out == *"needs root"* ]] || fail "config show as a normal user did not say it needs root: $out"
    no_secret "config show as a normal user" "$out"
    rc=0; out=$(conf_launch "$dir" config show --json e-conf 2>&1) || rc=$?
    [[ $rc -eq 1 && $out == *"needs root"* ]] \
        || fail "config show --json as a normal user did not refuse (exit $rc): $out"
    no_secret "config show --json as a normal user" "$out"
    pass "config show needs root"
    if [[ ${CLI_ROOT_TEST_REQUIRED:-0} -eq 1 ]]; then
        fail "config show root cases required but the suite is not running as root"
    fi
    printf 'skip config show root cases (needs root)\n'
else
    # As root, the refusal is proven for an unprivileged user from a
    # world-readable copy of the fixture, the same way _man is above.
    if command -v setpriv >/dev/null 2>&1 \
        && setpriv --reuid=65534 --regid=65534 --clear-groups true 2>/dev/null; then
        UNPRIV_CONF_ROOT=$(mktemp -d)
        cp -r "$conf_root/." "$UNPRIV_CONF_ROOT/"
        chmod -R a+rX "$UNPRIV_CONF_ROOT"
        dir=$(tmp); conf_plant "$dir"
        rc=0
        out=$(TOOLBOX_CONF_DIR="$dir" PVE_TOOLBOX_ROOT="$UNPRIV_CONF_ROOT" \
            HOME=/nonexistent-pve-toolbox-home \
            setpriv --reuid=65534 --regid=65534 --clear-groups \
            "$UNPRIV_CONF_ROOT/pve-toolbox" config show e-conf 2>&1) || rc=$?
        [[ $rc -eq 1 ]] || fail "config show as uid 65534 exited $rc, want 1: $out"
        [[ $out == *"needs root"* ]] || fail "config show as uid 65534 did not say it needs root: $out"
        no_secret "config show as uid 65534" "$out"
        pass "config show needs root (checked as uid 65534)"
    else
        if [[ ${CLI_ROOT_TEST_REQUIRED:-0} -eq 1 ]]; then
            fail "config show unprivileged check required but cannot switch to uid 65534 (setpriv missing or the uid is unmapped in this namespace)"
        fi
        printf 'skip config show unprivileged check, cannot switch to uid 65534 (setpriv missing or the uid is unmapped in this namespace)\n'
    fi

    # --- what it shows
    dir=$(tmp); conf_plant "$dir"
    errfile=$(tmp)/stderr
    out=$(conf_launch "$dir" config show e-conf 2>"$errfile") \
        || fail "config show e-conf failed: $out $(<"$errfile")"
    err=$(<"$errfile")
    [[ -z $err ]] || fail "config show e-conf wrote to stderr: $err"
    no_secret "config show" "$out"
    for want in /srv/e tank/a /srv/x; do
        [[ $out == *"$want"* ]] || fail "config show did not show public value $want: $out"
    done
    for key in E_WEBHOOK E_DIR_TOKEN E_MULTI E_KEY; do
        grep -Eq "^  $key +\(set, hidden\)$" <<<"$out" \
            || fail "config show did not show $key as (set, hidden): $out"
    done
    grep -Eq '^  E_EMPTY +\(not set\)$' <<<"$out" || fail "config show did not show E_EMPTY as (not set): $out"
    grep -Eq '^  E_DIR +/srv/e$' <<<"$out" || fail "config show did not align E_DIR with its value: $out"
    [[ $out != *E_JOB_B_SRC* ]] \
        || fail "config show read a line inside a multi-line value as a key: $out"
    # Keys in file order, once each; the main file before the extra one.
    order=$(grep -oE '^  E_[A-Z_]+' <<<"$out" | tr -d ' ' | tr '\n' ' ')
    [[ $order == "E_DIR E_WEBHOOK E_DIR_TOKEN E_JOB_A_SRC E_EMPTY E_MULTI E_DIR E_KEY " ]] \
        || fail "config show keys not in file order, once per file: $order"
    [[ $out == *e-conf*E_DIR*e-conf-extra*E_KEY* ]] \
        || fail "config show did not head each file with its name: $out"
    [[ $out != *"$ESC"* ]] || fail "config show wrote colour to a pipe: $out"
    pass "config show displays public values and hides every other one"

    json=$(conf_launch "$dir" config show --json e-conf 2>"$errfile") \
        || fail "config show --json e-conf failed: $json $(<"$errfile")"
    [[ -z $(<"$errfile") ]] || fail "config show --json wrote to stderr: $(<"$errfile")"
    no_secret "config show --json" "$json"
    [[ $json != *"$ESC"* ]] || fail "config show --json contained colour escapes: $json"
    jq -e '.schema_version == 1 and .command == "config" and .module == "e-conf"' \
        <<<"$json" >/dev/null || fail "config show --json envelope wrong: $json"
    jq -e '[.files[].name] == ["e-conf","e-conf-extra"]' <<<"$json" >/dev/null \
        || fail "config show --json files wrong: $json"
    jq -e '.files[0].keys == [
            {key:"E_DIR",set:true,hidden:false,value:"/srv/e"},
            {key:"E_WEBHOOK",set:true,hidden:true},
            {key:"E_DIR_TOKEN",set:true,hidden:true},
            {key:"E_JOB_A_SRC",set:true,hidden:false,value:"tank/a"},
            {key:"E_EMPTY",set:false,hidden:true},
            {key:"E_MULTI",set:true,hidden:true}]' <<<"$json" >/dev/null \
        || fail "config show --json keys of e-conf wrong: $json"
    jq -e '.files[1].keys == [
            {key:"E_DIR",set:true,hidden:false,value:"/srv/x"},
            {key:"E_KEY",set:true,hidden:true}]' <<<"$json" >/dev/null \
        || fail "config show --json keys of e-conf-extra wrong: $json"
    jq -e '[.files[].keys[] | select(.hidden) | has("value")] | any | not' <<<"$json" >/dev/null \
        || fail "config show --json gave a hidden key a value: $json"
    pass "config show --json carries a value only for public keys"

    # A module that declares nothing public shows every key hidden.
    dir=$(tmp)
    conf_write "$dir" g-hidden "G_PATH='/srv/SECRET-looking'" "G_EMPTY=''"
    out=$(conf_launch "$dir" config show g-hidden) || fail "config show g-hidden failed: $out"
    no_secret "config show g-hidden" "$out"
    grep -Eq '^  G_PATH +\(set, hidden\)$' <<<"$out" || fail "an undeclared key was not hidden: $out"
    grep -Eq '^  G_EMPTY +\(not set\)$' <<<"$out" || fail "an undeclared empty key was not (not set): $out"
    json=$(conf_launch "$dir" config show --json g-hidden) || fail "config show --json g-hidden failed"
    jq -e '[.files[].keys[] | has("value")] | any | not' <<<"$json" >/dev/null \
        || fail "config show --json showed a value for a module declaring nothing public: $json"
    pass "config show hides every key of a module that declares none public"

    # Nothing saved: a message and exit 0, or an empty files array.
    dir=$(tmp)
    out=$(conf_launch "$dir" config show f-none) || fail "config show f-none failed: $out"
    [[ $out == "no saved configuration for f-none" ]] || fail "config show f-none said: $out"
    out=$(conf_launch "$dir/absent" config show f-none) \
        || fail "config show with no configuration directory failed: $out"
    [[ $out == "no saved configuration for f-none" ]] \
        || fail "config show with no configuration directory said: $out"
    json=$(conf_launch "$dir" config show --json f-none) || fail "config show --json f-none failed"
    jq -e '.module == "f-none" and .files == []' <<<"$json" >/dev/null \
        || fail "config show --json f-none did not give an empty files array: $json"
    pass "config show reports a module with no saved configuration"

    # Public values are still cleaned: credentials in a URL are redacted and
    # control characters never reach the terminal or break the JSON.
    dir=$(tmp)
    esc=$'\e'
    conf_write "$dir" e-conf "E_DIR='https://user:SECRET6@host.example/x'" \
        "E_JOB_A_SRC='tank/\"q\"${esc}[31mred\\x'"
    out=$(conf_launch "$dir" config show e-conf) || fail "config show with odd public values failed: $out"
    no_secret "config show of a URL with credentials" "$out"
    [[ $out == *"[redacted]"* ]] || fail "config show did not redact a credential URL: $out"
    [[ $out != *$'\e'* ]] || fail "config show printed a raw escape character: $out"
    json=$(conf_launch "$dir" config show --json e-conf) || fail "config show --json with odd public values failed"
    no_secret "config show --json of a URL with credentials" "$json"
    [[ $json != *$'\e'* ]] || fail "config show --json printed a raw escape character: $json"
    [[ $(jq -r '.files[0].keys[1].value' <<<"$json") == 'tank/"q"'$'\e''[31mred\x' ]] \
        || fail "config show --json mangled a public value: $json"
    pass "config show cleans public values"

    # The UTF-8 encoding of a C1 control character (U+009B, CSI) is replaced
    # with ? in both text and --json, regardless of the caller's own locale.
    # [[:cntrl:]] only reaches it depending on locale (it does not match at
    # all under LC_ALL=C), and jq does not JSON-escape U+0080-U+009F at all,
    # so config show must strip it itself before either output sees it.
    dir=$(tmp)
    c1=$'\xc2\x9b'
    conf_write "$dir" e-conf "E_DIR='A${c1}B'"
    out=$(LC_ALL=C conf_launch "$dir" config show e-conf) || fail "config show under LC_ALL=C failed: $out"
    [[ $out != *"$c1"* ]] || fail "config show under LC_ALL=C printed a raw C1 control byte: $out"
    grep -Eq '^  E_DIR +A\?B$' <<<"$out" \
        || fail "config show under LC_ALL=C did not replace the C1 control byte with ?: $out"
    json=$(LC_ALL=C conf_launch "$dir" config show --json e-conf) \
        || fail "config show --json under LC_ALL=C failed: $json"
    [[ $json != *"$c1"* ]] || fail "config show --json under LC_ALL=C printed a raw C1 control byte: $json"
    [[ $(jq -r '.files[0].keys[0].value' <<<"$json") == "A?B" ]] \
        || fail "config show --json under LC_ALL=C did not replace the C1 control byte with ?: $json"
    pass "config show replaces the UTF-8 C1 control range with ? regardless of the caller's locale"

    # A lone byte in 0x80-0x9f is not UTF-8 at all, so the check above does
    # not see it, yet an 8-bit terminal reads a bare 0x9b as CSI. Text output
    # shows every invalid byte as ?, and keeps valid UTF-8 as it is.
    dir=$(tmp)
    conf_write "$dir" e-conf "E_DIR='A"$'\x9b'"B é"$'\xc2'"'"
    for loc in C C.UTF-8; do
        out=$(LC_ALL=$loc conf_launch "$dir" config show e-conf) \
            || fail "config show under LC_ALL=$loc failed: $out"
        grep -Eq '^  E_DIR +A\?B é\?$' <<<"$out" \
            || fail "config show under LC_ALL=$loc did not replace lone bytes with ?: $(od -c <<<"$out")"
        json=$(LC_ALL=$loc conf_launch "$dir" config show --json e-conf) \
            || fail "config show --json under LC_ALL=$loc failed: $json"
        [[ $(jq -r '.files[0].keys[0].value' <<<"$json") == "A"$'\xef\xbf\xbd'"B é"$'\xef\xbf\xbd' ]] \
            || fail "config show --json under LC_ALL=$loc did not carry lone bytes as U+FFFD: $json"
    done
    pass "config show shows lone invalid bytes as ? in text and U+FFFD in --json"

    # A public value far larger than one command-line argument may be is
    # shown in full, in text and in JSON: nothing passes it through argv.
    dir=$(tmp)
    big=$(printf 'a%.0s' $(seq 1 300000))
    conf_write "$dir" e-conf "E_DIR='$big'"
    rc=0; out=$(conf_launch "$dir" config show e-conf 2>&1) || rc=$?
    [[ $rc -eq 0 ]] || fail "config show of a 300 KB public value exited $rc: ${out:0:300}"
    [[ $out == *"E_DIR"*"$big"* ]] || fail "config show did not show a 300 KB public value"
    rc=0; out=$(conf_launch "$dir" config show --json e-conf 2>&1) || rc=$?
    [[ $rc -eq 0 ]] || fail "config show --json of a 300 KB public value exited $rc: ${out:0:300}"
    [[ $(jq -r '.files[0].keys[0].value' <<<"$out") == "$big" ]] \
        || fail "config show --json did not carry a 300 KB public value"
    pass "config show handles a public value larger than a command-line argument"

    # --- the parser: exactly the format conf_set writes
    conf_value() { # conf_value <conf-dir> <key> -> the JSON value config show gives <key> in e-conf
        conf_launch "$1" config show --json e-conf \
            | jq -r --arg k "$2" '.files[0].keys[] | select(.key == $k) | .value'
    }
    dir=$(tmp)
    ( umask 077; printf '%s\n' '# managed by pve-toolbox / e-conf' '' '# a comment' \
        "E_DIR='/srv/a'" "E_JOB_A_SRC='first" "second'" '' "E_JOB_B_SRC='it'\\''s'" \
        "E_JOB_C_SRC=''" "E_WEBHOOK='SECRETD'" "E_JOB_D_SRC='/srv/#not-a-comment'" \
        "E_DIR='/srv/b'" "E_JOB_F_SRC='x'\\''" "y'" '#' > "$dir/e-conf.conf"
      printf '%s' "E_JOB_E_SRC='no newline at the end'" >> "$dir/e-conf.conf" )
    out=$(conf_launch "$dir" config show e-conf) || fail "config show of a valid conf_set file failed: $out"
    no_secret "config show of a valid conf_set file" "$out"
    order=$(grep -oE '^  E_[A-Z_]+' <<<"$out" | tr -d ' ' | tr '\n' ' ')
    [[ $order == "E_DIR E_JOB_A_SRC E_JOB_B_SRC E_JOB_C_SRC E_WEBHOOK E_JOB_D_SRC E_JOB_F_SRC E_JOB_E_SRC " ]] \
        || fail "config show keys not in first-appearance order: $order"
    grep -Eq '^  E_DIR +/srv/b$' <<<"$out" || fail "the last assignment of a key did not win: $out"
    grep -Eq '^  E_JOB_A_SRC +first; second$' <<<"$out" || fail "a multi-line value was not shown cleaned: $out"
    grep -Eq '^  E_JOB_C_SRC +\(not set\)$' <<<"$out" || fail "an empty value was not (not set): $out"
    grep -Eq '^  E_WEBHOOK +\(set, hidden\)$' <<<"$out" || fail "E_WEBHOOK was not hidden: $out"
    [[ $(conf_value "$dir" E_JOB_A_SRC) == "first; second" ]] || fail "multi-line value wrong in JSON"
    [[ $(conf_value "$dir" E_JOB_B_SRC) == "it's" ]] || fail "a '\\'' value was not unescaped"
    [[ $(conf_value "$dir" E_JOB_C_SRC) == "" ]] || fail "an empty value was not empty"
    [[ $(conf_value "$dir" E_JOB_F_SRC) == "x'; y" ]] || fail "a '\\'' ending a line did not continue the value"
    [[ $(conf_value "$dir" E_JOB_D_SRC) == "/srv/#not-a-comment" ]] || fail "a # inside a value was lost"
    [[ $(conf_value "$dir" E_JOB_E_SRC) == "no newline at the end" ]] || fail "a last line without a newline was lost"
    pass "config show parses comments, blank lines, multi-line, escaped-quote, empty and repeated values"

    # Valid conf_set syntax is shown exactly as stored: nothing is expanded.
    dir=$(tmp)
    conf_write "$dir" e-conf "E_WEBHOOK='SECRETE'" "E_DIR='\$(printf %s \"\$E_WEBHOOK\")'" \
        "E_JOB_A_SRC='\$E_WEBHOOK \`echo \$E_WEBHOOK\` \${E_WEBHOOK}'" "key='E_WEBHOOK'" "f='E_WEBHOOK'"
    out=$(conf_launch "$dir" config show e-conf 2>&1) || fail "config show of literal shell syntax failed: $out"
    no_secret "config show of literal shell syntax" "$out"
    [[ $(conf_value "$dir" E_DIR) == '$(printf %s "$E_WEBHOOK")' ]] \
        || fail "a command substitution inside single quotes was not shown literally"
    [[ $(conf_value "$dir" E_JOB_A_SRC) == '$E_WEBHOOK `echo $E_WEBHOOK` ${E_WEBHOOK}' ]] \
        || fail "expansions inside single quotes were not shown literally"
    pass "config show shows stored values literally, never expanded"

    # Everything else is refused: exit 1, the file and the line named, and
    # no planted secret anywhere. Line 3 is the offending line in each. The
    # parser never runs the file, so each of these fails for the same plain
    # reason -- it is not a comment, blank, or a KEY='value' line -- and none
    # needs the elaborate sourcing-sandbox payloads (forged NUL-separated
    # records, an 'ok' sentinel, a $_cfgscan_* name) that earlier rounds used
    # to probe a subshell-sourcing design this codebase no longer has.
    esc=$'\e'
    for bad in 'printf "%s\n" "$E_WEBHOOK"' \
        'builtin() { :; }' 'command() { :; }' 'function helper { :; }' 'readonly -f conf_file' \
        "trap ':' EXIT" "trap ':' DEBUG" \
        'shopt -s nocasematch' 'declare -n E_DIR=E_WEBHOOK' 'export E_DIR' \
        'echo "$E_WEBHOOK"' 'echo "$E_WEBHOOK" >&2' \
        'E_DIR=$(printf %s "$E_WEBHOOK")' 'E_DIR=`echo "$E_WEBHOOK"`' 'E_DIR="/srv/$E_WEBHOOK"' \
        'E_DIR=/srv/e' 'E_DIR=' "E_DIR='/srv/'\"\$E_WEBHOOK\"" "E_DIR='/srv/e' # trailing" \
        "E_DIR='/srv/e';echo \"\$E_WEBHOOK\"" "E_DIR='/srv/e'"$'\r' "  E_DIR='/srv/e'" \
        "E_DIR='/srv/${esc}'x" ' ' "E_TOKEN='SECRETC"; do
        dir=$(tmp)
        conf_write "$dir" e-conf "E_WEBHOOK='SECRETA'" "e_dir='SECRETB'" "$bad" "E_DIR='/srv/e'"
        expect_config_fail "a file with line 3: ${bad:0:60}" "$dir/e-conf.conf: line 3: " "$dir" config show e-conf
        expect_config_fail "a file with line 3 (json): ${bad:0:60}" "$dir/e-conf.conf: line 3: " \
            "$dir" config show --json e-conf
    done
    # The reasons, and the line counted past a multi-line value.
    dir=$(tmp)
    conf_write "$dir" e-conf '# managed' "E_A='x" "y'" "E_TOKEN='SECRETF"
    expect_config_fail "an unterminated quote" "line 4: unterminated single quote" "$dir" config show e-conf
    dir=$(tmp)
    conf_write "$dir" e-conf "E_A='x" "y'" 'E_DIR="$E_A"'
    expect_config_fail "a double-quoted value" "line 3: the value is not single-quoted" "$dir" config show e-conf
    dir=$(tmp)
    conf_write "$dir" e-conf "E_DIR='x'SECRETG"
    expect_config_fail "text after the value" "line 1: unexpected text after the value" "$dir" config show e-conf
    # A quote is escaped only as '\'' in full: a \' or \ ending the line,
    # or \' followed by text, is text after the value.
    for bad in "E_DIR='x'\\'" "E_DIR='x'\\" "E_DIR='x'\\'SECRETG'"; do
        dir=$(tmp)
        conf_write "$dir" e-conf "E_A='x'" "$bad" "SECRETG'"
        expect_config_fail "an incomplete escape: $bad" "line 2: unexpected text after the value" \
            "$dir" config show e-conf
    done
    dir=$(tmp)
    conf_write "$dir" e-conf "E_A='x'" 'export SECRETH'
    expect_config_fail "a command line" "line 2: not a comment or a KEY='value' line" "$dir" config show e-conf
    dir=$(tmp)
    conf_write "$dir" e-conf "E_DIR='/srv/e'"
    printf "E_TOKEN='SECRETI\0'\n" >> "$dir/e-conf.conf"
    expect_config_fail "a NUL byte" "it contains a NUL byte" "$dir" config show e-conf
    pass "config show refuses anything but the conf_set format, naming the file and line"

    # Round trip through the real conf_set: every tricky value comes back
    # exactly, as report_clean_text renders it.
    dir=$(tmp)
    tricky=("it's a \"quote\" \\ and '\\'' too" $'multi\nline\n' "" "a=b=c" "#leading hash"
        "''" "\$HOME \`id\` \$(id) \${x}" "trailing space " "plain/path with spaces")
    (
        TOOLBOX_CONF_DIR=$dir
        # shellcheck source=lib/common.sh
        source "$ROOT/lib/common.sh"
        i=0
        for v in "${tricky[@]}"; do
            conf_set e-conf "E_JOB_${i}_SRC" "$v"
            i=$((i + 1))
        done
        conf_set e-conf E_WEBHOOK "https://discord.com/api/webhooks/1/SECRETJ"
        conf_set e-conf E_JOB_0_SRC "${tricky[0]}"
    )
    json=$(conf_launch "$dir" config show --json e-conf) || fail "config show of a conf_set file failed"
    no_secret "config show --json of a conf_set file" "$json"
    i=0
    for v in "${tricky[@]}"; do
        want=$(source "$ROOT/lib/report.sh"; report_clean_text "$v")
        got=$(jq -r --arg k "E_JOB_${i}_SRC" '.files[0].keys[] | select(.key == $k) | .value' <<<"$json")
        [[ $got == "$want" ]] || fail "conf_set round trip of value $i: got '$got', want '$want'"
        i=$((i + 1))
    done
    jq -e '.files[0].keys | map(select(.key == "E_WEBHOOK")) == [{key:"E_WEBHOOK",set:true,hidden:true}]' \
        <<<"$json" >/dev/null || fail "conf_set round trip: E_WEBHOOK not hidden: $json"
    pass "config show round-trips values written by conf_set"

    # module_config_files reads through conf_get, which config show replaces
    # with its own parser: the module's file is never run, even there. The
    # fixture's module_config_files is the template's documented example,
    # taken from the template itself.
    example=$(sed -n '/^#                           module_config_files() {/,/^#                           }/s/^#                           //p' \
        "$ROOT/modules/_template/module.sh")
    [[ $example == *"conf_get"*"MY_IDS"* ]] || fail "could not extract the template's module_config_files example"
    conf_module j-ids "$example"
    dir=$(tmp)
    conf_write "$dir" j-ids "MY_IDS='1 2 x'" "J_TOKEN='SECRETK'"
    conf_write "$dir" j-ids-1 "J_ONE='SECRETL'"
    conf_write "$dir" j-ids-2 "J_TWO=''"
    out=$(conf_launch "$dir" config show j-ids) || fail "config show of the template example failed: $out"
    no_secret "config show of the template example" "$out"
    [[ $out == *"j-ids ("*"j-ids-1 ("*"J_ONE"*"j-ids-2 ("*"J_TWO"* ]] \
        || fail "config show did not show the extra files module_config_files read with conf_get: $out"
    dir=$(tmp)
    conf_write "$dir" j-ids "J_TOKEN='SECRETLEAK'" "MY_IDS='1'" 'echo "stderr: $J_TOKEN" >&2' \
        "touch '$dir/RAN'" 'echo "stdout: $J_TOKEN"'
    conf_write "$dir" j-ids-1 "J_ONE='1'"
    expect_config_fail "a hostile file read by module_config_files" "$dir/j-ids.conf: line 3: " \
        "$dir" config show j-ids
    expect_config_fail "a hostile file read by module_config_files (json)" "$dir/j-ids.conf: line 3: " \
        "$dir" config show --json j-ids
    [[ ! -e $dir/RAN ]] || fail "config show ran the configuration file module_config_files read"
    # An extra file that module_config_files reads is held to the same checks.
    dir=$(tmp)
    conf_module k-reads 'module_config_files() { local id; for id in $(conf_get k-reads-ids IDS); do printf "k-reads-%s\n" "$id"; done; }'
    conf_write "$dir" k-reads "K_A='1'"
    conf_write "$dir" k-reads-ids "IDS='1'" "touch '$dir/RAN'"
    expect_config_fail "a hostile extra file read by module_config_files" "$dir/k-reads-ids.conf: line 2: " \
        "$dir" config show k-reads
    [[ ! -e $dir/RAN ]] || fail "config show ran an extra configuration file module_config_files read"
    dir=$(tmp)
    conf_write "$dir" k-reads "K_A='1'"
    conf_write "$dir" k-reads-ids "IDS='SECRETM'"
    chmod 0606 "$dir/k-reads-ids.conf"
    expect_config_fail "an unsafe extra file read by module_config_files" \
        "$dir/k-reads-ids.conf: writable by group or others" "$dir" config show k-reads
    # conf_load would run the file, so module_config_files cannot use it.
    conf_module l-loads 'module_config_files() { conf_load l-loads; printf "l-loads-%s\n" "${L_ID:-1}"; }'
    dir=$(tmp)
    conf_write "$dir" l-loads "L_ID='1'" "L_TOKEN='SECRETN'"
    expect_config_fail "module_config_files using conf_load" "conf_load" "$dir" config show l-loads
    # What a module prints on stderr never reaches the terminal.
    conf_module m-noisy 'module_config_files() { echo "noise SECRETO" >&2; printf "m-noisy-1\n"; }'
    dir=$(tmp)
    conf_write "$dir" m-noisy "M_A='1'"
    errfile=$(tmp)/stderr
    out=$(conf_launch "$dir" config show m-noisy 2>"$errfile") || fail "config show m-noisy failed: $out"
    no_secret "module_config_files stderr" "$out $(<"$errfile")"
    pass "config show never runs a file module_config_files reads, and discards its stderr"

    # Refusals travel on a channel of their own, never the module's stdout,
    # so a value a module prints cannot pose as one; every refusal message
    # is config show's own.
    conf_module n-prints 'module_config_files() { conf_get "$MODULE_NAME" LIST; }'
    dir=$(tmp)
    conf_write "$dir" n-prints "LIST='ok-name" "refuse:SECRETB2'"
    expect_config_fail "a printed value that looks like a refusal" \
        "module n-prints listed an invalid configuration name" "$dir" config show n-prints
    expect_config_fail "a printed value that looks like a refusal (json)" \
        "module n-prints listed an invalid configuration name" "$dir" config show --json n-prints
    # Lines in the channel's own form are, on stdout, only names.
    conf_write "$dir" n-prints "LIST='file n-prints'"
    expect_config_fail "a printed value in the refusal channel's form" \
        "module n-prints listed an invalid configuration name" "$dir" config show n-prints
    for line in load name; do
        conf_write "$dir" n-prints "LIST='$line'"
        out=$(conf_launch "$dir" config show n-prints 2>&1) \
            || fail "a printed value '$line' was taken for a refusal: $out"
    done
    conf_write "$dir" n-prints "LIST='SECRETB3'" "touch '$dir/RAN'"
    expect_config_fail "a refusal read through the channel" "$dir/n-prints.conf: line 2: " \
        "$dir" config show n-prints
    # A module that ignores conf_get's failure, and reads again, is still
    # refused: the first refusal stays on the channel.
    conf_module o-ignores 'module_config_files() { local i; for i in 1 2 3; do conf_get o-ignores-x K >/dev/null || true; done; printf "o-ignores-y\n"; }'
    conf_write "$dir" o-ignores "O_A='1'"
    conf_write "$dir" o-ignores-x "K='SECRETB4'" "junk line"
    conf_write "$dir" o-ignores-y "O_Y='1'"
    expect_config_fail "a refusal the module ignored" "$dir/o-ignores-x.conf: line 2: " \
        "$dir" config show o-ignores
    pass "config show takes refusals only from its own channel"

    # Regression guard for the fill guard itself: module_config_files often
    # captures conf_get's output through command substitution ("x=$(conf_get
    # ...)"), and every such call forks its own subshell. A per-shell
    # variable set inside one of those subshells cannot survive it, so a
    # guard against writing more than one refusal has to work by checking
    # the pipe itself (what fd 3 actually is), not shell state -- a variant
    # that checked shell state once regressed exactly this way, hanging
    # instead of refusing. A long, valid configuration name makes each
    # would-be duplicate refusal large enough that a few hundred of them
    # exceed the pipe's 64 KiB, so a broken guard hangs quickly rather than
    # needing thousands of iterations; timeout turns that hang into a fast,
    # named failure instead of stalling the whole suite.
    printf -v fillname 'f%.0s' $(seq 1 240)
    conf_module u-fills "module_config_files() { local i x; for ((i = 0; i < 400; i++)); do x=\$(conf_get $fillname K) || true; done; printf 'u-fills-y\n'; }"
    dir=$(tmp)
    conf_write "$dir" u-fills "U_A='1'"
    conf_write "$dir" "$fillname" "junk line"
    conf_write "$dir" u-fills-y "U_Y='1'"
    rc=0
    out=$(TOOLBOX_BIN_DIR=$(tmp) TOOLBOX_STATE_DIR=$(tmp) TOOLBOX_SYSTEMD_DIR=$(tmp) \
        TOOLBOX_CONF_DIR="$dir" PVE_TOOLBOX_ROOT="$conf_root" \
        timeout 30 "$conf_root/pve-toolbox" config show u-fills 2>&1) || rc=$?
    [[ $rc -ne 124 ]] || fail "config show hung on a module that retries a bad file through \$(conf_get ...) many times"
    [[ $rc -eq 1 ]] || fail "config show of a module that retries a bad file exited $rc, want 1: ${out:0:200}"
    [[ $out == *"$dir/$fillname.conf: line 1:"* ]] \
        || fail "config show of a module that retries a bad file did not name it: ${out:0:200}"
    pass "config show does not fill its refusal channel when a module retries a bad file many times through command substitution"

    # config show needs no temporary file: it works, and still refuses what
    # it must, with TMPDIR missing or in a directory nobody can write to.
    dir=$(tmp); conf_plant "$dir"
    big=$(printf 'b%.0s' {1..300000})
    conf_write "$dir" e-conf-extra "E_DIR='$big'" "E_KEY='SECRET3'"
    conf_write "$dir" o-ignores "O_A='1'"
    conf_write "$dir" o-ignores-x "K='SECRETB5'" "junk line"
    for tmpdir in "$(tmp)/missing" /proc; do
        if TMPDIR=$tmpdir mktemp >/dev/null 2>&1; then
            fail "TMPDIR=$tmpdir is writable, so it cannot stand for an unusable TMPDIR"
        fi
        out=$(TMPDIR=$tmpdir conf_launch "$dir" config show e-conf 2>&1) \
            || fail "config show with TMPDIR=$tmpdir failed: $out"
        no_secret "config show with TMPDIR=$tmpdir" "$out"
        [[ $out == *"e-conf-extra ("*"E_DIR"*"$big"* ]] \
            || fail "config show with TMPDIR=$tmpdir did not show every file"
        out=$(TMPDIR=$tmpdir conf_launch "$dir" config show --json e-conf 2>&1) \
            || fail "config show --json with TMPDIR=$tmpdir failed: $out"
        [[ $(jq -r '.files[1].keys[0].value' <<<"$out") == "$big" ]] \
            || fail "config show --json with TMPDIR=$tmpdir lost a large public value"
        TMPDIR=$tmpdir expect_config_fail "a refusal with TMPDIR=$tmpdir" "$dir/o-ignores-x.conf: line 2: " \
            "$dir" config show o-ignores
    done
    pass "config show works without a usable TMPDIR"

    # The parser is linear: each line is split on its quotes once. Proven by
    # a ratio between two input sizes rather than an absolute wall-clock
    # bound, so a slow or busy test runner cannot flake it: quadratic growth
    # would take about 16x as long for 4x the input, so a generous 10x bound
    # still catches a real regression while tolerating an ordinary slow
    # machine. $SECONDS is too coarse (whole seconds) for a small input, so
    # elapsed time is measured in milliseconds with the wall clock instead,
    # and a floor keeps a near-instant small run from making the ratio
    # unstable on its own.
    ms_now() { date +%s%N; }
    ms_ratio_ok() { # ms_ratio_ok <small-ms> <big-ms> -> true unless big grew worse than 10x a floored small
        local floor=$1
        ((floor >= 20)) || floor=20
        (($2 <= floor * 10))
    }
    dir=$(tmp)
    ( umask 077; for ((i = 0; i < 1000; i++)); do printf "E_K_%s='value %s'\n" "$i" "$i"; done > "$dir/e-conf.conf" )
    start=$(ms_now)
    out=$(conf_launch "$dir" config show e-conf) || fail "config show of 1000 keys failed"
    small=$((($(ms_now) - start) / 1000000))
    [[ $(grep -c '^  E_K_' <<<"$out") -eq 1000 ]] || fail "config show of 1000 keys did not show them all"
    dir=$(tmp)
    ( umask 077; for ((i = 0; i < 4000; i++)); do printf "E_K_%s='value %s'\n" "$i" "$i"; done > "$dir/e-conf.conf" )
    start=$(ms_now)
    out=$(conf_launch "$dir" config show e-conf) || fail "config show of 4000 keys failed"
    big=$((($(ms_now) - start) / 1000000))
    [[ $(grep -c '^  E_K_' <<<"$out") -eq 4000 ]] || fail "config show of 4000 keys did not show them all"
    ms_ratio_ok "$small" "$big" \
        || fail "config show of 4000 keys took ${big}ms against ${small}ms for 1000: parsing looks worse than linear"
    pass "config show parses 4000 keys in ${big}ms against ${small}ms for 1000 (linear, not quadratic)"

    dir=$(tmp)
    printf -v big_value "a'%.0s" $(seq 1 4000)
    ( umask 077; { printf "E_DIR='"; printf "a'\\\\''%.0s" $(seq 1 1000); printf "'\n"; } > "$dir/e-conf.conf" )
    start=$(ms_now)
    out=$(conf_launch "$dir" config show --json e-conf) || fail "config show of 1000 escaped quotes failed"
    small2=$((($(ms_now) - start) / 1000000))
    ( umask 077; { printf "E_DIR='"; printf "a'\\\\''%.0s" $(seq 1 4000); printf "'\n"; } > "$dir/e-conf.conf" )
    start=$(ms_now)
    out=$(conf_launch "$dir" config show --json e-conf) || fail "config show of 4000 escaped quotes failed"
    big2=$((($(ms_now) - start) / 1000000))
    [[ $(jq -r '.files[0].keys[0].value' <<<"$out") == "$big_value" ]] \
        || fail "config show of 4000 escaped quotes did not return the stored value"
    ms_ratio_ok "$small2" "$big2" \
        || fail "config show of 4000 escaped quotes on one line took ${big2}ms against ${small2}ms for 1000: parsing looks worse than linear"
    pass "config show parses 4000 escaped quotes on one line in ${big2}ms against ${small2}ms for 1000 (linear, not quadratic)"

    # --- what it refuses (P4-2): each names the file, exits 1 and prints
    # nothing from any file, including the ones that were fine.
    dir=$(tmp); conf_plant "$dir"
    mv "$dir/e-conf.conf" "$dir/real.conf"
    ln -s real.conf "$dir/e-conf.conf"
    expect_config_fail "a symlinked configuration file" "$dir/e-conf.conf" "$dir" config show e-conf
    expect_config_fail "a symlinked configuration file (json)" "symbolic link" "$dir" config show --json e-conf

    dir=$(tmp); conf_plant "$dir"
    mv "$dir/e-conf-extra.conf" "$dir/real.conf"
    ln -s real.conf "$dir/e-conf-extra.conf"
    expect_config_fail "a symlinked extra file" "$dir/e-conf-extra.conf" "$dir" config show e-conf

    dir=$(tmp); conf_plant "$dir"
    chmod 0620 "$dir/e-conf.conf"
    expect_config_fail "a group-writable file" "$dir/e-conf.conf" "$dir" config show e-conf
    expect_config_fail "a group-writable file (reason)" "writable by group or others" "$dir" config show e-conf
    chmod 0602 "$dir/e-conf.conf"
    expect_config_fail "a world-writable file" "$dir/e-conf.conf" "$dir" config show e-conf

    dir=$(tmp); conf_plant "$dir"
    mkfifo "$dir/e-conf-extra.conf.fifo"
    rm -f "$dir/e-conf-extra.conf"
    mv "$dir/e-conf-extra.conf.fifo" "$dir/e-conf-extra.conf"
    expect_config_fail "a FIFO" "$dir/e-conf-extra.conf" "$dir" config show e-conf
    expect_config_fail "a FIFO (reason)" "not a regular file" "$dir" config show e-conf

    dir=$(tmp); conf_plant "$dir"
    if chown 65534 "$dir/e-conf.conf" 2>/dev/null; then
        expect_config_fail "a file owned by another user" "$dir/e-conf.conf" "$dir" config show e-conf
        expect_config_fail "a file owned by another user (reason)" "not owned by root" "$dir" config show e-conf
        chown 0 "$dir/e-conf.conf"
        chown 65534 "$dir"
        expect_config_fail "a directory owned by another user" "$dir" "$dir" config show e-conf
    else
        if [[ ${CLI_ROOT_TEST_REQUIRED:-0} -eq 1 ]]; then
            fail "config show wrong-owner cases required but cannot chown to uid 65534 (unmapped in this namespace)"
        fi
        printf 'skip config show wrong-owner cases, cannot chown to uid 65534 (unmapped in this namespace)\n'
    fi
    # The owner check itself, wherever chown cannot run: a stat that reports
    # another owner for the file (and root for everything else) is refused.
    shim=$(tmp)
    dir=$(tmp); conf_plant "$dir"
    printf '%s\n' '#!/usr/bin/env bash' \
        "[[ \${*: -1} == '$dir/e-conf.conf' ]] && { printf '65534 600\\n'; exit 0; }" \
        "exec '$(command -v stat)' \"\$@\"" > "$shim/stat"
    chmod 0755 "$shim/stat"
    PATH="$shim:$PATH" expect_config_fail "a file stat reports as owned by another user" \
        "$dir/e-conf.conf: not owned by root" "$dir" config show e-conf

    real=$(tmp); conf_plant "$real"
    link=$(tmp)/conf
    ln -s "$real" "$link"
    expect_config_fail "a symlinked configuration directory" "$link" "$link" config show e-conf
    expect_config_fail "a symlinked configuration directory, trailing slash" "$link: it is a symbolic link" \
        "$link/" config show e-conf
    expect_config_fail "a symlinked configuration directory, trailing slashes" "$link: it is a symbolic link" \
        "$link//" config show e-conf
    expect_config_fail "a symlinked configuration directory, trailing /." "$link: it is a symbolic link" \
        "$link/." config show e-conf
    dir=$(tmp); conf_plant "$dir"; chmod 0770 "$dir"
    expect_config_fail "a group-writable configuration directory" "$dir" "$dir" config show e-conf
    notdir=$(tmp)/conf; printf 'x\n' > "$notdir"
    expect_config_fail "a configuration directory that is a file" "not a directory" "$notdir" config show e-conf

    dir=$(tmp); conf_write "$dir" h-badname "H_TOKEN='SECRET11'"
    expect_config_fail "an invalid name from module_config_files" \
        "module h-badname listed an invalid configuration name" "$dir" config show h-badname
    out=$(conf_launch "$dir" config show h-badname 2>&1 || true)
    [[ $out != *escape* ]] || fail "config show echoed the invalid name module_config_files printed: $out"
    dir=$(tmp); conf_write "$dir" i-fails "I_TOKEN='SECRET12'"
    expect_config_fail "a failing module_config_files" "i-fails" "$dir" config show i-fails
    pass "config show refuses unsafe configuration files and directories, naming them"

    # --- the real modules' declarations, on configuration conf_set wrote
    real_launch() { # real_launch <conf-dir> [args...] -> the repository's launcher
        local dir=$1; shift
        TOOLBOX_BIN_DIR=$(tmp) TOOLBOX_STATE_DIR=$(tmp) TOOLBOX_SYSTEMD_DIR=$(tmp) \
        TOOLBOX_CONF_DIR=$dir "$ROOT/pve-toolbox" "$@"
    }
    real_hidden() { # real_hidden <what> <text> <json> <key>... -> each is set and hidden
        local what=$1 text=$2 json=$3 key
        shift 3
        for key in "$@"; do
            grep -Eq "^  $key +\(set, hidden\)$" <<<"$text" \
                || fail "$what: $key is not shown as (set, hidden): $text"
            jq -e --arg k "$key" '[.files[].keys[] | select(.key == $k)] | length > 0
                and all(.set and .hidden and (has("value") | not))' <<<"$json" >/dev/null \
                || fail "$what: --json does not hide $key: $json"
        done
    }
    real_public() { # real_public <what> <text> <json> <key> <value> -> shown as stored
        local what=$1 text=$2 json=$3 key=$4 value=$5
        grep -Fqx -- "$(printf '  %-28s %s' "$key" "$value")" <<<"$text" \
            || fail "$what: $key is not shown as $value: $text"
        jq -e --arg k "$key" --arg v "$value" '[.files[].keys[] | select(.key == $k)] | length > 0
            and all(.hidden == false and .value == $v)' <<<"$json" >/dev/null \
            || fail "$what: --json does not show $key as $value: $json"
    }

    # config-backup: the webhook, the remote with a credential in it, the age
    # recipient, the deploy key and the token file stay hidden.
    dir=$(tmp)
    (
        TOOLBOX_CONF_DIR=$dir
        # shellcheck source=lib/common.sh
        source "$ROOT/lib/common.sh"
        conf_set config-backup DISCORD_WEBHOOK 'https://discord.com/api/webhooks/123/LEAKwebhookabcdefghijklmnop'
        conf_set config-backup CB_ARCHIVE_DIR /var/lib/pve-toolbox/config-backup
        conf_set config-backup CB_RETENTION_COUNT 30
        conf_set config-backup CB_AGE_RECIPIENT age1leakrecipientLEAKvalue
        conf_set config-backup CB_SECRET_ALLOW 'pve/user.cfg:credential derived/dpkg-selections.txt:credential'
        conf_set config-backup CB_GIT_DIR /var/lib/pve-toolbox/config-backup.git
        conf_set config-backup CB_GIT_REMOTE 'https://user:tok@host/x'
        conf_set config-backup CB_GIT_BRANCH master
        conf_set config-backup CB_GIT_SSH_KEY /root/.ssh/LEAK-deploy-key
        conf_set config-backup CB_GIT_TOKEN_FILE /root/LEAK-token-file
    )
    out=$(real_launch "$dir" config show config-backup) || fail "config show config-backup failed: $out"
    json=$(real_launch "$dir" config show --json config-backup) || fail "config show --json config-backup failed: $json"
    # CB_SECRET_ALLOW is a key name here, so the planted values carry LEAK.
    for text in "$out" "$json"; do
        for leak in LEAK user:tok tok@ host/x webhooks age1; do
            [[ $text != *"$leak"* ]] || fail "config show config-backup leaked '$leak': $text"
        done
    done
    real_hidden "config show config-backup" "$out" "$json" \
        DISCORD_WEBHOOK CB_AGE_RECIPIENT CB_GIT_REMOTE CB_GIT_SSH_KEY CB_GIT_TOKEN_FILE
    real_public "config show config-backup" "$out" "$json" CB_ARCHIVE_DIR /var/lib/pve-toolbox/config-backup
    real_public "config show config-backup" "$out" "$json" CB_RETENTION_COUNT 30
    real_public "config show config-backup" "$out" "$json" CB_GIT_DIR /var/lib/pve-toolbox/config-backup.git
    real_public "config show config-backup" "$out" "$json" CB_GIT_BRANCH master
    real_public "config show config-backup" "$out" "$json" CB_SECRET_ALLOW \
        'pve/user.cfg:credential derived/dpkg-selections.txt:credential'
    pass "config show config-backup hides the webhook, the remote, the recipient and the key and token paths"

    # komodo-periphery: the per-guest records are shown after the ID lists,
    # an invalid ID names no file, and the SSH key and known-hosts paths
    # stay hidden.
    dir=$(tmp)
    identity=$(printf '%064d' 7)
    (
        TOOLBOX_CONF_DIR=$dir
        # shellcheck source=lib/common.sh
        source "$ROOT/lib/common.sh"
        conf_set komodo-periphery KP_IDS '101 abc 102'
        conf_set komodo-periphery-abc KP_KEY_FILE /root/SECRET-abc
        conf_set komodo-periphery-101 KP_PENDING ''
        conf_set komodo-periphery-101 KP_IDENTITY "$identity"
        conf_set komodo-periphery-101 KP_VERSION 2.3.3
        conf_set komodo-periphery-qemu KP_VM_IDS '201 x/y'
        conf_set komodo-periphery-qemu-201 KP_TRANSPORT ssh
        conf_set komodo-periphery-qemu-201 KP_ADDRESS vm201.example
        conf_set komodo-periphery-qemu-201 KP_PORT 2222
        conf_set komodo-periphery-qemu-201 KP_KEY_FILE /root/.ssh/SECRET-periphery-key
        conf_set komodo-periphery-qemu-201 KP_KNOWN_HOSTS /root/.ssh/SECRET-known-hosts
        conf_set komodo-periphery-qemu-201 KP_HOST_FINGERPRINT SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG
        conf_set komodo-periphery-qemu-201 KP_VERSION 2.3.3
    )
    out=$(real_launch "$dir" config show komodo-periphery) || fail "config show komodo-periphery failed: $out"
    json=$(real_launch "$dir" config show --json komodo-periphery) || fail "config show --json komodo-periphery failed: $json"
    no_secret "config show komodo-periphery" "$out"
    no_secret "config show --json komodo-periphery" "$json"
    [[ $out == "komodo-periphery ("*$'\n'"komodo-periphery-qemu ("*$'\n'"komodo-periphery-101 ("*$'\n'"komodo-periphery-qemu-201 ("* ]] \
        || fail "config show komodo-periphery did not show the ID lists and then each record: $out"
    [[ $out != *komodo-periphery-abc* && $out != *komodo-periphery-102* ]] \
        || fail "config show komodo-periphery showed a file for an invalid or absent ID: $out"
    jq -e '[.files[].name] == ["komodo-periphery","komodo-periphery-qemu","komodo-periphery-101","komodo-periphery-qemu-201"]' \
        <<<"$json" >/dev/null || fail "config show --json komodo-periphery files wrong: $json"
    real_hidden "config show komodo-periphery" "$out" "$json" KP_KEY_FILE KP_KNOWN_HOSTS
    real_public "config show komodo-periphery" "$out" "$json" KP_IDS '101 abc 102'
    real_public "config show komodo-periphery" "$out" "$json" KP_VM_IDS '201 x/y'
    real_public "config show komodo-periphery" "$out" "$json" KP_IDENTITY "$identity"
    real_public "config show komodo-periphery" "$out" "$json" KP_ADDRESS vm201.example
    real_public "config show komodo-periphery" "$out" "$json" KP_PORT 2222
    real_public "config show komodo-periphery" "$out" "$json" KP_HOST_FINGERPRINT \
        SHA256:abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG
    grep -Eq '^  KP_PENDING +\(not set\)$' <<<"$out" || fail "config show komodo-periphery: KP_PENDING not (not set): $out"
    pass "config show komodo-periphery shows each guest record and hides the SSH key and known-hosts paths"

    # zfs-replication: job names are chosen so the field they add trips a
    # careless glob -- "src_opts" normalizes to JOB_SRC_OPTS_OPTS (an _OPTS
    # key whose job name itself contains "SRC") and "a_path" to
    # JOB_A_PATH_OPTS (a job name containing "PATH") -- and the webhook and
    # every job's OPTS still have to stay hidden regardless.
    dir=$(tmp)
    (
        TOOLBOX_CONF_DIR=$dir
        # shellcheck source=lib/common.sh
        source "$ROOT/lib/common.sh"
        conf_set zfs-replication DISCORD_WEBHOOK 'https://discord.com/api/webhooks/123/LEAKwebhookabcdefghijklmnop'
        conf_set zfs-replication LOG_DIR /var/log/pve-toolbox
        conf_set zfs-replication NOTIFY_START 1
        conf_set zfs-replication JOBS 'src_opts a_path'
        conf_set zfs-replication JOB_SRC_OPTS_SRC tank/src-opts
        conf_set zfs-replication JOB_SRC_OPTS_DST backup/src-opts
        conf_set zfs-replication JOB_SRC_OPTS_OPTS '--recursive --identifier LEAKOPTS1'
        conf_set zfs-replication JOB_SRC_OPTS_CHOWN 100:100
        conf_set zfs-replication JOB_SRC_OPTS_CHMOD 750
        conf_set zfs-replication JOB_SRC_OPTS_PATH /srv/src-opts
        conf_set zfs-replication JOB_A_PATH_SRC tank/a-path
        conf_set zfs-replication JOB_A_PATH_DST backup/a-path
        conf_set zfs-replication JOB_A_PATH_OPTS '--compress=zstd LEAKOPTS2'
        conf_set zfs-replication JOB_A_PATH_CHOWN 200:200
        conf_set zfs-replication JOB_A_PATH_CHMOD 640
        conf_set zfs-replication JOB_A_PATH_PATH /srv/a-path
    )
    out=$(real_launch "$dir" config show zfs-replication) || fail "config show zfs-replication failed: $out"
    json=$(real_launch "$dir" config show --json zfs-replication) || fail "config show --json zfs-replication failed: $json"
    for text in "$out" "$json"; do
        for leak in LEAK webhooks LEAKOPTS1 LEAKOPTS2; do
            [[ $text != *"$leak"* ]] || fail "config show zfs-replication leaked '$leak': $text"
        done
    done
    real_hidden "config show zfs-replication" "$out" "$json" \
        DISCORD_WEBHOOK JOB_SRC_OPTS_OPTS JOB_A_PATH_OPTS
    real_public "config show zfs-replication" "$out" "$json" LOG_DIR /var/log/pve-toolbox
    real_public "config show zfs-replication" "$out" "$json" NOTIFY_START 1
    real_public "config show zfs-replication" "$out" "$json" JOBS 'src_opts a_path'
    real_public "config show zfs-replication" "$out" "$json" JOB_SRC_OPTS_SRC tank/src-opts
    real_public "config show zfs-replication" "$out" "$json" JOB_SRC_OPTS_DST backup/src-opts
    real_public "config show zfs-replication" "$out" "$json" JOB_SRC_OPTS_CHOWN 100:100
    real_public "config show zfs-replication" "$out" "$json" JOB_SRC_OPTS_CHMOD 750
    real_public "config show zfs-replication" "$out" "$json" JOB_SRC_OPTS_PATH /srv/src-opts
    real_public "config show zfs-replication" "$out" "$json" JOB_A_PATH_SRC tank/a-path
    real_public "config show zfs-replication" "$out" "$json" JOB_A_PATH_DST backup/a-path
    real_public "config show zfs-replication" "$out" "$json" JOB_A_PATH_CHOWN 200:200
    real_public "config show zfs-replication" "$out" "$json" JOB_A_PATH_CHMOD 640
    real_public "config show zfs-replication" "$out" "$json" JOB_A_PATH_PATH /srv/a-path
    pass "config show zfs-replication shows job fields and hides the webhook and every job's OPTS"
fi
