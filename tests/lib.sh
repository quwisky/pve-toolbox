#!/usr/bin/env bash
#
# Tests for lib/common.sh: the helpers modules are told to build on.
#
# Everything here is pure or writes only into a throwaway directory, so it
# runs anywhere `make test` does - no root, no systemd, no network.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# GNU stat on the target, BSD stat on the machine this is usually written on.
mode_of() { # mode_of <path> -> permission bits, octal
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

# Nothing may reach the host: these are the paths the helpers write to.
TOOLBOX_BIN_DIR=$(mktemp -d "$WORK/XXXXXX")
TOOLBOX_LIB_DIR=$(mktemp -d "$WORK/XXXXXX")
TOOLBOX_CONF_DIR=$(mktemp -d "$WORK/XXXXXX")
TOOLBOX_STATE_DIR=$(mktemp -d "$WORK/XXXXXX")
TOOLBOX_SYSTEMD_DIR=$(mktemp -d "$WORK/XXXXXX")
export TOOLBOX_BIN_DIR TOOLBOX_LIB_DIR TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR \
       TOOLBOX_SYSTEMD_DIR

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

# The values that have historically broken one storage layer or another: shell
# metacharacters, sed replacement syntax, and awk -v escape expansion.
AWKWARD=(
    'hello'
    'a|b'
    'a&b'
    "it's"
    'say "hi"'
    'a\b'
    'a`b`'
    'a$HOME'
    'a  b'
    'a=b=c'
    'https://discord.com/api/webhooks/123/aB-c_dE'
    '/mnt/pool/some dir'
)

# --- conf: what the operator set ---------------------------------------------

# conf is where webhook URLs and tokens go, so a value that does not survive
# the round trip is a broken install, not a cosmetic bug.
for v in "${AWKWARD[@]}"; do
    conf_set roundtrip KEY "$v"
    got=$(conf_get roundtrip KEY)
    [[ $got == "$v" ]] || fail "conf_set/conf_get mangled [$v] into [$got]"
    conf_clear roundtrip
done
pass "conf round-trips awkward values"

# Overwriting a key must replace it, not append a second one.
conf_set overwrite KEY "first"
conf_set overwrite KEY "second"
conf_set overwrite OTHER "kept"
[[ $(conf_get overwrite KEY) == second ]] || fail "conf_set did not overwrite"
[[ $(conf_get overwrite OTHER) == kept ]] || fail "conf_set clobbered another key"
[[ $(grep -c '^KEY=' "$(conf_file overwrite)") -eq 1 ]] \
    || fail "conf_set left a duplicate KEY line"
pass "conf_set overwrites in place"

# The documented promise: a helper script installed into TOOLBOX_BIN_DIR can
# source the file directly rather than depending on this library.
conf_set sourceable WEBHOOK "https://example.invalid/a'b\$c"
got=$(bash -c 'set -eu; . "$1"; printf "%s" "$WEBHOOK"' _ "$(conf_file sourceable)")
[[ $got == "https://example.invalid/a'b\$c" ]] \
    || fail "conf file is not sourceable intact, got [$got]"
pass "conf files stay sourceable"

# Secrets live here, so the modes are part of the contract.
[[ $(mode_of "$(conf_file sourceable)") == 600 ]] \
    || fail "conf file is not 0600"
[[ $(mode_of "$TOOLBOX_CONF_DIR") == 750 ]] \
    || fail "conf dir is not 0750"
pass "conf modes are 0600 in a 0750 dir"

conf_exists sourceable || fail "conf_exists said no for a file that exists"
conf_clear sourceable
conf_exists sourceable && fail "conf_exists said yes after conf_clear"
pass "conf_exists tracks conf_clear"

# --- state: what the module knows --------------------------------------------

# state_set used to update through `sed s|^K=.*|K=$v|`, which read & as the
# whole match, ate backslashes and failed outright on a |. The update path is
# the one that broke, so every value is written twice.
for v in "${AWKWARD[@]}"; do
    state_set roundtrip KEY "placeholder"
    state_set roundtrip KEY "$v"
    got=$(state_get roundtrip KEY)
    [[ $got == "$v" ]] || fail "state_set/state_get mangled [$v] into [$got]"
    state_clear roundtrip
done
pass "state round-trips awkward values"

state_set overwrite KEY "first"
state_set overwrite OTHER "kept"
state_set overwrite KEY "second"
[[ $(state_get overwrite KEY) == second ]] || fail "state_set did not overwrite"
[[ $(state_get overwrite OTHER) == kept ]] || fail "state_set clobbered another key"
[[ $(grep -c '^KEY=' "$TOOLBOX_STATE_DIR/overwrite.state") -eq 1 ]] \
    || fail "state_set left a duplicate KEY line"
pass "state_set overwrites in place"

# state is safe to print, unlike conf.
[[ $(mode_of "$TOOLBOX_STATE_DIR/overwrite.state") == 644 ]] \
    || fail "state file is not 0644"
pass "state files are 0644"

[[ -z $(state_get overwrite ABSENT) ]] || fail "state_get invented a value"
[[ -z $(state_get nosuchmodule KEY) ]] || fail "state_get read a missing file"
state_exists overwrite || fail "state_exists said no for a file that exists"
state_clear overwrite
state_exists overwrite && fail "state_exists said yes after state_clear"
pass "state_get and state_exists handle absence"

# --- version helpers ---------------------------------------------------------

[[ $(version_bare v1.69.1) == 1.69.1 ]] || fail "version_bare left the v"
[[ $(version_bare V1.69.1) == 1.69.1 ]] || fail "version_bare left a capital V"
[[ $(version_bare 1.69.1)  == 1.69.1 ]] || fail "version_bare altered a bare version"
[[ $(version_bare "")      == ""     ]] || fail "version_bare invented a value"
pass "version_bare"

newer_is() { # newer_is <candidate> <current> <yes|no>
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

# Nothing known about the current version means anything is an upgrade...
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
pass "is_newer"

# --- backup_file -------------------------------------------------------------

# Every restore-shaped write is supposed to go through this first.
target="$WORK/target.conf"
printf 'original\n' > "$target"
backup_file "$target" >/dev/null
mapfile -t backups < <(find "$WORK" -name 'target.conf.bak.*' -type f)
[[ ${#backups[@]} -eq 1 ]] || fail "backup_file made ${#backups[@]} backups, wanted 1"
[[ $(cat "${backups[0]}") == original ]] || fail "backup does not match the original"
[[ $(cat "$target") == original ]] || fail "backup_file altered the original"
pass "backup_file copies before an overwrite"

backup_file "$WORK/does-not-exist" >/dev/null || fail "backup_file failed on a missing file"
[[ ! -e $WORK/does-not-exist ]] || fail "backup_file created the missing file"
pass "backup_file is a no-op on a missing file"

# --- the scrutiny update decision --------------------------------------------

# Module logic rather than lib, but pure, and it shares the version helpers
# above. module.sh is contracted to be side-effect free at source time, which
# is what lets this run without a release API or an installed collector.
# shellcheck source=modules/scrutiny-collectors/module.sh
source "$ROOT/modules/scrutiny-collectors/module.sh"

compare_is() { # compare_is <installed> <tag> <expected>
    local got; got=$(_sc_compare "$1" "$2")
    [[ $got == "$3" ]] || fail "_sc_compare '$1' '$2' returned $got, wanted $3"
}

# One release, two spellings, once reported as an available update.
compare_is 1.69.1  v1.69.1 same
compare_is v1.69.1 1.69.1  same
compare_is 1.69.1  1.69.1  same

compare_is 1.69.1 v1.70.0 upgrade
compare_is 1.70.0 v1.69.1 downgrade

# An install predating the state file reports unknown; anything beats it.
compare_is unknown v1.69.1 upgrade
pass "update decision"
