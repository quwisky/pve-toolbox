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
for c in menu ui list install update check status doctor lxc-update uninstall link self-update help; do
    [[ $help == *"  $c "* ]] || fail "--help does not list $c"
done
[[ $help == *"pve-toolbox help <command>"* ]] || fail "--help lacks the per-command hint"
[[ $help == *"--json, --quiet"*"status, check, doctor"* ]] \
    || fail "--help no longer mentions --json/--quiet and where they apply"
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
lxc_help=$(launch help lxc-update)
lxc_root_count=$(grep -o "Requires root" <<<"$lxc_help" | wc -l)
[[ $lxc_root_count -eq 1 ]] \
    || fail "help lxc-update should say 'Requires root' exactly once, got $lxc_root_count"
# Wrapped description lines carry no trailing spaces, in any command's help.
for c in "" menu ui list install update check status doctor lxc-update uninstall link self-update help; do
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

# _man needs no root: the whole test suite already runs unprivileged, so a
# plain, successful call here is the proof.
[[ $(id -u) -ne 0 ]] || fail "test suite must not run as root"
launch _man >/dev/null || fail "_man failed as a normal user"
pass "_man works as a normal user"

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
