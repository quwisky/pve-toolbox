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
# setpriv), skip with the reason instead of failing -- real root in CI has
# the mapping and must take the real path.
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
        "E_DIR='/srv/b'" '#' > "$dir/e-conf.conf"
      printf '%s' "E_JOB_E_SRC='no newline at the end'" >> "$dir/e-conf.conf" )
    out=$(conf_launch "$dir" config show e-conf) || fail "config show of a valid conf_set file failed: $out"
    no_secret "config show of a valid conf_set file" "$out"
    order=$(grep -oE '^  E_[A-Z_]+' <<<"$out" | tr -d ' ' | tr '\n' ' ')
    [[ $order == "E_DIR E_JOB_A_SRC E_JOB_B_SRC E_JOB_C_SRC E_WEBHOOK E_JOB_D_SRC E_JOB_E_SRC " ]] \
        || fail "config show keys not in first-appearance order: $order"
    grep -Eq '^  E_DIR +/srv/b$' <<<"$out" || fail "the last assignment of a key did not win: $out"
    grep -Eq '^  E_JOB_A_SRC +first; second$' <<<"$out" || fail "a multi-line value was not shown cleaned: $out"
    grep -Eq '^  E_JOB_C_SRC +\(not set\)$' <<<"$out" || fail "an empty value was not (not set): $out"
    grep -Eq '^  E_WEBHOOK +\(set, hidden\)$' <<<"$out" || fail "E_WEBHOOK was not hidden: $out"
    [[ $(conf_value "$dir" E_JOB_A_SRC) == "first; second" ]] || fail "multi-line value wrong in JSON"
    [[ $(conf_value "$dir" E_JOB_B_SRC) == "it's" ]] || fail "a '\\'' value was not unescaped"
    [[ $(conf_value "$dir" E_JOB_C_SRC) == "" ]] || fail "an empty value was not empty"
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
    # no planted secret anywhere. Line 3 is the offending line in each.
    printf_fn='printf() { if [[ $1 == '"'"'ok\0'"'"' ]]; then builtin printf '"'"'ok\0'"'"'; else builtin printf '"'"'%s\0%s\0%s\0%s\0'"'"' "$2" 1 1 "${!2}"; fi; }'
    esc=$'\e'
    for bad in "$printf_fn" \
        'declare() { builtin printf '"'"'%s'"'"' "$_cfgscan_functions"; }' \
        'builtin() { :; }' 'command() { :; }' 'function helper { :; }' 'readonly -f conf_file' \
        "trap 'printf \"%s\\0\" E_DIR 1 1 \"\$E_WEBHOOK\" ok' EXIT" \
        "trap 'printf \"%s\\0\" E_DIR 1 1 \"\$E_WEBHOOK\"' DEBUG" \
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

    # The parser is linear: 5000 keys parse in well under the bound.
    dir=$(tmp)
    ( umask 077; for ((i = 0; i < 5000; i++)); do printf "E_K_%s='value %s'\n" "$i" "$i"; done > "$dir/e-conf.conf" )
    start=$SECONDS
    out=$(conf_launch "$dir" config show e-conf) || fail "config show of 5000 keys failed"
    elapsed=$((SECONDS - start))
    [[ $(grep -c '^  E_K_' <<<"$out") -eq 5000 ]] || fail "config show of 5000 keys did not show them all"
    [[ $elapsed -lt 10 ]] || fail "config show of 5000 keys took ${elapsed}s"
    pass "config show parses 5000 keys in ${elapsed}s"

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
fi
