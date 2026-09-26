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

# Release binaries execute as root. Missing or incomplete checksum metadata is
# therefore an error, not an optional warning.
checksum_payload="$WORK/release-asset"
checksum_list="$WORK/SHA256SUMS"
printf 'collector build\n' > "$checksum_payload"
CHECKSUM_FILE=""
verify_checksum "$checksum_payload" collector-linux-amd64 \
    && fail "verify_checksum accepted an absent checksum file"
printf '%s  %s\n' "$(sha256sum "$checksum_payload" | awk '{print $1}')" other-asset \
    > "$checksum_list"
CHECKSUM_FILE=$checksum_list
verify_checksum "$checksum_payload" collector-linux-amd64 \
    && fail "verify_checksum accepted a missing asset entry"
printf '%s  *%s\n' "$(sha256sum "$checksum_payload" | awk '{print $1}')" collector-linux-amd64 \
    > "$checksum_list"
verify_checksum "$checksum_payload" collector-linux-amd64 >/dev/null \
    || fail "verify_checksum rejected an exact asset entry"
pass "release checksums fail closed"

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

# --- prompts ------------------------------------------------------------------

# prompt_run <input> <function> -> PROMPT_OUT (stdout and stderr), PROMPT_RC.
# The function runs in a pipeline subshell, so a die inside it ends only that.
prompt_run() {
    local input=$1 fn=$2
    PROMPT_RC=0
    PROMPT_OUT=$(printf '%s' "$input" | "$fn" 2>&1) || PROMPT_RC=$?
}
expect_out() { [[ $PROMPT_OUT == *"$1"* ]] || fail "$2: missing [$1] in [$PROMPT_OUT]"; }
refuse_out() { [[ $PROMPT_OUT != *"$1"* ]] || fail "$2: unexpected [$1] in [$PROMPT_OUT]"; }
expect_rc() { # expect_rc <zero|nonzero> <what>
    if [[ $1 == zero ]]; then
        [[ $PROMPT_RC -eq 0 ]] || fail "$2: exit $PROMPT_RC [$PROMPT_OUT]"
    else
        [[ $PROMPT_RC -ne 0 ]] || fail "$2: succeeded [$PROMPT_OUT]"
    fi
}

t_ask()        { local answer=""; ask answer "pick one" "dflt"; printf 'got=[%s]\n' "$answer"; }
t_ask_key()    { ask SOME_KEY "pick one" "dflt"; printf 'got=[%s]\n' "$SOME_KEY"; }
t_ask_preset() { local SOME_KEY=preset; ask SOME_KEY "pick one" "dflt"; printf 'got=[%s]\n' "$SOME_KEY"; }

prompt_run $'typed\n' t_ask
expect_rc zero "ask piped answer"; expect_out 'got=[typed]' "ask piped answer"
prompt_run $'\n' t_ask
expect_out 'got=[dflt]' "ask blank answer"
prompt_run 'unterminated' t_ask
expect_out 'got=[unterminated]' "ask last line without a newline"
prompt_run $'\n' t_ask_preset
expect_out 'got=[preset]' "ask preset default"
prompt_run '' t_ask
expect_rc nonzero "ask on closed input"
expect_out 'no answer for "pick one"' "ask on closed input"
refuse_out 'got=' "ask on closed input"
refuse_out 'set answer' "ask hint for a local variable"
prompt_run '' t_ask_key
expect_out 'use -y and set SOME_KEY' "ask hint for a presettable key"
pass "ask reads piped answers and fails closed on EOF"

_t_even() {
    [[ $1 =~ ^[0-9]+$ ]] && (( $1 % 2 == 0 )) || { ASK_REASON="must be even"; return 1; }
    ASK_NORMALIZED="even-$1"
}
t_valid()     { local n=""; ask_valid n "even number" "" _t_even; printf 'got=[%s]\n' "$n"; }
t_valid_yes() { ASSUME_YES=1; local EVEN_N=3; ask_valid EVEN_N "even number" "" _t_even; printf 'got=[%s]\n' "$EVEN_N"; }

prompt_run $'3\n4\n' t_valid
expect_out 'must be even' "ask_valid rejection"; expect_out 'got=[even-4]' "ask_valid normalized re-prompt"
prompt_run '' t_valid_yes
expect_rc nonzero "ask_valid invalid preset under -y"
expect_out 'invalid value for EVEN_N: must be even' "ask_valid invalid preset under -y"
refuse_out 'got=' "ask_valid invalid preset under -y"
pass "ask_valid re-prompts interactively and dies under -y"

t_yn()        { local reply=""; ask_yn reply "go on" "n"; printf 'got=[%s]\n' "$reply"; }
t_yn_preset() { ASSUME_YES=1; local FLAG=1; ask_yn FLAG "go on" "n"; printf 'got=[%s]\n' "$FLAG"; }
t_confirm()   { if confirm "sure?" n; then echo 'answer=yes'; else echo 'answer=no'; fi; }

