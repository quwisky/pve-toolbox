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

got=$(complete_words 1 ./pve-toolbox "")
[[ " $got " == *" install "* ]] || fail "no commands offered, got: $got"

got=$(complete_words 2 ./pve-toolbox install "")
[[ " $got " == *" zfs-scrub "* ]] || fail "no modules offered, got: $got"

# A module already on the line must not be offered again.
got=$(complete_words 3 ./pve-toolbox install zfs-scrub "")
[[ " $got " != *" zfs-scrub "* ]] || fail "re-offered a module already given"

# Flags are accepted anywhere, so the command is the first non-flag word.
got=$(complete_words 3 ./pve-toolbox -y install "")
[[ " $got " == *" zfs-scrub "* ]] || fail "flag before command broke it, got: $got"

got=$(complete_words 2 ./pve-toolbox link "")
[[ -z $got ]] || fail "link takes no arguments, got: $got"

pass "bash completion"

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
