#!/usr/bin/env bash
#
# Smoke tests for the launcher. No root, no systemd, no network: every
# path here has to work on a plain checkout, which is what CI has.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

# One parent dir, everything under it. tmp() is called from command
# substitutions, so it cannot record what it made in a variable out here.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
tmp() { mktemp -d "$WORK/XXXXXX"; }

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# Every install path writes somewhere; point them all at throwaway dirs so a
# test run cannot touch the machine it runs on.
launch() { # launch <path-to-launcher> [args...]
    local bin=$1; shift
    TOOLBOX_BIN_DIR=$(tmp) TOOLBOX_STATE_DIR=$(tmp) \
    TOOLBOX_SYSTEMD_DIR=$(tmp) TOOLBOX_CONF_DIR=$(tmp) \
    "$bin" "$@"
}

# --- the launcher runs, in place and through a symlink ----------------------

launch ./pve-toolbox list >/dev/null || fail "launcher smoke test"
pass "launcher smoke test"

# `pve-toolbox link` installs a symlink, and resolving it is how the launcher
# finds lib/ and modules/. Running in place is the one path that cannot catch
# a regression there.
link_dir=$(tmp)
ln -s "$ROOT/pve-toolbox" "$link_dir/pve-toolbox"
launch "$link_dir/pve-toolbox" list >/dev/null || fail "launcher via symlink"
pass "launcher via symlink"

# --- completion candidates --------------------------------------------------

for target in commands modules tags; do
    [[ -n $(launch ./pve-toolbox _complete "$target") ]] \
        || fail "completion target '$target' produced nothing"
done
if launch ./pve-toolbox _complete modules | grep -Fxq native-notifications; then
    fail "obsolete notification provisioning remains discoverable"
fi
launch ./pve-toolbox _complete bogus 2>/dev/null \
    && fail "completion accepted an unknown target"
pass "completion candidates"

# --- the bash completion function itself ------------------------------------

# shellcheck source=completions/pve-toolbox.bash
source "$ROOT/completions/pve-toolbox.bash"

complete_words() { # complete_words <cword> <word>... -> prints candidates
    local cword=$1; shift
    COMP_WORDS=("$@"); COMP_CWORD=$cword; COMPREPLY=()
    _pve_toolbox
    printf '%s' "${COMPREPLY[*]:-}"
}

has()    { [[ " $1 " == *" $2 "* ]]; }
has_not() { [[ " $1 " != *" $2 "* ]]; }

# Commands, and every verb the launcher dispatches.
got=$(complete_words 1 ./pve-toolbox "")
for verb in menu ui list install update check status doctor uninstall link self-update; do
    has "$got" "$verb" || fail "commands missing $verb, got: $got"
done
pass "bash offers every command"

# compgen filters by prefix; the completion only supplies the candidates.
got=$(complete_words 1 ./pve-toolbox "in")
[[ $got == install ]] || fail "prefix in<TAB> should give install alone, got: $got"
got=$(complete_words 1 ./pve-toolbox "self")
[[ $got == self-update ]] || fail "prefix self<TAB> should give self-update, got: $got"
pass "bash filters commands by prefix"

got=$(complete_words 2 ./pve-toolbox install "")
has "$got" zfs-scrub || fail "no modules offered for install, got: $got"
has_not "$got" native-notifications \
    || fail "obsolete notification provisioning offered for install, got: $got"
got=$(complete_words 2 ./pve-toolbox install "zfs-")
has "$got" zfs-scrub       || fail "prefix zfs-<TAB> dropped zfs-scrub, got: $got"
has "$got" zfs-replication || fail "prefix zfs-<TAB> dropped zfs-replication, got: $got"
has_not "$got" scrutiny-collectors || fail "prefix zfs-<TAB> kept a non-match, got: $got"
pass "bash offers modules, filtered by prefix"

# A module already on the line is not offered a second time.
got=$(complete_words 3 ./pve-toolbox install zfs-scrub "")
has_not "$got" zfs-scrub       || fail "re-offered a module already given, got: $got"
has "$got" zfs-replication     || fail "dropped the modules still available, got: $got"
pass "bash drops what is already on the line"

# update, check and status take module names too.
for verb in update check status; do
    got=$(complete_words 2 ./pve-toolbox "$verb" "")
    has "$got" zfs-scrub || fail "$verb offered no modules, got: $got"
done
pass "bash offers modules for update, check and status"

# uninstall offers only what is installed, which in a checkout is nothing.
got=$(complete_words 2 ./pve-toolbox uninstall "")
[[ -z $got ]] || fail "uninstall offered a module in a bare checkout, got: $got"
pass "bash offers only installed modules for uninstall"

# list takes a single tag, gathered from every module's MODULE_TAGS.
got=$(complete_words 2 ./pve-toolbox list "")
has "$got" storage || fail "list offered no tags, got: $got"
has "$got" zfs     || fail "list dropped a tag, got: $got"
got=$(complete_words 3 ./pve-toolbox list storage "")
[[ -z $got ]] || fail "list takes one tag, got: $got"
pass "bash offers tags for list, once"

# Flags are accepted anywhere, so the command is the first non-flag word.
got=$(complete_words 3 ./pve-toolbox -y install "")
has "$got" zfs-scrub || fail "a flag before the command broke it, got: $got"
pass "bash finds the command past a flag"

got=$(complete_words 1 ./pve-toolbox "-")
for flag in -y --yes -f --force --json --quiet -V --version -h --help; do
    has "$got" "$flag" || fail "flags missing $flag, got: $got"
done
got=$(complete_words 1 ./pve-toolbox "--f")
[[ $got == --force ]] || fail "prefix --f<TAB> should give --force, got: $got"
pass "bash offers flags"