prompt_run $'maybe\nYES\n' t_yn
expect_out 'please answer y or n' "ask_yn rejection"; expect_out 'got=[y]' "ask_yn re-prompt"
prompt_run '' t_yn_preset
expect_out 'got=[y]' "ask_yn legacy 1 preset"
prompt_run $'y\n' t_confirm
expect_out 'answer=yes' "confirm reads its caller's __r"
prompt_run $'\n' t_confirm
expect_out 'answer=no' "confirm default"
prompt_run '' t_confirm
expect_rc nonzero "confirm on closed input"; refuse_out 'answer=' "confirm on closed input"
pass "ask_yn and confirm validate and fail closed"

t_int()     { local n=""; ask_int n "count" "5" 1 100; printf 'got=[%s]\n' "$n"; }
t_int_min() { local n=""; ask_int n "count" "" 1; printf 'got=[%s]\n' "$n"; }
t_int_yes() { ASSUME_YES=1; local SOME_NUM=0; ask_int SOME_NUM "count" "5" 1 100; printf 'got=[%s]\n' "$SOME_NUM"; }

prompt_run $'abc\n007\n101\n42\n' t_int
expect_out 'enter a whole number from 1 to 100' "ask_int rejection"
expect_out 'got=[42]' "ask_int re-prompt"
[[ $(grep -c 'enter a whole number' <<<"$PROMPT_OUT") -eq 3 ]] \
    || fail "ask_int did not reject abc, 007 and 101 each: $PROMPT_OUT"
prompt_run $'\n' t_int
expect_out 'got=[5]' "ask_int default"
prompt_run $'0\n7\n' t_int_min
expect_out 'enter a whole number of at least 1' "ask_int lower bound only"
expect_out 'got=[7]' "ask_int lower bound re-prompt"
prompt_run '' t_int_yes
expect_rc nonzero "ask_int invalid preset under -y"
expect_out 'invalid value for SOME_NUM' "ask_int invalid preset under -y"
pass "ask_int enforces format and bounds"

t_choice()     { local c=""; ask_choice c "transport" "qga" qga ssh; printf 'got=[%s]\n' "$c"; }
t_choice_yes() { ASSUME_YES=1; local MODE=SSH; ask_choice MODE "transport" "qga" qga ssh; printf 'got=[%s]\n' "$MODE"; }
t_choice_bad() { ASSUME_YES=1; local MODE=telnet; ask_choice MODE "transport" "qga" qga ssh; printf 'got=[%s]\n' "$MODE"; }

prompt_run $'telnet\nSSH\n' t_choice
expect_out 'choose one of qga/ssh' "ask_choice rejection"
expect_out 'got=[ssh]' "ask_choice canonical spelling"
prompt_run $'\n' t_choice
expect_out 'got=[qga]' "ask_choice default"
prompt_run '' t_choice_yes
expect_out 'got=[ssh]' "ask_choice mixed-case preset"
prompt_run '' t_choice_bad
expect_rc nonzero "ask_choice invalid preset"
expect_out 'invalid value for MODE: choose one of qga/ssh' "ask_choice invalid preset"
prompt_run '' t_choice
expect_out 'no answer for "transport (qga/ssh)"' "ask_choice on closed input"
pass "ask_choice matches case-insensitively and stores canonical choices"

t_sched() {
    systemd-analyze() {
        [[ $1 == calendar && $2 == --iterations=1 ]] || return 2
        case $3 in
            daily) printf '  Next elapse: Thu 2026-10-01 00:00:00 UTC\n' ;;
            dead)  printf '  Next elapse: never\n' ;;
            *)     return 1 ;;
        esac
    }
    local s=""; ask_schedule s "schedule" "dead"; printf 'got=[%s]\n' "$s"
}
# shellcheck disable=SC2123 # deliberately hiding systemd-analyze for this test only
t_sched_missing() { PATH=/nonexistent; local s=""; ask_schedule s "schedule" "daily"; printf 'got=[%s]\n' "$s"; }

prompt_run $'nonsense\n\ndaily\n' t_sched
expect_out 'not a systemd OnCalendar expression: nonsense' "ask_schedule syntax"
expect_out 'schedule never runs: dead' "ask_schedule dead default"
expect_out 'got=[daily]' "ask_schedule re-prompt"
prompt_run $'daily\n' t_sched_missing
expect_rc nonzero "ask_schedule without systemd-analyze"
expect_out 'systemd-analyze is needed to check schedules' "ask_schedule without systemd-analyze"
pass "ask_schedule validates with systemd-analyze and never guesses"

