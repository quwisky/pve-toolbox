#!/usr/bin/env bash
# bao-run and openbao-setup.sh against curl/bao test doubles. No network, no root.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
BR=$ROOT/modules/bao-run/bao-run.sh
SETUP=$ROOT/modules/bao-run/openbao-setup.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
BIN=$WORK/bin
D=$WORK/d
CONF=$WORK/conf
mkdir -p "$BIN"

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

TOKEN_S=SENTINEL-TOKEN
SID_S=SECRETID-SENT
RID_S=ROLEID-SENT

# curl double: records argv (one line per call) and stdin, answers by URL.
cat > "$BIN/curl" <<'DBL'
#!/usr/bin/env bash
[[ ${1:-} != --version ]] || exit 0
D=$BR_D
echo "$*" >> "$D/argv"
url=${*: -1}
stdin=0 w=0
for a in "$@"; do [[ $a == @- ]] && stdin=1; [[ $a == -w ]] && w=1; done
if [[ $stdin == 1 ]]; then { cat; echo; echo ---; } >> "$D/stdin"; fi
emit() { printf '%s' "$1"; if [[ $w == 1 ]]; then printf '\n%s' "$2"; fi; }
case $url in
  */v1/auth/approle/login)
    echo login >> "$D/calls"
    if [[ -f $D/curl_stderr ]]; then cat "$D/curl_stderr" >&2; fi
    if [[ -f $D/login_exit ]]; then emit '' 000; exit "$(<"$D/login_exit")"; fi
    st=200; [[ -f $D/login_status ]] && st=$(<"$D/login_status")
    if [[ $st == 200 ]]; then
      if [[ -f $D/login_body ]]; then emit "$(<"$D/login_body")" 200
      else emit '{"auth":{"client_token":"SENTINEL-TOKEN"}}' 200; fi
      exit 0
    fi
    emit '{"errors":["nope"]}' "$st"; exit 22 ;;
  */v1/auth/token/revoke-self) echo "revoke $url" >> "$D/calls"; exit 0 ;;
  */v1/kv/data/*)
    p=${url#*/v1/kv/data/}
    echo "read $url" >> "$D/calls"
    f="$D/kv/${p//\//_}.json"
    [[ -f $f ]] || { printf '{"errors":[]}'; exit 22; }
    cat "$f" ;;
esac
DBL

# bao double: logs every call, state comes from files in $BR_D.
cat > "$BIN/bao" <<'DBL'
#!/usr/bin/env bash
D=$BR_D
echo "$*" >> "$D/bao.log"
case "$*" in
  "secrets list "*) cat "$D/secrets.json" ;;
  "auth list "*) cat "$D/auth.json" ;;
  "policy list "*) [[ ! -f $D/policy_list_fail ]] || { echo "boom" >&2; exit 2; }; cat "$D/policies.json" ;;
  "policy read "*) cat "$D/policy_$3" ;;
  "policy write "*) cat > "$D/policy_written" ;;
  "read -field=role_id "*) echo ROLEID-1234 ;;
  "write -f -field=secret_id "*) echo SECRETID-5678 ;;
  "list -format=json auth/approle/role")
    if [[ -f $D/role_list_error ]]; then echo "permission denied" >&2; exit 2; fi
    if [[ -f $D/role_list_warning ]]; then echo "WARNING! token expires soon" >&2; fi
    if [[ -f $D/role_list_empty ]]; then echo '{}'; exit 2; fi
    if [[ -f $D/role_exists ]]; then echo '["other","komodo-a"]'
    else echo "No value found at auth/approle/role" >&2; exit 2; fi ;;
  "read -format=json auth/approle/role/"*)
    [[ ! -f $D/role_read_error ]] || { echo "permission denied" >&2; exit 2; }
    if [[ -f $D/role_read ]]; then cat "$D/role_read"; else jq -n --arg n "${3##*/}" '{data:{token_policies:[$n]}}'; fi ;;
esac
exit 0
DBL