# menu, ui, link and self-update take nothing, and neither does a typo.
for verb in menu ui doctor link self-update definitely-not-a-command; do
    got=$(complete_words 2 ./pve-toolbox "$verb" "")
    [[ -z $got ]] || fail "$verb should offer nothing, got: $got"
done
pass "bash offers nothing where nothing is taken"

# --- usage -------------------------------------------------------------------

# usage() read a hardcoded line range of the header comment, so growing that
# header spilled `set -euo pipefail` and the code under it into --help.
help=$(launch ./pve-toolbox --help)
[[ $help == *"pve-toolbox list [tag]"* ]] || fail "--help lost the command list"
[[ $help == *"Flags:"* ]]                 || fail "--help lost the flags line"
[[ $help != *"set -euo"* ]]               || fail "--help leaked shell code"
[[ $help != *"#"* ]]                      || fail "--help leaked a comment marker"
pass "usage stops at the end of the header"

# The package launcher lives separately from its modules and libraries. An
# explicit root exercises that layout without writing into /usr during tests.
expected_version=$(<VERSION)
[[ $(PVE_TOOLBOX_ROOT="$ROOT" launch ./pve-toolbox --version) == "pve-toolbox $expected_version" ]] \
    || fail "--version did not read the packaged version file"
for verb in link self-update; do
    res=$(PVE_TOOLBOX_ROOT="$ROOT" launch ./pve-toolbox "$verb" 2>&1 || true)
    [[ $res == *"managed by apt"* ]] || fail "packaged $verb was not refused: $res"
done
pass "packaged installs report their version and defer to apt"

# --- installed detection -----------------------------------------------------

# status_line normalises an empty status to the exact string is_installed
# compares against, and every caller - update, check, uninstall completion -
# turns on getting that right. Nothing is installed in a checkout, so every
# module has to report so and none may appear as installed.
list=$(launch ./pve-toolbox list)
module_count=$(launch ./pve-toolbox _complete modules | wc -l)
while read -r mod; do
    [[ $list == *"$mod"* ]] || fail "list did not mention $mod"
done < <(launch ./pve-toolbox _complete modules)
[[ $(launch ./pve-toolbox list | grep -c 'status: not installed') -eq $module_count ]] \
    || fail "expected every discovered module to be uninstalled"
[[ -z $(launch ./pve-toolbox _complete installed) ]] \
    || fail "_complete installed named a module in a bare checkout"
pass "nothing reads as installed in a checkout"

# --- the command line's per-module dispatch ----------------------------------

# cmd_each is what install/update/check/status/uninstall all go through, and
# nothing exercised it. With no module names it filters to what is installed,
# which in a checkout is nothing.
for verb in update check status; do
    res=$(launch ./pve-toolbox "$verb" 2>&1) || fail "$verb with no args exited non-zero"
    [[ $res == *"no installed modules"* ]] || fail "$verb said: $res"
done
pass "update, check and status do nothing when nothing is installed"

# install and uninstall refuse to guess, because both are destructive in a way
# update and status are not.
for verb in install uninstall; do
    launch ./pve-toolbox "$verb" >/dev/null 2>&1 \
        && fail "$verb with no module name should have failed"
    res=$(launch ./pve-toolbox "$verb" 2>&1 || true)
    [[ $res == *"needs a module name"* ]] || fail "$verb said: $res"
done
pass "install and uninstall demand a module name"

# A named module is acted on whether or not it is installed - that is how you
# ask about one. module_status exits 1 to mean "not installed", so status has
# to read that as the answer rather than announcing a failure.
res=$(launch ./pve-toolbox status zfs-scrub 2>&1) || fail "status <module> exited non-zero"
[[ $res == *"not installed"* ]] || fail "status did not report the state: $res"
[[ $res != *"failed"* ]] || fail "status called a not-installed module failed: $res"
pass "status names an uninstalled module without calling it a failure"

# Per-module commands may continue after one module fails, but their final exit
# status must still tell automation that the requested operation was incomplete.
failure_root=$(tmp)
mkdir -p "$failure_root/lib" "$failure_root/modules/failing"
cp "$ROOT/lib/common.sh" "$ROOT/lib/discord.sh" "$ROOT/lib/doctor.sh" "$ROOT/lib/pve.sh" \
    "$ROOT/lib/report.sh" "$failure_root/lib/"
printf '%s\n' \
    'MODULE_NAME="failing"' \
    'MODULE_TITLE="Failing fixture"' \
    'MODULE_DESC="returns a deliberate error"' \
    'MODULE_TAGS="test"' \
    'module_status() { printf installed; }' \
    'module_status_long() { printf installed; }' \
    'module_install() { return 42; }' \
    'module_update() { return 42; }' \
    'module_uninstall() { return 42; }' \
    > "$failure_root/modules/failing/module.sh"
for verb in install update check uninstall; do
    PVE_TOOLBOX_ROOT="$failure_root" launch ./pve-toolbox "$verb" failing \
        >/dev/null 2>&1 && fail "$verb hid a module failure behind exit 0"
done
pass "per-module command failures reach the launcher exit status"

launch ./pve-toolbox status definitely-not-a-module >/dev/null 2>&1 \
    && fail "an unknown module should have failed"
res=$(launch ./pve-toolbox status definitely-not-a-module 2>&1 || true)
[[ $res == *"unknown module"* ]] || fail "unknown module said: $res"
pass "an unknown module is rejected"

launch ./pve-toolbox definitely-not-a-command >/dev/null 2>&1 \
    && fail "an unknown command should have failed"
pass "an unknown command is rejected"