HOOK_OK='https://discord.com/api/webhooks/1/tok-en_1'
t_secret()      { local TOKEN=""; ask_secret TOKEN "token"; [[ $TOKEN == s3cret-value ]] && echo 'stored=typed'; }
t_secret_keep() { local TOKEN=old-secret; ask_secret TOKEN "token"; [[ $TOKEN == old-secret ]] && echo 'stored=kept'; }
t_secret_none() { local TOKEN=old-secret; ask_secret TOKEN "token"; [[ -z $TOKEN ]] && echo 'stored=cleared'; }
t_hook()        { local HOOK=""; ask_secret HOOK "Discord webhook URL" valid_webhook_url; [[ $HOOK == "$HOOK_OK" ]] && echo 'stored=hook'; }
t_hook_yes()    { ASSUME_YES=1; local HOOK=""; ask_secret HOOK "Discord webhook URL" valid_webhook_url; echo 'stored=?'; }
t_hook_other()  { local HOOK=""; ask_secret HOOK "hook" valid_webhook_url; [[ $HOOK == https://hooks.example.invalid/x ]] && echo 'stored=other'; }
t_hook_yes_kept() { ASSUME_YES=1; local HOOK="$HOOK_OK"; ask_secret HOOK "Discord webhook URL" valid_webhook_url; [[ $HOOK == "$HOOK_OK" ]] && echo 'stored=yes-kept'; }
t_hook_keep()     { local HOOK="$HOOK_OK"; ask_secret HOOK "Discord webhook URL" valid_webhook_url; [[ $HOOK == "$HOOK_OK" ]] && echo 'stored=enter-kept'; }

prompt_run $'s3cret-value\n' t_secret
expect_out 'stored=typed' "ask_secret stores the typed value"
refuse_out 's3cret-value' "ask_secret output"
prompt_run $'\n' t_secret_keep
expect_out 'stored=kept' "ask_secret Enter keeps"
prompt_run $'none\n' t_secret_none
expect_out 'stored=cleared' "ask_secret none clears"
prompt_run $'\nhttp://leak.example.invalid/tok\n'"$HOOK_OK"$'\n' t_hook
expect_out 'a webhook URL is required' "required secret re-prompts on blank"
expect_out 'does not look like a URL' "malformed webhook rejected"
refuse_out 'leak.example.invalid' "rejected secret value is never echoed"
expect_out 'stored=hook' "webhook accepted after re-prompt"
prompt_run '' t_hook_yes
expect_rc nonzero "missing required secret under -y"
expect_out 'invalid value for HOOK: a webhook URL is required' "missing required secret under -y"
prompt_run '' t_secret
expect_rc nonzero "ask_secret on closed input"; expect_out 'no answer for "token"' "ask_secret on closed input"
prompt_run $'https://hooks.example.invalid/x\n' t_hook_other
expect_out 'not a discord.com/api/webhooks URL' "non-Discord webhook warns"
expect_out 'stored=other' "non-Discord webhook still accepted"
# Passing empty stdin: any attempt to read here would hit closed input and
# die, so a zero exit is itself proof that -y never reads.
prompt_run '' t_hook_yes_kept
expect_rc zero "-y keeps an already-valid preset without reading"
expect_out 'stored=yes-kept' "-y keeps an already-valid preset without reading"
prompt_run $'\n' t_hook_keep
expect_out 'stored=enter-kept' "Enter keeps an already-valid preset for a required secret"
pass "ask_secret keeps, clears, validates and never echoes"

# The prompt globals outlive the call, so a secret must not linger in any of
# them once ask_secret has stored it. _t_upper normalizes, which is what puts
# a copy of the value in ASK_NORMALIZED.
_t_upper() { ASK_NORMALIZED=${1^^}; }
t_secret_globals() {
    local TOKEN=""; ask_secret TOKEN "token" _t_upper
    printf 'stored=[%s] globals=[%s|%s|%s]\n' "$TOKEN" "$ASK_LINE" "$ASK_VALUE" "$ASK_NORMALIZED"
}
t_secret_globals_yes() {
    ASSUME_YES=1; local TOKEN=s3cret-value; ask_secret TOKEN "token" _t_upper
    printf 'stored=[%s] globals=[%s|%s|%s]\n' "$TOKEN" "$ASK_LINE" "$ASK_VALUE" "$ASK_NORMALIZED"
}
prompt_run $'s3cret-value\n' t_secret_globals
expect_out 'stored=[S3CRET-VALUE] globals=[||]' "ask_secret clears the prompt globals"
prompt_run '' t_secret_globals_yes
expect_out 'stored=[S3CRET-VALUE] globals=[||]' "ask_secret under -y clears the prompt globals"
pass "ask_secret leaves no copy of the secret in the prompt globals"

# Only a variable an operator could preset is named; a local one would send
# them looking for a setting that does not exist, so the prompt is named.
t_valid_yes_local() { ASSUME_YES=1; local n=3; ask_valid n "even number" "" _t_even; printf 'got=[%s]\n' "$n"; }
t_secret_yes_local() { ASSUME_YES=1; local hook=""; ask_secret hook "Discord webhook URL" valid_webhook_url; printf 'stored=[%s]\n' "$hook"; }
prompt_run '' t_valid_yes_local
expect_rc nonzero "ask_valid invalid local default under -y"
expect_out 'invalid value for "even number": must be even' "ask_valid invalid local default under -y"
refuse_out 'invalid value for n:' "ask_valid invalid local default under -y"
prompt_run '' t_secret_yes_local
expect_rc nonzero "ask_secret missing local value under -y"
expect_out 'invalid value for "Discord webhook URL": a webhook URL is required' "ask_secret missing local value under -y"
pass "-y errors name the prompt when the variable cannot be preset"
