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

# --- version comparison -----------------------------------------------------

# Sourced in-process, so point every path at a throwaway first. Without this
# the rest of the file inherits /usr/local/bin and /var/lib/pve-toolbox, and
# anything added below could write to the host it is testing on.
TOOLBOX_BIN_DIR=$(tmp)
TOOLBOX_LIB_DIR=$(tmp)
TOOLBOX_CONF_DIR=$(tmp)
TOOLBOX_STATE_DIR=$(tmp)
TOOLBOX_SYSTEMD_DIR=$(tmp)
export TOOLBOX_BIN_DIR TOOLBOX_LIB_DIR TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR TOOLBOX_SYSTEMD_DIR

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# is_newer <candidate> <current> <expected yes|no>
newer_is() {
    local got=no
    is_newer "$1" "$2" && got=yes
    [[ $got == "$3" ]] || fail "is_newer '$1' '$2' returned $got, wanted $3"
}

# A release tag carries a leading v and `--version` output does not, so the
# two arrive spelled differently for the same release. Comparing them raw made
# every check report the installed version as an available update.
newer_is v1.69.1 1.69.1  no
newer_is 1.69.1  v1.69.1 no
newer_is 1.69.1  1.69.1  no
newer_is v1.69.1 v1.69.1 no

newer_is v1.70.0 1.69.1  yes
newer_is 1.70.0  v1.69.1 yes
newer_is 1.69.1  1.70.0  no

# Version order, not string order.
newer_is 1.10.0 1.9.0  yes
newer_is 1.9.0  1.10.0 no

# Nothing known about the current version means anything is an upgrade.
newer_is 1.0.0 ""        yes
newer_is 1.0.0 "unknown" yes

# ...but an unknown candidate is not an upgrade over anything.
newer_is ""        1.0.0     no
newer_is "unknown" 1.0.0     no
newer_is "unknown" "unknown" no

# sort -V puts 1.70.0-rc1 above 1.70.0 on its own; a prerelease has to sort
# below the release it is a candidate for.
newer_is 1.70.0-rc1 1.70.0     no
newer_is 1.70.0     1.70.0-rc1 yes
newer_is 1.70.0-rc2 1.70.0-rc1 yes

pass "version comparison"

# --- the update/check decision ----------------------------------------------

# module.sh is contracted to be side-effect free at source time, which is what
# lets this be tested without a release API or an installed collector.
# shellcheck source=modules/scrutiny-collectors/module.sh
source "$ROOT/modules/scrutiny-collectors/module.sh"

compare_is() { # compare_is <installed> <tag> <expected>
    local got; got=$(_sc_compare "$1" "$2")
    [[ $got == "$3" ]] || fail "_sc_compare '$1' '$2' returned $got, wanted $3"
}

# The reported bug: one release, two spellings, reported as an update.
compare_is 1.69.1 v1.69.1 same
compare_is v1.69.1 1.69.1 same
compare_is 1.69.1 1.69.1  same

compare_is 1.69.1 v1.70.0 upgrade
compare_is 1.70.0 v1.69.1 downgrade

# An install that predates the state file reports unknown; anything beats it.
compare_is unknown v1.69.1 upgrade

pass "update decision"