# child: records the named env vars, proving it ran.
cat > "$BIN/child" <<'DBL'
#!/usr/bin/env bash
touch "$BR_D/ran"
for v in "$@"; do printf '%s' "${!v-UNSET}" > "$BR_D/v_$v"; done
DBL
chmod +x "$BIN"/*

mk() {
  rm -rf "$D" "$CONF"; mkdir -p "$D/kv" "$CONF/roles/foo"
  printf 'https://openbao.invalid:8200\n' > "$CONF/addr"
  printf '%s\n' "$RID_S" > "$CONF/role_id"; printf '%s\n' "$SID_S" > "$CONF/secret_id"
  printf 'FOO-ROLE\n' > "$CONF/roles/foo/role_id"; printf 'FOO-SID\n' > "$CONF/roles/foo/secret_id"
  printf '%s' '{"kv/":{"type":"kv","options":{"version":"2"}},"sys/":{"type":"system"}}' > "$D/secrets.json"
  printf '%s' '{"approle/":{"type":"approle"}}' > "$D/auth.json"
  printf '%s' '["default","root"]' > "$D/policies.json"
}
kv() { printf '{"data":{"data":%s}}' "$2" > "$D/kv/${1//\//_}.json"; }
RC=0
run_br() {
  RC=0
  PATH=$BIN:$PATH BAO_RUN_CONF=$CONF BR_D=$D "$BR" "$@" >"$D/out" 2>"$D/err" </dev/null || RC=$?
}
run_setup() {
  RC=0
  PATH=$BIN:$PATH BR_D=$D BAO_ADDR=https://openbao.invalid:8200 BAO_TOKEN=ADMIN-SENT \
    "$SETUP" "$@" >"$D/out" 2>"$D/err" </dev/null || RC=$?
}
ran() { [[ -e $D/ran ]]; }
revoked() { grep -q '^revoke ' "$D/calls"; }
v() { cat "$D/v_$1"; }
nosecret() { # nosecret <needle>... : not on stdout or stderr
  local n; for n in "$@"; do ! grep -qF -- "$n" "$D/out" "$D/err" || return 1; done
}

test_kv_key_count_cannot_inject() {
  mk; local mark=$WORK/MARK
  kv a/b "$(jq -n --arg v "paths[\$(touch \"$mark\")0]" '{count:$v}')"
  run_br a/b -- child count
  [[ $RC -eq 0 && ! -e $mark ]] || fail "count key injected (rc=$RC)"
  ran || fail "count: command did not run"
  [[ $(v count) == "paths[\$(touch \"$mark\")0]" ]] || fail "count not literal"
  pass "kv key count cannot inject"
}

test_kv_key_addr_cannot_redirect() {
  mk
  kv one '{"ADDR":"https://attacker.invalid"}'; kv two '{"K":"v"}'
  run_br one two -- child ADDR
  [[ $RC -eq 0 ]] || fail "addr: rc=$RC"
  ! grep -q attacker "$D/argv" || fail "addr redirected a request"
  [[ $(grep -c '^read https://openbao.invalid:8200/' "$D/calls") -eq 2 ]] || fail "addr: reads"
  grep -q '^revoke https://openbao.invalid:8200/' "$D/calls" || fail "addr: revoke"
  [[ $(v ADDR) == https://attacker.invalid ]] || fail "child lost ADDR"
  pass "kv key ADDR cannot redirect"
}

test_kv_keys_token_and_paths_do_not_break_revoke() {
  mk
  kv one '{"TOKEN":"x","paths":"y","CURL":"z","MOUNT":"m"}'; kv two '{"K":"v"}'
  run_br one two -- child TOKEN paths CURL MOUNT K
  [[ $RC -eq 0 ]] || fail "internal names: rc=$RC"
  revoked || fail "internal names: no revoke"
  [[ $(grep -c '^read ' "$D/calls") -eq 2 ]] || fail "internal names: reads"
  [[ $(v TOKEN)$(v paths)$(v CURL)$(v MOUNT)$(v K) == xyzmv ]] || fail "internal names: child env"
  pass "kv keys TOKEN/paths/CURL/MOUNT leave reads and revoke working"
}

test_denied_keys_stop_before_exec() {
  local k
  for k in PATH IFS ENV BASH_ENV SHELLOPTS BASHOPTS PS4 HOME GCONV_PATH LOCPATH BAO_RUN_CONF \
           LD_PRELOAD BASH_FUNC_x BASHPID DOCKER_HOST COMPOSE_FILE BUILDKIT_HOST BUILDX_BUILDER _BR_x \
           RANDOM SRANDOM OPTIND OPTARG OPTERR HISTCMD LINENO SECONDS EPOCHSECONDS EPOCHREALTIME \
           UID EUID PPID GROUPS FUNCNAME DIRSTACK PIPESTATUS; do
    mk; kv a "$(jq -n --arg k "$k" '{($k):"x"}')"
    run_br a -- child
    [[ $RC -ne 0 ]] || fail "denied $k: succeeded"
    ran && fail "denied $k: command ran"
    revoked || fail "denied $k: token not revoked"
    grep -qF "bao-run: refused env var name '$k' in a" "$D/err" || fail "denied $k: message"
  done
  # A refused key's value is never evaluated and never printed.
  local mark=$WORK/MARK2 k
  for k in RANDOM SRANDOM OPTIND HISTCMD _BR_PATHS; do
    mk; rm -f "$mark"
    kv a "$(jq -n --arg k "$k" --arg v "PIPESTATUS[\$(touch \"$mark\")0] hunter2 secret" '{($k):$v}')"
    run_br a -- child
    [[ $RC -ne 0 ]] && ! ran && [[ ! -e $mark ]] || fail "value of $k evaluated or command ran"
    nosecret hunter2 || fail "value of refused $k printed"
  done
  # An allowed key whose value looks like arithmetic stays inert.
  mk; rm -f "$mark"
  kv a "$(jq -n --arg v "_BR_PATHS[\$(touch \"$mark\")0]" '{K:$v}')"
  run_br a -- child K
  [[ $RC -eq 0 && ! -e $mark ]] || fail "arithmetic value evaluated"
  mk; kv a '{"BASH_FUNC_x%%":"() { :; }"}'; run_br a -- child
  [[ $RC -ne 0 ]] && ! ran || fail "exported-function name accepted"
  pass "denied keys stop before exec"
}

test_invalid_key_is_not_printed() {
  mk; kv a '{"hunter2 key":"v"}'
  run_br a -- child
  [[ $RC -ne 0 ]] && ! ran || fail "invalid key accepted"
  revoked || fail "invalid key: token not revoked"
  nosecret hunter2 || fail "invalid key printed"
  grep -qF 'bao-run: invalid env var name in a' "$D/err" || fail "invalid key: message"
  pass "an invalid key is reported by path only"
}

test_role_default_means_top_level_files() {
  mk; mkdir -p "$CONF/roles/default"
  printf 'WRONG-ROLE\n' > "$CONF/roles/default/role_id"; printf 'WRONG-SID\n' > "$CONF/roles/default/secret_id"
  run_br --check -r default
  [[ $RC -eq 0 && $(<"$D/out") == ok ]] || fail "check -r default: rc=$RC"
  grep -q "$RID_S" "$D/stdin" || fail "-r default: top-level creds not used"
  ! grep -q WRONG "$D/stdin" || fail "-r default: read roles/default"
  rm -r "$CONF/roles/default"; kv a '{"K":"v"}'
  run_br -r default a -- child
  [[ $RC -eq 0 ]] && ran || fail "run -r default: rc=$RC"
  grep -q 'as default$' "$D/err" || fail "-r default: summary"
  pass "-r default means the top-level files"
}

test_setup_refuses_a_stack_named_default() {
  mk; run_setup a 10.0.0.5 default
  [[ $RC -ne 0 && ! -e $D/bao.log ]] || fail "stack named default accepted"
  grep -q default "$D/err" || fail "stack default: message"
  pass "setup refuses a stack named default"
}

test_setup_refuses_existing_role_it_does_not_own() {
  # Role present, same-named policy absent: it is bound to someone else's policy.
  mk; touch "$D/role_exists"; printf '%s' '["default","team-policy"]' > "$D/policies.json"
  printf '%s' '{"data":{"token_policies":["team-policy"]}}' > "$D/role_read"
  run_setup a 10.0.0.5
  [[ $RC -ne 0 ]] || fail "role without policy: succeeded"
  grep -q komodo-a "$D/err" || fail "role without policy: role not named"
  ! wrote '^policy write' && ! wrote '^write ' && ! wrote ' enable ' || fail "role without policy: wrote"
  local body
  # Same-named policy present, but the role does not use exactly that policy.
  for body in '{"data":{"token_policies":["team-policy"]}}' '{"data":{"token_policies":["komodo-a","extra"]}}' \
              '{"data":{"token_policies":[]}}' '{"data":{}}' 'not json'; do
    primed; printf '%s' "$body" > "$D/role_read"
    run_setup --new-secret-id a 10.0.0.5
    [[ $RC -ne 0 ]] || fail "role policies $body: succeeded"
    ! wrote '^policy write' && ! wrote '^write ' || fail "role policies $body: wrote"
    ! grep -q SECRETID "$D/out" || fail "role policies $body: minted"
  done
  primed; touch "$D/role_read_error"
  run_setup a 10.0.0.5
  [[ $RC -ne 0 ]] && ! wrote '^policy write' && ! wrote '^write ' || fail "unreadable role: wrote"
  pass "setup refuses an existing role it does not own"
}

test_setup_accepts_an_approle_mount_without_roles() {
  mk; touch "$D/role_list_empty"
  run_setup a 10.0.0.5
  [[ $RC -eq 0 ]] || fail "empty listing: rc=$RC: $(<"$D/err")"
  wrote 'field=secret_id' || fail "empty listing: not treated as a new role"
  mk; touch "$D/role_list_empty" "$D/role_list_warning"
  run_setup a 10.0.0.5
  [[ $RC -eq 0 ]] || fail "empty listing with a warning: rc=$RC"
  # A CLI warning on stderr must not corrupt the JSON on stdout.
  primed; touch "$D/role_list_warning"
  run_setup a 10.0.0.5
  [[ $RC -eq 0 ]] || fail "warning with roles: rc=$RC: $(<"$D/err")"
  ! wrote 'field=secret_id' || fail "warning hid an existing role"
  mk; touch "$D/role_list_error"
  run_setup a 10.0.0.5
  grep -q 'cannot list AppRoles: permission denied' "$D/err" || fail "listing error text lost"
  pass "setup accepts an approle mount without roles"
}

test_token_never_in_argv() {
  mk; kv a '{"K":"v"}'
  run_br a -- child
  [[ $RC -eq 0 ]] || fail "argv: rc=$RC"
  ! grep -q "$TOKEN_S" "$D/argv" || fail "token in curl argv"
  ! grep -q "$SID_S\|$RID_S" "$D/argv" || fail "credential in curl argv"
  grep -q "$TOKEN_S" "$D/stdin" || fail "token not on stdin"
  pass "token never in argv"
}

test_empty_path_fails() {
  local body
  for body in '{"data":{"data":{}}}' '{"data":{"data":null}}' 'not json'; do
    mk; printf '%s' "$body" > "$D/kv/a.json"
    run_br a -- child
    [[ $RC -ne 0 ]] || fail "empty '$body': succeeded"
    ran && fail "empty '$body': command ran"
    grep -q 'no usable secrets at kv/a' "$D/err" || fail "empty '$body': message"
  done
  pass "empty or malformed path fails"
}

test_nul_in_value_fails() {
  mk; printf '%s' '{"data":{"data":{"K":"XQ9\u0000ZW7"}}}' > "$D/kv/a.json"
  run_br a -- child
  [[ $RC -ne 0 ]] && ! ran || fail "NUL value accepted"
  nosecret XQ9 ZW7 || fail "NUL value printed"
  mk; printf '%s' '{"data":{"data":{"K\u0000X":"v"}}}' > "$D/kv/a.json"
  run_br a -- child
  [[ $RC -ne 0 ]] && ! ran || fail "NUL key accepted"
  pass "NUL in value fails without printing it"
}

test_values_round_trip() {
  mk
  kv one "$(jq -n '{A:"line1\nline2", B:"$HOME '"'"'q'"'"' \"d\" x", C:"first"}')"
  kv two '{"C":"second"}'
  run_br one two -- child A B C
  [[ $RC -eq 0 ]] || fail "round trip: rc=$RC"
  [[ $(v A) == $'line1\nline2' ]] || fail "newline lost"
  [[ $(v B) == "\$HOME 'q' \"d\" x" ]] || fail "special chars lost"
  [[ $(v C) == second ]] || fail "later path did not override"
  grep -q 'injected 3 secret(s) from one two' "$D/err" || fail "summary"
  nosecret line1 second first || fail "values printed"
  pass "values round trip"
}

test_check_results() {
  local case_ st word
  for case_ in "200:ok" "400:rejected" "403:rejected" "401:rejected" "503:unavailable" \
               "e60:tls" "e35:tls" "e7:unreachable" "e28:unreachable"; do
    mk
    if [[ ${case_%%:*} == e* ]]; then st=${case_%%:*}; printf '%s' "${st#e}" > "$D/login_exit"
    else printf '%s' "${case_%%:*}" > "$D/login_status"; fi
    word=${case_#*:}
    run_br --check
    [[ $(<"$D/out") == "$word" ]] || fail "check $case_: got '$(<"$D/out")'"
    if [[ $word == ok ]]; then
      [[ $RC -eq 0 ]] && revoked || fail "check ok: rc=$RC or no revoke"
    else
      [[ $RC -ne 0 ]] || fail "check $case_: exit 0"
      ! revoked || fail "check $case_: revoked without token"
    fi
    nosecret "$TOKEN_S" "$SID_S" "$RID_S" || fail "check $case_: secret printed"
  done
  mk; printf '%s' '{"auth":null}' > "$D/login_body"
  run_br --check
  [[ $(<"$D/out") == unavailable && $RC -ne 0 ]] || fail "200 without token"
  pass "check results"
}

test_run_mode_login_failure_shows_curl_stderr() {
  mk; echo "curl: (60) SSL certificate problem" > "$D/curl_stderr"; echo 60 > "$D/login_exit"
  run_br a -- child
  [[ $RC -ne 0 ]] && ! ran || fail "login failure accepted"
  grep -q 'SSL certificate problem' "$D/err" || fail "curl stderr hidden in run mode"
  grep -q 'AppRole login failed' "$D/err" || fail "login message"
  run_br --check
  ! grep -q 'SSL certificate' "$D/err" || fail "check leaked curl stderr"
  pass "run-mode login failure shows curl stderr"
}

test_tools_must_run() {
  local tool state only=$WORK/only
  for tool in jq curl; do
    for state in non-executable absent; do
      # Only this directory is on PATH: bash skips a non-executable file if a working one follows.
      mk; rm -rf "$only"; mkdir "$only"; kv a '{"K":"v"}'
      ln -s "$(command -v bash)" "$only/bash"
      ln -s "$(command -v jq)" "$only/jq"
      ln -s "$BIN/curl" "$only/curl"
      rm "$only/$tool"
      [[ $state == absent ]] || install -m 0644 /dev/null "$only/$tool"
      RC=0; PATH=$only BAO_RUN_CONF=$CONF BR_D=$D "$BASH" "$BR" a -- "$BIN/child" >"$D/out" 2>"$D/err" </dev/null || RC=$?
      [[ $RC -ne 0 ]] && ! ran || fail "$tool $state: run accepted"
      grep -qF "bao-run: $tool not found or not executable" "$D/err" || fail "$tool $state: message: $(<"$D/err")"
      [[ ! -e $D/argv ]] || fail "$tool $state: reached OpenBao"
      RC=0; PATH=$only BAO_RUN_CONF=$CONF BR_D=$D "$BASH" "$BR" --check >"$D/out" 2>"$D/err" </dev/null || RC=$?
      [[ $RC -ne 0 && ! -s $D/out ]] || fail "$tool $state: --check rc=$RC out=$(<"$D/out")"
      grep -qF "bao-run: $tool not found or not executable" "$D/err" || fail "$tool $state: --check message"
      [[ ! -e $D/argv ]] || fail "$tool $state: --check reached OpenBao"
    done
  done
  pass "tools must run, not only exist"
}

test_blank_addr_fails() {
  local c
  for c in $'\n' '   '; do
    mk; printf '%s\n' "$c" > "$CONF/addr"; kv a '{"K":"v"}'
    run_br a -- child
    [[ $RC -ne 0 ]] && ! ran || fail "blank addr accepted"
    grep -q "no OpenBao address in $CONF/addr" "$D/err" || fail "blank addr message"
    [[ ! -e $D/argv ]] || fail "curl called with blank addr"
  done
  pass "blank addr fails"
}

test_check_role_selects_role_dir() {
  mk
  run_br --check -r foo
  [[ $RC -eq 0 && $(<"$D/out") == ok ]] || fail "check -r foo: rc=$RC"
  grep -q FOO-ROLE "$D/stdin" && grep -q FOO-SID "$D/stdin" || fail "role creds not used"
  ! grep -q "$RID_S" "$D/stdin" || fail "default creds used"
  run_br --check -r nope
  [[ $RC -ne 0 ]] || fail "unknown role accepted"
  run_br --check -r 'a/b'
  [[ $RC -ne 0 ]] || fail "bad role name accepted"
  pass "check -r selects the role dir"
}

test_missing_addr_and_creds_fail() {
  mk; rm "$CONF/addr"; kv a '{"K":"v"}'
  run_br a -- child
  [[ $RC -ne 0 ]] && ! ran || fail "missing addr"
  grep -q "no OpenBao address in $CONF/addr" "$D/err" || fail "addr message"
  mk; rm "$CONF/secret_id"
  run_br a -- child
  [[ $RC -ne 0 ]] && ! ran || fail "missing creds"
  grep -q 'no credentials in' "$D/err" || fail "creds message"
  run_br --check
  [[ $RC -ne 0 && ! -s $D/out ]] || fail "check with missing creds"
  [[ ! -e $D/argv ]] || fail "curl called without credentials"
  pass "missing addr and creds fail"
}

wrote() { grep -q "$1" "$D/bao.log"; }

test_setup_refuses_collision() {
  mk; printf 'path "other" { capabilities = ["read"] }\n' > "$D/policy_komodo-a-b"
  printf '%s' '["default","komodo-a-b"]' > "$D/policies.json"
  run_setup a 10.0.0.5 b
  [[ $RC -ne 0 ]] || fail "collision: succeeded"
  grep -q komodo-a-b "$D/err" || fail "collision: role not named"
  ! wrote '^policy write' && ! wrote '^write ' && ! wrote ' enable ' || fail "collision: wrote"
  pass "setup refuses a policy collision"
}

# Prime state as if a previous run had completed.
primed() {
  mk; run_setup a 10.0.0.5 || fail "prime run: rc=$RC"
  { cat "$D/policy_written"; printf '  \n'; } > "$D/policy_komodo-a"
  printf '%s' '["default","komodo-a"]' > "$D/policies.json"
  touch "$D/role_exists"; rm -f "$D/bao.log"
}

test_setup_fails_closed_on_lookup_errors() {
  mk; touch "$D/policy_list_fail"
  run_setup a 10.0.0.5
  [[ $RC -ne 0 ]] || fail "policy list failure ignored"
  ! wrote '^policy write' && ! wrote '^write ' || fail "wrote after policy list failure"
  mk; touch "$D/role_list_error"
  run_setup a 10.0.0.5
  [[ $RC -ne 0 ]] || fail "role list failure ignored"
  ! wrote '^policy write' && ! wrote '^write ' || fail "wrote after role list failure"
  ! grep -q SECRETID "$D/out" || fail "minted after role list failure"
  pass "setup fails closed on lookup errors"
}

test_setup_rejects_empty_host() {
  mk; run_setup "" 10.0.0.5
  [[ $RC -ne 0 && ! -e $D/bao.log ]] || fail "empty host accepted"
  mk; run_setup "" 10.0.0.5 web
  [[ $RC -ne 0 && ! -e $D/bao.log ]] || fail "empty host with stack accepted"
  pass "setup rejects an empty host"
}

test_setup_rerun_mints_no_secret() {
  mk; run_setup a 10.0.0.5
  [[ $RC -eq 0 ]] || fail "first run: rc=$RC"
  wrote 'field=secret_id' && grep -q SECRETID-5678 "$D/out" || fail "first run did not mint"
  primed
  run_setup a 10.0.0.5
  [[ $RC -eq 0 ]] || fail "rerun: rc=$RC"
  ! wrote 'field=secret_id' || fail "rerun minted a secret ID"
  grep -q ROLEID-1234 "$D/out" && grep -qi 'no new secret ID' "$D/out" || fail "rerun output"
  ! grep -q SECRETID "$D/out" || fail "rerun printed a secret ID"
  pass "setup rerun mints no secret ID"
}

test_setup_new_secret_id_flag() {
  primed
  run_setup --new-secret-id a 10.0.0.5
  [[ $RC -eq 0 ]] || fail "new-secret-id: rc=$RC"
  wrote 'field=secret_id' && grep -q SECRETID-5678 "$D/out" || fail "not minted"
  grep -q 'bao list auth/approle/role/komodo-a/secret-id' "$D/out" || fail "old-ID guidance"
  grep -qi 'valid until' "$D/out" || fail "old IDs warning"
  pass "setup --new-secret-id"
}

test_setup_refuses_kv_v1() {
  mk; printf '%s' '{"kv/":{"type":"kv","options":{"version":"1"}}}' > "$D/secrets.json"
  run_setup a 10.0.0.5
  [[ $RC -ne 0 ]] || fail "kv v1 accepted"
  ! wrote '^policy write' && ! wrote '^write ' && ! wrote ' enable ' || fail "kv v1: wrote"
  grep -qi 'v2' "$D/err" || fail "kv v1: message"
  pass "setup refuses KV v1"
}

test_setup_output_has_no_echo_commands() {
  mk; run_setup a 10.0.0.5 web
  [[ $RC -eq 0 ]] || fail "output: rc=$RC"
  ! grep -q "echo '" "$D/out" "$D/err" || fail "echo command printed"
  grep -qF 'pve-toolbox install bao-run' "$D/out" || fail "install step"
  grep -qF 'bao-run -r web komodo/a/web -- [[COMPOSE_COMMAND]]' "$D/out" || fail "wrapper line"
  grep -qi 'komodo/shared.*first' "$D/out" || fail "shared values note"
  grep -q 'komodo-a-web' "$D/out" || fail "role name"
  ! grep -q ADMIN-SENT "$D/out" "$D/err" || fail "admin token printed"
  run_setup a 10.0.0.5
  grep -qF 'bao-run komodo/a/<stack> -- [[COMPOSE_COMMAND]]' "$D/out" || fail "host wrapper line"
  ! grep -qE '^ +bao-run .*komodo/shared' "$D/out" || fail "default wrapper reads komodo/shared"
  pass "setup output has no echo commands"
}

test_setup_requires_bao_env() {
  mk
  RC=0; PATH=$BIN:$PATH BR_D=$D BAO_TOKEN=x "$SETUP" a 10.0.0.5 >/dev/null 2>&1 </dev/null || RC=$?
  [[ $RC -ne 0 ]] || fail "no BAO_ADDR accepted"
  RC=0; PATH=$BIN:$PATH BR_D=$D BAO_ADDR=https://x "$SETUP" a 10.0.0.5 >/dev/null 2>&1 </dev/null || RC=$?
  [[ $RC -ne 0 ]] || fail "no BAO_TOKEN accepted"
  [[ ! -e $D/bao.log ]] || fail "bao called without env"
  pass "setup requires BAO_ADDR and BAO_TOKEN"
}

test_setup_rejects_bad_ip() {
  local ip
  for ip in 999.1.1.1 10.0.0 a.b.c.d 10.0.0.5/32 '10.0.0.5 x' 01.2.3.4; do
    mk; run_setup a "$ip"
    [[ $RC -ne 0 ]] || fail "bad ip '$ip' accepted"
    [[ ! -e $D/bao.log ]] || fail "bad ip '$ip': bao called"
  done
  pass "setup rejects a bad IP"
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do "$t"; done
