#!/usr/bin/env bash
# The package-owned sender passes arbitrary text safely into PVE::Notify.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

fake_perl="$WORK/perl"
mkdir -p "$fake_perl/PVE"
printf '%s\n' \
    'package PVE::Notify;' \
    'sub common_template_data { return { hostname => "pve1" }; }' \
    'sub notify { my ($severity, $template, $data, $fields) = @_; print join("|", $severity, $template, $data->{title}, $data->{message}, $fields->{type}); }' \
    '1;' > "$fake_perl/PVE/Notify.pm"
helper_output=$(PERL5LIB="$fake_perl" \
    "$ROOT/scripts/pve-toolbox-native-notify" \
    warning 'quoted "title"' $'line one\nline two')
[[ $helper_output == $'warning|pve-toolbox|quoted "title"|line one\nline two|pve-toolbox' ]] \
    || fail "shared helper mangled notification data: $helper_output"
rc=0
PERL5LIB="$fake_perl" "$ROOT/scripts/pve-toolbox-native-notify" \
    critical title message >/dev/null 2>&1 || rc=$?
[[ $rc -eq 64 ]] || fail "shared helper accepted an invalid severity"
pass "shared helper uses the native matcher path safely"
