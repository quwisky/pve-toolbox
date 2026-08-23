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
for verb in menu ui list install update check status uninstall link self-update; do
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
for flag in -y --yes -f --force -h --help; do
    has "$got" "$flag" || fail "flags missing $flag, got: $got"
done
got=$(complete_words 1 ./pve-toolbox "--f")
[[ $got == --force ]] || fail "prefix --f<TAB> should give --force, got: $got"
pass "bash offers flags"

# menu, ui, link and self-update take nothing, and neither does a typo.
for verb in menu ui link self-update definitely-not-a-command; do
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

# --- installed detection -----------------------------------------------------

# status_line normalises an empty status to the exact string is_installed
# compares against, and every caller - update, check, uninstall completion -
# turns on getting that right. Nothing is installed in a checkout, so every
# module has to report so and none may appear as installed.
list=$(launch ./pve-toolbox list)
while read -r mod; do
    [[ $list == *"$mod"* ]] || fail "list did not mention $mod"
done < <(launch ./pve-toolbox _complete modules)
[[ $(launch ./pve-toolbox list | grep -c 'status: not installed') -eq 3 ]] \
    || fail "expected three uninstalled modules in list"
[[ -z $(launch ./pve-toolbox _complete installed) ]] \
    || fail "_complete installed named a module in a bare checkout"
pass "nothing reads as installed in a checkout"
