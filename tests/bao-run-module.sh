#!/usr/bin/env bash
# The bao-run module on the host: metadata and refusals always, the full flow
# through the real launcher as root with expect, PVE doubles and a chroot guest.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck source=tests/fixtures/bao-run/harness.sh
source tests/fixtures/bao-run/harness.sh

br_no_pct() { [[ ! -s $BR_PCT_LOG ]] || br_fail "pct was called: $(<"$BR_PCT_LOG")"; }

portable_discovery_and_metadata() {
    br_fixture
    [[ $'\n'$(./pve-toolbox _complete modules)$'\n' == *$'\n'bao-run$'\n'* ]] || br_fail 'module missing from discovery'
    [[ $(./pve-toolbox list openbao) == *bao-run* ]] || br_fail 'module missing from tag'
    [[ $(./pve-toolbox status bao-run) == *'not installed'* ]] || br_fail 'status should say not installed'
    (
        TOOLBOX_ROOT=$PWD
        # shellcheck source=modules/bao-run/module.sh
        source modules/bao-run/module.sh
        [[ $MODULE_NAME == bao-run && $MODULE_HOST_ONLY == 1 && $MODULE_EXPLICIT_UPDATE == 1 ]] || exit 1
        [[ $MODULE_CONFIG_PUBLIC == 'BR_IDS BR_ADDR BR_ROLES BR_PERIPHERY BR_CONTAINER BR_IDENTITY BR_PENDING' ]] || exit 1
    ) || br_fail 'metadata'
}
portable_status_runs_no_guest_call() {
    br_fixture
    (
        source lib/common.sh
        conf_set bao-run BR_IDS 101
    ) || br_fail 'seeding the record'
    [[ $(./pve-toolbox list) == *configured* ]] || br_fail 'list should show the module as configured'
    br_no_pct
}
portable_config_files_lists_valid_ids() {
    br_fixture
    local out
    out=$(
        source lib/common.sh
        TOOLBOX_ROOT=$PWD
        # shellcheck source=modules/bao-run/module.sh
        source modules/bao-run/module.sh
        conf_set bao-run BR_IDS '101 abc 0 099 ../x * 102' || exit 1
        module_config_files
    )
    [[ $out == $'bao-run-101\nbao-run-102' ]] || br_fail "config files: $out"
}
portable_noninteractive_refused() {
    br_fixture
    if ./pve-toolbox -y install bao-run > "$BR_SESSION" 2>&1; then br_fail '-y install accepted'; fi
    if ./pve-toolbox --force update bao-run > "$BR_SESSION" 2>&1; then br_fail '--force update accepted'; fi
    if ./pve-toolbox install bao-run < /dev/null > "$BR_SESSION" 2>&1; then br_fail 'non-terminal install accepted'; fi
    br_has 'require a terminal'
    br_no_pct
}
portable_prompt_validators() {
    (
        source lib/common.sh
        source lib/report.sh
        source lib/pve.sh
        TOOLBOX_ROOT=$PWD
        # shellcheck source=modules/bao-run/host.sh
        source modules/bao-run/host.sh
        local value
        for value in https://bao.example https://bao.example:8200 https://10.0.0.1:8200; do
            br_valid_addr "$value" || br_fail "refused address $value"
        done
        for value in '' http://bao.example https://user:pw@bao.example https://bao.example/v1 'https://bao.example?x=1' \
            'https://bao.example#a' https://bao.example/ 'https://bao example' $'https://bao.example\n'; do
            if br_valid_addr "$value"; then br_fail "accepted address [$value]"; fi
        done
        br_valid_credential abc-DEF_123.~ || br_fail 'refused a credential'
        for value in '' 'SENTINEL with space' $'SENTINEL\ttab' 'SENTINELé' "$(printf 'S%.0s' {1..513})"; do
            ASK_REASON=""
            if br_valid_credential "$value"; then br_fail 'accepted a bad credential'; fi
            [[ -n $ASK_REASON && $ASK_REASON != *SENTINEL* && $ASK_REASON != *SSS* ]] || br_fail "reason: [$ASK_REASON]"
        done
        br_valid_credential "$(printf 'S%.0s' {1..512})" || br_fail 'refused a 512-byte credential'
        for value in default app_1 my-stack; do br_valid_role_name "$value" || br_fail "refused role $value"; done
        for value in '' a.b a/b 'a b' ../x a=b; do
            if br_valid_role_name "$value"; then br_fail "accepted role [$value]"; fi
        done
        for value in '' -x 'a b' 'a;b' 'a$b'; do
            if br_valid_container "$value"; then br_fail "accepted container [$value]"; fi
        done
    ) || br_fail 'validators'
}

test_install_secret_never_leaks() {
    br_fixture
    ans_to_role; ans_role default; ans_role vaultwarden; ans_apply
    # Tracing the launcher must not reach the secrets either.
    br_drive bash -x ./pve-toolbox install bao-run || br_fail 'install failed'
    local file
    for file in "$BR_PCT_LOG" "$BR_SESSION" "$BR_HOST/timeouts"; do
        if grep -aq 'SENTINEL-\(ROLE\|SECRET\)-ID' "$file"; then br_fail "sentinel in ${file##*/}"; fi
    done
    if grep -raq SENTINEL "$TOOLBOX_CONF_DIR" "$TOOLBOX_STATE_DIR"; then br_fail 'sentinel in host records'; fi
    br_no_work; br_no_stage
    while IFS= read -r file; do
        [[ $file == "$BR_TEST_ROOT/etc/bao-run/"* ]] || br_fail "sentinel in guest file $file"
    done < <(grep -rlaF SENTINEL "$BR_TEST_ROOT")
    [[ $(<"$BR_TEST_ROOT/etc/bao-run/secret_id") == SENTINEL-SECRET-ID-default ]] || br_fail 'default secret'
    [[ $(<"$BR_TEST_ROOT/etc/bao-run/roles/vaultwarden/role_id") == SENTINEL-ROLE-ID-vaultwarden ]] || br_fail 'role id'
    [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'BR_IDS'
    [[ $(br_conf bao-run-101 BR_ROLES) == 'default=komodo-docker01 vaultwarden=komodo-docker01-vaultwarden' ]] || br_fail 'BR_ROLES'
    [[ $(br_conf bao-run-101 BR_ADDR) == https://bao.example:8200 && $(br_conf bao-run-101 BR_PERIPHERY) == systemd ]] || br_fail 'addr or periphery'
    [[ -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'BR_PENDING not cleared'
    [[ $(br_conf bao-run-101 BR_IDENTITY) =~ ^[0-9a-f]{64}$ ]] || br_fail 'BR_IDENTITY'
    grep -Fxq "payload_sha256=$(br_sha modules/bao-run/bao-run.sh)" "$TOOLBOX_STATE_DIR/bao-run-101.state" || br_fail 'state hash'
    # Two roles: 120 + 60 * 2, without -k.
    grep -q '^240 pct exec 101 -- bash /run/pve-toolbox-bao-run-[0-9a-f]*/guest.sh apply ' "$BR_HOST/timeouts" || br_fail "apply limit: $(<"$BR_HOST/timeouts")"
    grep -q '^exec 101 -- mkdir -m 0700 -- /run/pve-toolbox-bao-run-[0-9a-f]*$' "$BR_PCT_LOG" || br_fail 'staging not created'
}
test_ca_file_replace_keep_remove() {
    br_fixture
    local ca=$BR_T/ca.pem junk=$BR_T/junk.pem
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj /CN=bao -days 1 -out "$ca" 2>/dev/null
    printf 'not a certificate\n' > "$junk"
    ans_to_role
    sed -i '$d' "$BR_ANS"
    ans 'CA file' "$junk"
    ans 'CA file' /no/such/file
    ans 'CA file' "$ca"
    ans_role default; ans_apply
    br_run install bao-run || br_fail 'install with a CA failed'
    br_has 'root-owned PEM certificate'
    cmp -s "$ca" "$BR_TEST_ROOT/etc/bao-run/ca.pem" || br_fail 'CA not installed'
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans_apply
    br_run install bao-run || br_fail 'keeping the CA failed'
    cmp -s "$ca" "$BR_TEST_ROOT/etc/bao-run/ca.pem" || br_fail 'blank did not keep the CA'
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file' none
    ans 'Role default' keep; ans_apply
    br_run install bao-run || br_fail 'removing the CA failed'
    [[ ! -e $BR_TEST_ROOT/etc/bao-run/ca.pem ]] || br_fail 'none did not remove the CA'
}
test_failed_login_keeps_guest_and_host_records() {
    br_fixture
    printf 'rejected\n' > "$BR_TEST_ROOT/curl-mode"
    ans_to_role; ans_role default; ans_apply
    if br_run install bao-run; then br_fail 'rejected login succeeded'; fi
    br_has "check the role and secret ID, and that this CT's IP matches the AppRole's bound address"
    [[ ! -e $BR_TEST_ROOT/etc/bao-run && ! -e $BR_TEST_ROOT/usr/local/bin/bao-run ]] || br_fail 'guest changed'
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run.conf && ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || br_fail 'record saved'
    br_no_stage; br_no_work
    # With an existing install the records stay and only the failed change is dropped.
    printf 'ok\n' > "$BR_TEST_ROOT/curl-mode"
    ans_to_role; ans_role default; ans_apply
    br_run install bao-run || br_fail 'install failed'
    local before
    before=$(br_guest_tree)
    printf 'sealed\n' > "$BR_TEST_ROOT/curl-mode"
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans_role extra; ans_apply
    if br_run install bao-run; then br_fail 'sealed install succeeded'; fi
    br_has "OpenBao is reachable but not serving requests; it may be sealed"
    [[ $(br_guest_tree) == "$before" ]] || br_fail 'guest changed on a sealed install'
    [[ $(br_conf bao-run-101 BR_ROLES) == default=komodo-docker01 && -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'records changed'
    br_no_stage
}
test_identity_change_refuses_push() {
    br_fixture
    br_install
    printf 'fedcba9876543210fedcba9876543210\n' > "$BR_TEST_ROOT/etc/machine-id"
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'replaced CT accepted'; fi
    br_has 'identity differs'
    if grep -q '^push' "$BR_PCT_LOG"; then br_fail 'pushed to a replaced CT'; fi
    # Replaced after the preview: nothing is pushed, staging stays on record.
    br_fixture
    : > "$BR_HOST/replace-after-mkdir"
    ans_to_role; ans_role default; ans_apply
    if br_run install bao-run; then br_fail 'CT replaced mid-install accepted'; fi
    if grep -q '^push' "$BR_PCT_LOG"; then br_fail 'pushed after the identity changed'; fi
    [[ $(br_conf bao-run-101 BR_PENDING) =~ ^[0-9a-f]{32}$ ]] || br_fail 'pending record lost'
    [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'retained staging not listed'
    br_no_work
}
test_outcome_unknown_keeps_pending() {
    local flag
    for flag in apply-timeout apply-garbage; do
        br_fixture
        : > "$BR_HOST/$flag"
        ans_to_role; ans_role default; ans_apply
        if br_run install bao-run; then br_fail "$flag succeeded"; fi
        br_has 'guest outcome unavailable'
        [[ $(br_conf bao-run-101 BR_PENDING) =~ ^[0-9a-f]{32}$ ]] || br_fail "$flag: BR_PENDING not kept"
        [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail "$flag: unknown first install not listed"
        [[ -n $(br_stages) ]] || br_fail "$flag: staging of an unknown outcome removed"
        br_no_work
        rm -f "$BR_HOST/$flag"
        # Visible everywhere an operator looks, and the list drives uninstall.
        [[ $(./pve-toolbox list) == *configured* ]] || br_fail "$flag: list says not installed"
        br_status_fails "$flag" 'pending'
        # A guest still holding its lock keeps its staging.
        exec 9> "$BR_TEST_ROOT/run/pve-toolbox-bao-run.lock"
        flock -n 9
        ans 'Container ID' 101; ans 'Clean up that protected staging' y
        if br_run uninstall bao-run; then br_fail "$flag: removed staging under a running guest"; fi
        [[ -n $(br_stages) && -n $(br_conf bao-run-101 BR_PENDING) ]] || br_fail "$flag: running guest's staging lost"
        exec 9>&-
        ans 'Container ID' 101; ans 'Clean up that protected staging' y
        br_run uninstall bao-run || br_fail "$flag: staging cleanup failed"
        br_no_stage
        [[ -z $(br_conf bao-run-101 BR_PENDING) && $(br_conf bao-run BR_IDS) == 101 ]] || br_fail "$flag: cleanup settled the record wrongly"
        ans 'Container ID' 101; ans 'Apply this operation' y
        br_run uninstall bao-run || br_fail "$flag: uninstall failed"
        [[ ! -e $TOOLBOX_CONF_DIR/bao-run.conf && ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || br_fail "$flag: uninstall left records"
    done
}
br_seed_stage() { # A hard-killed guest's staging; prints nothing, sets BR_SEEDED.
    BR_SEEDED=$BR_TEST_ROOT/run/pve-toolbox-bao-run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    mkdir -m 0700 "$BR_SEEDED" "$BR_SEEDED/conf" "$BR_SEEDED/conf/roles" "$BR_SEEDED/backup"
    printf 'SENTINEL-KILLED\n' > "$BR_SEEDED/conf/roles/secret_id"
    printf 'SENTINEL-KILLED\n' > "$BR_SEEDED/request.json"
    : > "$BR_SEEDED/guest.sh"
    (source lib/common.sh; conf_set bao-run-101 BR_PENDING aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) || br_fail 'seeding pending'
}
test_pending_cleanup_after_hard_killed_guest() {
    br_fixture
    br_install
    # Killed before any swap: conf holds credentials, backup is empty.
    br_seed_stage
    ans 'Container ID' 101; ans 'Clean up that protected staging' y
    br_run install bao-run || br_fail 'cleanup of a killed guest failed'
    br_no_stage
    [[ -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'pending not cleared'
    # Killed mid-swap: the backup may be the only copy, so it stays with instructions.
    br_seed_stage
    printf 'SENTINEL-PREVIOUS\n' > "$BR_SEEDED/backup/0"
    ans 'Container ID' 101; ans 'Clean up that protected staging' y
    if br_run install bao-run; then br_fail 'cleanup ignored a non-empty backup'; fi
    br_has "/run/pve-toolbox-bao-run-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/backup"
    br_has 'repair'
    br_lacks 'SENTINEL'
    [[ $(<"$BR_SEEDED/backup/0") == SENTINEL-PREVIOUS ]] || br_fail 'backup changed'
    [[ ! -e $BR_SEEDED/conf && ! -e $BR_SEEDED/request.json ]] || br_fail 'new credentials left beside the backup'
    [[ -n $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'pending dropped with a backup left'
    # Repaired by hand: the next offer finishes it.
    rm "$BR_SEEDED/backup/0"
    ans 'Container ID' 101; ans 'Clean up that protected staging' y
    br_run install bao-run || br_fail 'cleanup after the repair failed'
    br_no_stage
    # A lock that is not a plain file cannot be confirmed free.
    br_seed_stage
    rm -f "$BR_TEST_ROOT/run/pve-toolbox-bao-run.lock"
    ln -s /etc/machine-id "$BR_TEST_ROOT/run/pve-toolbox-bao-run.lock"
    ans 'Container ID' 101; ans 'Clean up that protected staging' y
    if br_run install bao-run; then br_fail 'cleanup with a symlinked lock succeeded'; fi
    [[ -e $BR_SEEDED/conf/roles/secret_id ]] || br_fail 'staging removed without confirming the lock'
}
test_status_reports_unknown_files() {
    br_fixture
    br_install
    printf 'keep\n' > "$BR_TEST_ROOT/etc/bao-run/notes"
    : > "$BR_TEST_ROOT/etc/bao-run/"$'evil\033[31m\xc2\x9bname'
    # Listed, and not by itself a failure.
    ./pve-toolbox --json status bao-run > "$BR_SESSION" 2>&1 || br_fail 'a listed file failed status'
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
    br_has '/etc/bao-run/notes'
    br_has '/etc/bao-run/evil[31mname'
    if grep -aq $'\033\|\xc2\x9b' "$BR_SESSION"; then br_fail 'a file name reached the terminal'; fi
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans_apply n
    br_run install bao-run || br_fail 'declined install failed'
    br_has '/etc/bao-run/notes'
    # A temp from an interrupted swap can hold a new secret.
    printf 'SENTINEL-TEMP\n' > "$BR_TEST_ROOT/etc/bao-run/.bao-run.Abc12345"
    br_status_fails temp '/etc/bao-run/.bao-run.Abc12345'
    br_lacks 'SENTINEL'
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans_apply n
    br_run install bao-run || br_fail 'declined install failed'
    br_has '/etc/bao-run/.bao-run.Abc12345'
    br_lacks 'SENTINEL'
}
test_revocation_commands_only_after_removal() {
    # The guest refused: credentials are still in use.
    br_fixture
    br_install
    exec 9> "$BR_TEST_ROOT/run/pve-toolbox-bao-run.lock"
    flock -n 9
    ans 'Container ID' 101; ans 'Apply this operation' y
    if br_run uninstall bao-run; then br_fail 'failed uninstall exited 0'; fi
    br_has 'another bao-run transaction'
    br_lacks 'bao delete'
    exec 9>&-
    # Never reached the guest.
    br_fixture
    br_install
    : > "$BR_HOST/replace-after-mkdir"
    ans 'Container ID' 101; ans 'Apply this operation' y
    if br_run uninstall bao-run; then br_fail 'pre-guest failure exited 0'; fi
    br_lacks 'bao delete'
    [[ -e $BR_TEST_ROOT/etc/bao-run/secret_id ]] || br_fail 'guest changed'
}
test_uninstall_unknown_outcome_holds_revocation() {
    local flag
    for flag in apply-timeout apply-garbage; do
        br_fixture
        br_install
        : > "$BR_HOST/$flag"
        ans 'Container ID' 101; ans 'Apply this operation' y
        if br_run uninstall bao-run; then br_fail "$flag: unknown uninstall exited 0"; fi
        br_has 'guest outcome unavailable'
        br_lacks 'bao delete'
        br_has 'only after confirming the credentials are gone or no longer wanted'
        [[ $(br_conf bao-run BR_IDS) == 101 && -n $(br_conf bao-run-101 BR_PENDING) ]] || br_fail "$flag: records dropped"
    done
}
test_second_interrupt_during_cleanup() {
    br_fixture
    printf 'rejected\n' > "$BR_TEST_ROOT/curl-mode"
    : > "$BR_HOST/slow-after-apply"
    ans_to_role; ans_role default; ans 'Add a role' n; ans 'Apply this operation' y
    printf 'bound address\t^C2\n' >> "$BR_ANS"
    br_run install bao-run || true
    br_no_work
    # Ignoring the interrupts also lets the slow guest cleanup finish, after the launcher may have gone.
    local i
    for ((i = 0; i < 60; i++)); do
        [[ -n $(br_stages) || -e $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || break
        sleep 0.5
    done
    br_no_stage
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf && ! -e $TOOLBOX_CONF_DIR/bao-run.conf ]] || br_fail 'interrupted cleanup left records'
}
test_hostile_status_strings_refused() {
    local filter
    for filter in '.payload.sha256 = "\u001b[31mEVIL"' '.tools += {"\u001b[2JTOOL": false}' '.periphery.sha256 = "\u001b[31mEVIL"' \
        '.unknown_files = [7]' '.unknown_files = "x"' 'del(.unknown_files)' \
        '.periphery.missing_tools = ["\u001b[31mEVIL"]' '.periphery.missing_tools = ["jq",7]' '.periphery.missing_tools = ["sh"]' \
        '.periphery.missing_tools = "jq"' 'del(.periphery.missing_tools)'; do
        br_fixture
        br_install
        printf '%s' "$filter" > "$BR_HOST/status-filter"
        ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
        if grep -aq $'\033' "$BR_SESSION"; then br_fail "status reached the terminal: $filter"; fi
        br_has 'guest status unavailable or invalid'
        if ./pve-toolbox --json status bao-run > "$BR_SESSION" 2>&1; then br_fail "--json status passed: $filter"; fi
        if ./pve-toolbox check bao-run > "$BR_SESSION" 2>&1; then br_fail "check passed: $filter"; fi
        if grep -aq $'\033' "$BR_SESSION"; then br_fail "check reached the terminal: $filter"; fi
    done
}
test_cleanup_failure_keeps_pending() {
    br_fixture
    # A foreign file in the stage makes rmdir fail after a successful apply.
    : > "$BR_HOST/foreign-in-stage"
    ans_to_role; ans_role default; ans_apply
    local rc=0
    br_run install bao-run || rc=$?
    ((rc != 0)) || br_fail 'failed cleanup exited 0'
    br_has 'guest staging cleanup incomplete'
    [[ $(br_conf bao-run-101 BR_PENDING) =~ ^[0-9a-f]{32}$ ]] || br_fail 'BR_PENDING cleared'
    [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'successful install not recorded'
    br_no_work
    # Uninstall under the same fault keeps the records with the pending staging.
    rm -f "$BR_TEST_ROOT"/run/pve-toolbox-bao-run-*/foreign
    ans 'Container ID' 101; ans 'Clean up that protected staging' y
    br_run uninstall bao-run || br_fail 'staging cleanup failed'
    ans 'Container ID' 101; ans 'Apply this operation' y
    if br_run uninstall bao-run; then br_fail 'failed cleanup exited 0 on uninstall'; fi
    br_has 'guest staging cleanup incomplete'
    [[ $(br_conf bao-run BR_IDS) == 101 && $(br_conf bao-run-101 BR_PENDING) =~ ^[0-9a-f]{32}$ ]] || br_fail 'records dropped with staging left'
}
test_incomplete_restore_keeps_first_install_record() {
    local outcome='{schema:1,result:"failed",reason:"final login check failed; restore incomplete, manual repair required",payload_sha256:"",login:[],remaining:[],changed:$c}'
    br_fixture
    jq -n --argjson c true "$outcome" > "$BR_HOST/apply-outcome"
    ans_to_role; ans_role default; ans_apply
    if br_run install bao-run; then br_fail 'failed outcome exited 0'; fi
    br_has 'restore incomplete'
    [[ $(br_conf bao-run BR_IDS) == 101 && -n $(br_conf bao-run-101 BR_IDENTITY) && -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'changed guest was forgotten'
    br_no_stage
    # With previous files to repair from: their copies stay, and so does pending.
    br_fixture
    jq -n --argjson c true "$outcome" > "$BR_HOST/apply-outcome"
    : > "$BR_HOST/apply-outcome-backup"
    ans_to_role; ans_role default; ans_apply
    if br_run install bao-run; then br_fail 'failed outcome exited 0'; fi
    br_has 'restore incomplete'
    br_has '/backup in CT 101 still holds previous files'
    br_has 'To repair'
    [[ -n $(br_conf bao-run-101 BR_PENDING) && $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'pending dropped with a backup left'
    [[ $(cat "$BR_TEST_ROOT"/run/pve-toolbox-bao-run-*/backup/0) == previous ]] || br_fail 'backup removed'
    [[ -z $(compgen -G "$BR_TEST_ROOT/run/pve-toolbox-bao-run-*/request.json") ]] || br_fail 'request left beside the backup'
    # Restored: the guest is as it was, so a first install leaves no record.
    br_fixture
    jq -n --argjson c false "$outcome" > "$BR_HOST/apply-outcome"
    ans_to_role; ans_role default; ans_apply
    if br_run install bao-run; then br_fail 'failed outcome exited 0'; fi
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run.conf && ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || br_fail 'unchanged guest kept a record'
    # A success that the transport contradicts, or an outcome without the field, is unknown.
    local filter
    for filter in '.result = "success"' 'del(.changed)'; do
        br_fixture
        jq -n --argjson c false "$outcome" | jq "$filter" > "$BR_HOST/apply-outcome"
        ans_to_role; ans_role default; ans_apply
        if br_run install bao-run; then br_fail "$filter exited 0"; fi
        br_has 'guest outcome unavailable'
        [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail "$filter: unknown outcome not listed"
    done
}
test_flooding_guest_output_is_bounded() {
    local started
    br_fixture
    br_install
    : > "$BR_HOST/flood-status"
    # Without the bound this runs into the 120 second inspection limit, still buffering.
    timeout 20 ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1 || br_fail 'flooded status did not finish'
    br_has 'oversized guest status'
    br_fixture
    : > "$BR_HOST/flood-apply"
    started=$SECONDS
    ans_to_role; ans_role default; ans_apply
    if br_run install bao-run; then br_fail 'flooded apply succeeded'; fi
    br_has 'guest outcome unavailable'
    ((SECONDS - started < 30)) || br_fail 'flooded apply was not cut short'
    [[ -n $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'unknown outcome not pending'
}
test_parallel_saves_keep_every_id() {
    br_fixture
    local ct pids=() pid
    for ((ct = 100; ct < 130; ct++)); do
        (
            source lib/common.sh
            source lib/report.sh
            source lib/pve.sh
            TOOLBOX_ROOT=$PWD
            # shellcheck source=modules/bao-run/host.sh
            source modules/bao-run/host.sh
            br_save_ids add "$ct"
        ) &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || br_fail 'a parallel save failed'; done
    local saved=()
    read -r -a saved <<<"$(br_conf bao-run BR_IDS)"
    ((${#saved[@]} == 30)) || br_fail "parallel adds kept ${#saved[@]} of 30"
    # The lock path is validated before it is opened.
    rm -f "$TOOLBOX_STATE_DIR/bao-run.lock"
    ln -s "$BR_T/elsewhere" "$TOOLBOX_STATE_DIR/bao-run.lock"
    if (
        source lib/common.sh
        source lib/report.sh
        source lib/pve.sh
        TOOLBOX_ROOT=$PWD
        # shellcheck source=modules/bao-run/host.sh
        source modules/bao-run/host.sh
        br_save_ids add 131
    ) > /dev/null 2>&1; then br_fail 'saved through a symlinked lock'; fi
    [[ ! -e $BR_T/elsewhere && $(br_conf bao-run BR_IDS) != *131* ]] || br_fail 'symlinked lock was used'
}
test_interrupt_at_secret_prompt_restores_echo() {
    br_fixture
    ans_to_role
    ans 'Add a role' y; ans 'Role name' default; ans 'AppRole name for default'
    ans 'Role ID for default' '^C'
    # A shell that stays on the same terminal, as the operator's does.
    # shellcheck disable=SC2016 # Expanded by the inner shell.
    br_drive bash -c 'trap : INT; ./pve-toolbox install bao-run; stty -a > "$1"' _ "$BR_HOST/stty" || true
    [[ -s $BR_HOST/stty ]] || br_fail 'terminal state not captured'
    grep -Eq '(^|[ ;])echo([ ;]|$)' "$BR_HOST/stty" || br_fail "echo left off: $(<"$BR_HOST/stty")"
    br_no_work
}
test_host_save_failure_reconciles() {
    br_fixture
    : > "$BR_HOST/break-state-after-apply"
    ans_to_role; ans_role default; ans_apply
    if br_run install bao-run; then br_fail 'failed host save exited 0'; fi
    br_has 'host records failed'
    [[ -e $BR_TEST_ROOT/etc/bao-run/role_id ]] || br_fail 'guest install missing'
    br_no_stage; br_no_work
    rm -f "$BR_HOST/break-state-after-apply"
    rmdir "$TOOLBOX_STATE_DIR/bao-run-101.state"
    local before
    before=$(br_guest_tree)
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans_apply
    br_run install bao-run || br_fail 'reconcile failed'
    [[ $(br_guest_tree) == "$before" ]] || br_fail 'reconcile changed the guest'
    grep -Fxq "payload_sha256=$(br_sha modules/bao-run/bao-run.sh)" "$TOOLBOX_STATE_DIR/bao-run-101.state" || br_fail 'state not reconciled'
    [[ $(br_conf bao-run BR_IDS) == 101 && $(br_conf bao-run-101 BR_ROLES) == default=komodo-docker01 ]] || br_fail 'not reconciled'
}
test_interrupt_removes_protected_files() {
    br_fixture
    ans_to_role; ans_role default; ans 'Add a role' n; ans 'Apply this operation' '^C'
    if br_run install bao-run; then br_fail 'interrupted install succeeded'; fi
    br_no_work
    if grep -q '^push' "$BR_PCT_LOG"; then br_fail 'pushed after an interrupt'; fi
    [[ ! -e $BR_TEST_ROOT/etc/bao-run ]] || br_fail 'interrupted install changed the guest'
}
test_dhcp_warning_and_ips_in_preview() {
    br_fixture
    printf '{"ostype":"debian","hostname":"docker01","rootfs":"local:vm-101-disk-0","net0":"name=eth0,bridge=vmbr0,ip=dhcp"}' > "$BR_HOST/config"
    ans_to_role; ans_role default; ans_apply n
    br_run install bao-run || br_fail 'declined preview failed'
    br_has 'this CT uses DHCP; AppRoles are bound to one IP, so a new lease stops logins'
    br_has '192.0.2.50 198.51.100.7'
    br_has docker01
    br_lacks SENTINEL
    # A static address has no warning.
    br_fixture
    ans_to_role; ans_role default; ans_apply n
    br_run install bao-run || br_fail 'declined preview failed'
    br_lacks 'uses DHCP'
    # A second NIC counts too.
    br_fixture
    printf '{"ostype":"debian","hostname":"docker01","rootfs":"local:vm-101-disk-0","net0":"name=eth0,bridge=vmbr0,ip=192.0.2.50/24","net1":"name=eth1,bridge=vmbr1,ip=dhcp"}' > "$BR_HOST/config"
    ans_to_role; ans_role default; ans_apply n
    br_run install bao-run || br_fail 'declined preview failed'
    br_has 'this CT uses DHCP; AppRoles are bound to one IP, so a new lease stops logins'
    # After a lease changed, status says rejected with the bound-IP hint.
    br_install
    printf 'rejected\n' > "$BR_TEST_ROOT/curl-mode"
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
    br_has 'login rejected'
    br_has "that this CT's IP matches the AppRole's bound address"
}
test_preview_warnings_for_periphery() {
    br_fixture
    printf 'LoadState=loaded\nActiveState=active\nUser=komodo\n' > "$BR_TEST_ROOT/unit"
    ans_to_role; ans_role default; ans_apply n
    br_run install bao-run || br_fail 'declined preview failed'
    br_has 'non-root Periphery'
    br_fixture
    printf '0000\n' > "$BR_TEST_ROOT/docker-sha"
    ans 'Container ID' 101; ans 'Periphery runs as' container; ans 'Periphery container name' 'bad name'
    ans 'Periphery container name' periphery
    ans 'OpenBao URL' https://bao.example:8200; ans 'CA file'; ans_role default; ans_apply
    br_run install bao-run || br_fail 'container install failed'
    br_has '/usr/local/bin/bao-run'; br_has '/etc/bao-run'; br_has 'restart'
    [[ $(br_conf bao-run-101 BR_PERIPHERY) == container && $(br_conf bao-run-101 BR_CONTAINER) == periphery ]] || br_fail 'container record'
}
br_container_install() { # A healthy install with Periphery in a container.
    br_sha modules/bao-run/bao-run.sh > "$BR_TEST_ROOT/docker-sha"
    ans 'Container ID' 101; ans 'Periphery runs as' container; ans 'Periphery container name' periphery
    ans 'OpenBao URL' https://bao.example:8200; ans 'CA file'; ans_role default; ans_apply "${1:-y}"
}
BR_JQ_CHECKSUM=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f
BR_JQ_DOCS=https://quwisky.github.io/pve-toolbox/modules/bao-run/#adding-jq-to-the-official-image
br_has_jq_help() {
    br_has 'static jq'; br_has 'does not manage'; br_has 'as root in the LXC'
    br_has 'curl -fsSL -o /tmp/jq-linux-amd64 https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64'
    br_has "echo '$BR_JQ_CHECKSUM  /tmp/jq-linux-amd64' | sha256sum -c - \\"
    br_has '  && install -m 0755 /tmp/jq-linux-amd64 /usr/local/lib/bao-run-jq'
    br_has 'rm -f /tmp/jq-linux-amd64'
    br_has '/usr/local/lib/bao-run-jq:/usr/local/bin/jq:ro'; br_has 'recreate'
    br_has "$BR_JQ_DOCS"
}
test_status_explains_missing_tools() {
    br_fixture
    br_container_install
    br_run install bao-run || br_fail 'container install failed'
    ./pve-toolbox --json status bao-run > "$BR_SESSION" 2>&1 || br_fail 'healthy container failed status'
    printf 'jq\n' > "$BR_TEST_ROOT/docker-missing"
    br_status_fails 'jq missing' 'the Periphery container lacks jq'
    # Doctor is what br_status_fails read last: one record, one line, the link and no commands.
    jq -e --arg docs "$BR_JQ_DOCS" '[.results[] | select(.id == "module.bao-run.agents")] | length == 1
        and (.[0].detail | contains("lacks jq") and contains($docs) and (contains("sha256sum") | not))' "$BR_SESSION" > /dev/null \
        || br_fail 'doctor detail'
    jq -e 'any(.results[]; .id | test("^module\\.bao-run\\.(protocol|runner)$")) | not' "$BR_SESSION" > /dev/null || br_fail 'doctor protocol'
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
    br_has_jq_help
    ./pve-toolbox --json status bao-run > "$BR_SESSION" 2>&1 || true # Fails by design; the output must still parse.
    jq -e --arg docs "$BR_JQ_DOCS" 'tostring | contains($docs)' "$BR_SESSION" > /dev/null || br_fail '--json status with the help is not JSON'
    printf 'curl\njq\n' > "$BR_TEST_ROOT/docker-missing"
    br_status_fails 'curl and jq' 'the Periphery container lacks curl, jq'
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
    br_has_jq_help
    local tool
    for tool in bash curl; do
        printf '%s\n' "$tool" > "$BR_TEST_ROOT/docker-missing"
        br_status_fails "$tool only" "the Periphery container lacks $tool"
        ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
        br_lacks "$BR_JQ_CHECKSUM"; br_lacks 'bao-run-jq'; br_lacks "$BR_JQ_DOCS"
    done
    # Unreachable says nothing about what the container holds.
    rm "$BR_TEST_ROOT/docker-missing"
    : > "$BR_TEST_ROOT/docker-down"
    br_status_fails unreachable 'could not check bash, curl and jq'
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
    br_lacks 'lacks'; br_lacks "$BR_JQ_CHECKSUM"
}
test_preview_explains_missing_jq_without_blocking() {
    br_fixture
    printf 'jq\n' > "$BR_TEST_ROOT/docker-missing"
    br_container_install
    br_run install bao-run || br_fail 'install blocked by a missing jq'
    br_has 'the Periphery container lacks jq'
    br_has_jq_help
    cmp -s modules/bao-run/bao-run.sh "$BR_TEST_ROOT/usr/local/bin/bao-run" || br_fail 'not installed'
    # Nothing new for a container that is fine, not started yet, lacks only curl, or is not in use.
    br_fixture
    br_container_install n
    br_run install bao-run || br_fail 'declined preview failed'
    br_lacks 'lacks'; br_lacks "$BR_JQ_CHECKSUM"
    br_fixture
    : > "$BR_TEST_ROOT/docker-down"
    br_container_install n
    br_run install bao-run || br_fail 'declined preview failed'
    br_lacks 'lacks'; br_lacks "$BR_JQ_CHECKSUM"
    br_fixture
    printf 'curl\n' > "$BR_TEST_ROOT/docker-missing"
    br_container_install n
    br_run install bao-run || br_fail 'declined preview failed'
    br_lacks "$BR_JQ_CHECKSUM"
    br_fixture
    printf 'jq\n' > "$BR_TEST_ROOT/docker-missing"
    ans_to_role; ans_role default; ans_apply n
    br_run install bao-run || br_fail 'declined preview failed'
    br_lacks "$BR_JQ_CHECKSUM"
}
test_decline_changes_nothing() {
    br_fixture
    ans_to_role; ans_role default; ans_apply n
    br_run install bao-run || br_fail 'decline failed'
    if grep -Eq '^(push|exec 101 -- mkdir)' "$BR_PCT_LOG"; then br_fail 'declined install touched the guest'; fi
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf && ! -e $TOOLBOX_CONF_DIR/bao-run.conf ]] || br_fail 'declined install wrote records'
    [[ ! -e $BR_TEST_ROOT/etc/bao-run ]] || br_fail 'declined install changed the guest'
    br_no_work; br_lacks SENTINEL
}
test_invalid_credentials_reasked_without_echo() {
    br_fixture
    ans_to_role
    ans 'Add a role' y; ans 'Role name' 'bad/role'; ans 'Role name' default; ans 'AppRole name for default'
    ans 'Role ID for default' 'SENTINEL has spaces'
    ans 'Role ID for default' SENTINEL-ROLE-ID-1
    ans 'Secret ID for default' ''
    ans 'Secret ID for default' SENTINEL-SECRET-ID-1
    ans_apply
    br_run install bao-run || br_fail 'install failed'
    br_has 'without spaces'; br_has 'a value is required'
    br_lacks SENTINEL
    [[ $(<"$BR_TEST_ROOT/etc/bao-run/role_id") == SENTINEL-ROLE-ID-1 ]] || br_fail 'reasked value not used'
}
test_address_reasked() {
    br_fixture
    ans 'Container ID' 101; ans 'Periphery runs as' systemd
    ans 'OpenBao URL' http://bao.example; ans 'OpenBao URL' https://u:p@bao.example; ans 'OpenBao URL' https://bao.example:8200
    ans 'CA file'; ans_role default; ans_apply n
    br_run install bao-run || br_fail 'install failed'
    br_has 'without credentials or a path'
}
test_at_least_one_role_required() {
    br_fixture
    br_install
    local before
    before=$(br_guest_tree)
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' remove
    ans 'Add a role' n
    ans 'Add a role' y; ans 'Role name' default
    ans 'Role name' other; ans 'AppRole name for other'; ans 'Role ID for other' SENTINEL-R; ans 'Secret ID for other' SENTINEL-S
    ans_apply n
    br_run install bao-run || br_fail 'decline failed'
    br_has 'at least one role'
    [[ $(br_guest_tree) == "$before" ]] || br_fail 'guest changed'
}
test_role_replace_and_remove() {
    br_fixture
    ans_to_role; ans_role default; ans_role app; ans_apply
    br_run install bao-run || br_fail 'install failed'
    # Roles are asked in the guest's order: default, then app.
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' replace; ans 'AppRole name for default'; ans 'Role ID for default' SENTINEL-NEW-R; ans 'Secret ID for default' SENTINEL-NEW-S
    ans 'Role app' remove
    ans_apply
    br_run install bao-run || br_fail 'change failed'
    [[ $(<"$BR_TEST_ROOT/etc/bao-run/role_id") == SENTINEL-NEW-R && ! -e $BR_TEST_ROOT/etc/bao-run/roles/app ]] || br_fail 'guest not changed'
    [[ $(br_conf bao-run-101 BR_ROLES) == default=komodo-docker01 ]] || br_fail "BR_ROLES: $(br_conf bao-run-101 BR_ROLES)"
    br_has 'bao delete auth/approle/role/komodo-docker01-app'
    # A stray file blocks removal, and the failure says so plainly.
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans_role app; ans_apply
    br_run install bao-run || br_fail 'adding app failed'
    : > "$BR_TEST_ROOT/etc/bao-run/roles/app/stray"
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans 'Role app' remove; ans_apply
    if br_run install bao-run; then br_fail 'removal with a stray file succeeded'; fi
    br_has 'other files'; br_has 'OpenBao is down'
    [[ $(br_conf bao-run-101 BR_ROLES) == *app=* ]] || br_fail 'failed removal changed the record'
}
test_unsupported_and_missing_tools_refused() {
    br_fixture
    printf 'ID=debian\nVERSION_ID="12"\n' > "$BR_TEST_ROOT/etc/os-release"
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'unsupported guest accepted'; fi
    br_has 'requires Debian 13 amd64 guest'
    br_fixture
    printf 'not-a-machine-id\n' > "$BR_TEST_ROOT/etc/machine-id"
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'bad machine ID accepted'; fi
    br_has 'invalid guest machine-id'
    br_fixture
    rm "$BR_TEST_ROOT/usr/bin/curl"
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'missing curl accepted'; fi
    br_has 'apt install curl'
    br_fixture
    rm "$BR_TEST_ROOT"/usr/bin/{curl,jq}
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'missing tools accepted'; fi
    br_has 'apt install curl jq'
    if grep -Eq '^(push|exec 101 -- mkdir)' "$BR_PCT_LOG"; then br_fail 'refused install touched the guest'; fi
    br_fixture
    printf '{"status":"stopped"}' > "$BR_HOST/status"
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'stopped CT accepted'; fi
    br_has 'not running'
    if grep -q '^exec' "$BR_PCT_LOG"; then br_fail 'exec in a stopped CT'; fi
}
test_adoption_of_manual_install() {
    br_fixture
    printf '#!/bin/bash\n# by hand\n' > "$BR_TEST_ROOT/usr/local/bin/bao-run"
    chmod 0755 "$BR_TEST_ROOT/usr/local/bin/bao-run"
    ans 'Container ID' 101; ans 'Adopt this existing payload' n
    if br_run install bao-run; then br_fail 'declined adoption continued'; fi
    grep -q 'by hand' "$BR_TEST_ROOT/usr/local/bin/bao-run" || br_fail 'payload replaced'
    ans 'Container ID' 101; ans 'Adopt this existing payload' y
    ans 'Periphery runs as' systemd; ans 'OpenBao URL' https://bao.example:8200; ans 'CA file'; ans_role default; ans_apply
    br_run install bao-run || br_fail 'adoption failed'
    cmp -s modules/bao-run/bao-run.sh "$BR_TEST_ROOT/usr/local/bin/bao-run" || br_fail 'not adopted'
    # Existing roles without a host record ask for the AppRole name when kept.
    rm -f "$TOOLBOX_CONF_DIR"/bao-run* "$TOOLBOX_STATE_DIR"/bao-run*
    ans 'Container ID' 101; ans 'Periphery runs as' systemd; ans 'OpenBao URL' https://bao.example:8200; ans 'CA file'
    ans 'Role default' keep; ans 'AppRole name for default' custom-name; ans_apply
    br_run install bao-run || br_fail 'reconcile failed'
    [[ $(br_conf bao-run-101 BR_ROLES) == default=custom-name && $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'not reconciled'
}
test_repeat_install_keep_all_is_noop() {
    br_fixture
    br_install
    local before state
    before=$(br_guest_tree)
    state=$(<"$TOOLBOX_STATE_DIR/bao-run-101.state")
    ans 'Container ID' 101; ans 'Periphery runs as'; ans 'OpenBao URL'; ans 'CA file'
    ans 'Role default' keep; ans_apply
    br_run install bao-run || br_fail 'repeat install failed'
    [[ $(br_guest_tree) == "$before" ]] || br_fail 'repeat install changed the guest'
    if grep -q '^curl' "$BR_TEST_ROOT/calls"; then br_fail 'repeat install logged in'; fi
    [[ $(<"$TOOLBOX_STATE_DIR/bao-run-101.state") == "$state" ]] || br_fail 'state changed'
    [[ $(br_conf bao-run-101 BR_ROLES) == default=komodo-docker01 && -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'records changed'
    br_no_stage; br_no_work
}
test_update_up_to_date_refreshes_recorded_state() {
    br_fixture
    br_install
    # An unknown outcome that really succeeded: the guest is current, the record is not.
    sed -i 's/^payload_sha256=.*/payload_sha256=stale/' "$TOOLBOX_STATE_DIR/bao-run-101.state"
    ans 'Container ID' 101
    br_run update bao-run || br_fail 'update failed'
    br_has 'up to date'
    grep -Fxq "payload_sha256=$(br_sha modules/bao-run/bao-run.sh)" "$TOOLBOX_STATE_DIR/bao-run-101.state" || br_fail 'state not refreshed'
    # So the next packaged payload is not mistaken for a hand edit.
    br_age_payload
    ans 'Container ID' 101; ans 'Apply this operation' n
    br_run update bao-run || br_fail 'update preview failed'
    br_lacks 'Adopt this edited payload'
}
br_age_payload() { # The payload as an earlier package installed and recorded it.
    local payload=$BR_TEST_ROOT/usr/local/bin/bao-run owner=$BR_TEST_ROOT/var/lib/pve-toolbox/bao-run/owner.json hash tmp
    printf '# older\n' >> "$payload"
    hash=$(br_sha "$payload")
    tmp=$(jq --arg h "$hash" '.payload_sha256 = $h' "$owner")
    printf '%s\n' "$tmp" > "$owner"
    sed -i "s/^payload_sha256=.*/payload_sha256=$hash/" "$TOOLBOX_STATE_DIR/bao-run-101.state"
}
test_update_requires_explicit_and_confirm() {
    br_fixture
    br_install
    br_age_payload
    local aged creds
    aged=$(br_sha "$BR_TEST_ROOT/usr/local/bin/bao-run")
    creds=$(<"$BR_TEST_ROOT/etc/bao-run/secret_id")
    ./pve-toolbox update > "$BR_SESSION" 2>&1 || br_fail 'plain update failed'
    br_has 'explicit selection'
    [[ $(br_sha "$BR_TEST_ROOT/usr/local/bin/bao-run") == "$aged" && ! -s $BR_PCT_LOG ]] || br_fail 'plain update touched the guest'
    ans 'Container ID' 999; ans 'Container ID' 101; ans 'Apply this operation' n
    br_run update bao-run || br_fail 'declined update failed'
    [[ $(br_sha "$BR_TEST_ROOT/usr/local/bin/bao-run") == "$aged" ]] || br_fail 'declined update changed the payload'
    ans 'Container ID' 101; ans 'Apply this operation' y
    br_run update bao-run || br_fail 'update failed'
    cmp -s modules/bao-run/bao-run.sh "$BR_TEST_ROOT/usr/local/bin/bao-run" || br_fail 'payload not updated'
    [[ $(<"$BR_TEST_ROOT/etc/bao-run/secret_id") == "$creds" ]] || br_fail 'credentials changed'
    grep -Fxq "payload_sha256=$(br_sha modules/bao-run/bao-run.sh)" "$TOOLBOX_STATE_DIR/bao-run-101.state" || br_fail 'state hash'
    br_no_stage; br_no_work
    ans 'Container ID' 101
    br_run update bao-run || br_fail 'current update failed'
    br_has 'up to date'
    # Edited by hand: neither hash matches, both are shown, and adoption is separate.
    printf '# edited\n' >> "$BR_TEST_ROOT/usr/local/bin/bao-run"
    ans 'Container ID' 101; ans 'Adopt this edited payload' n
    if br_run update bao-run; then br_fail 'declined adoption succeeded'; fi
    br_has "$(br_sha modules/bao-run/bao-run.sh | cut -c1-12)"
    grep -q edited "$BR_TEST_ROOT/usr/local/bin/bao-run" || br_fail 'edited payload replaced'
    ans 'Container ID' 101; ans 'Adopt this edited payload' y; ans 'Apply this operation' y
    br_run update bao-run || br_fail 'adopting update failed'
    cmp -s modules/bao-run/bao-run.sh "$BR_TEST_ROOT/usr/local/bin/bao-run" || br_fail 'edited payload not replaced'
}
test_check_is_read_only() {
    br_fixture
    br_install
    local before
    ./pve-toolbox check bao-run > "$BR_SESSION" 2>&1 || br_fail 'check failed'
    br_has 'CT 101: up to date'
    br_age_payload
    before=$(br_guest_tree)
    : > "$BR_TEST_ROOT/calls"
    ./pve-toolbox check bao-run > "$BR_SESSION" 2>&1 || br_fail 'check failed'
    br_has "update available: CT 101 $(br_sha "$BR_TEST_ROOT/usr/local/bin/bao-run" | cut -c1-12) -> $(br_sha modules/bao-run/bao-run.sh | cut -c1-12)"
    [[ $(br_guest_tree) == "$before" ]] || br_fail 'check changed the guest'
    if grep -q '^curl' "$BR_TEST_ROOT/calls"; then br_fail 'check logged in'; fi
    if grep -q '^push' "$BR_PCT_LOG"; then br_fail 'check pushed'; fi
    : > "$BR_HOST/pct-down"
    if ./pve-toolbox check bao-run > "$BR_SESSION" 2>&1; then br_fail 'check passed on an uninspectable CT'; fi
}
# The launcher keeps plain status at exit 0 for a named module, so that form is
# read for its text; --json status and doctor are the scripted interfaces.
br_status_fails() { # <label> <text the status must show>
    if ./pve-toolbox --json status bao-run > "$BR_SESSION" 2>&1; then br_fail "$1: --json status exited 0"; fi
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1 || br_fail "$1: plain status exit changed"
    br_has "$2"
    if ./pve-toolbox --json doctor > "$BR_SESSION" 2>&1; then br_fail "$1: doctor exited 0"; fi
    jq -e '[.results[] | select(.id == "module.bao-run.agents")] | length == 1 and .[0].state == "fail"' "$BR_SESSION" > /dev/null || br_fail "$1: doctor did not fail"
}
test_status_failure_modes() {
    br_fixture
    br_install
    ./pve-toolbox --json status bao-run > "$BR_SESSION" 2>&1 || br_fail 'healthy status failed'
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1
    br_has 'CT 101: payload current, curl jq ok, periphery systemd active'
    br_has 'default (komodo-docker01): credentials ok, login ok'
    br_lacks SENTINEL
    ./pve-toolbox --json doctor > "$BR_SESSION" 2>&1 || true
    jq -e '[.results[] | select(.id == "module.bao-run.agents")] | length == 1 and .[0].state == "pass"' "$BR_SESSION" > /dev/null || br_fail 'doctor did not pass'
    printf 'rejected\n' > "$BR_TEST_ROOT/curl-mode"
    br_status_fails rejected "this CT's IP matches"
    printf 'sealed\n' > "$BR_TEST_ROOT/curl-mode"
    br_status_fails unavailable 'it may be sealed'
    printf 'ok\n' > "$BR_TEST_ROOT/curl-mode"
    br_age_payload
    br_status_fails stale 'payload differs from packaged'
    br_fixture
    br_install
    chmod 0644 "$BR_TEST_ROOT/etc/bao-run/role_id"
    br_status_fails credentials 'credentials bad'
    br_fixture
    br_install
    printf 'LoadState=loaded\nActiveState=active\nUser=komodo\n' > "$BR_TEST_ROOT/unit"
    br_status_fails unreadable 'service user cannot read credentials'
    br_fixture
    br_install
    rm "$BR_TEST_ROOT/usr/bin/curl"
    br_status_fails tool 'curl missing'
    br_fixture
    br_install
    chmod 0644 "$BR_TEST_ROOT/usr/bin/curl"
    br_status_fails 'tool that will not run' 'curl missing'
    br_fixture
    br_install
    rm -rf "$BR_TEST_ROOT/etc/bao-run/role_id" "$BR_TEST_ROOT/etc/bao-run/secret_id"
    br_status_fails 'missing role' 'missing from the CT'
    br_fixture
    br_install
    printf 'fedcba9876543210fedcba9876543210\n' > "$BR_TEST_ROOT/etc/machine-id"
    br_status_fails identity 'identity mismatch'
    br_fixture
    br_install
    : > "$BR_HOST/pct-down"
    br_status_fails unreachable 'unreachable'
    br_fixture
    br_install
    (source lib/common.sh; conf_set bao-run-101 BR_PENDING aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa) || br_fail 'seeding pending'
    br_status_fails pending 'staging'
    # A container on the old file after a payload update.
    br_fixture
    printf '%s\n' "$(printf '0%.0s' {1..64})" > "$BR_TEST_ROOT/docker-sha"
    ans 'Container ID' 101; ans 'Periphery runs as' container; ans 'Periphery container name' periphery
    ans 'OpenBao URL' https://bao.example:8200; ans 'CA file'; ans_role default; ans_apply
    br_run install bao-run || br_fail 'container install failed'
    br_status_fails 'container hash' 'restart the Periphery container to load the new payload'
    # Guest strings cannot control the terminal.
    br_fixture
    br_install
    printf 'LoadState=loaded\nActiveState=act\033[31mive\nUser=\n' > "$BR_TEST_ROOT/unit"
    ./pve-toolbox status bao-run > "$BR_SESSION" 2>&1 || true
    if grep -aq $'\033\[31m' "$BR_SESSION"; then br_fail 'guest string reached the terminal'; fi
    br_no_stage
}
test_uninstall_clean_and_partial() {
    br_fixture
    br_install
    ans 'Container ID' 101; ans 'Apply this operation' n
    br_run uninstall bao-run || br_fail 'declined uninstall failed'
    [[ -e $BR_TEST_ROOT/etc/bao-run/role_id && $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'declined uninstall changed something'
    # Partial: a foreign file stays and the records stay.
    : > "$BR_TEST_ROOT/etc/bao-run/foreign"
    ans 'Container ID' 101; ans 'Apply this operation' y
    if br_run uninstall bao-run; then br_fail 'partial uninstall exited 0'; fi
    br_has '/etc/bao-run/foreign'
    br_has 'bao delete auth/approle/role/komodo-docker01'
    [[ $(br_conf bao-run BR_IDS) == 101 && -f $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || br_fail 'partial uninstall dropped records'
    [[ -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'BR_PENDING after partial'
    br_no_stage; br_no_work
    rm "$BR_TEST_ROOT/etc/bao-run/foreign"
    ans 'Container ID' 101; ans 'Apply this operation' y
    br_run uninstall bao-run || br_fail 'clean uninstall failed'
    br_has 'bao delete auth/approle/role/komodo-docker01'
    br_has 'stay valid'; br_has 'backups and snapshots'
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run.conf && ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf && ! -e $TOOLBOX_STATE_DIR/bao-run-101.state ]] || br_fail 'records left'
    [[ ! -e $BR_TEST_ROOT/etc/bao-run && ! -e $BR_TEST_ROOT/usr/local/bin/bao-run ]] || br_fail 'guest files left'
    br_no_stage; br_no_work
    [[ $(./pve-toolbox status bao-run) == *'not installed'* ]] || br_fail 'status after uninstall'
    # An unmatched payload needs its own answer.
    br_install
    printf '# edited\n' >> "$BR_TEST_ROOT/usr/local/bin/bao-run"
    ans 'Container ID' 101; ans 'Remove the unmatched payload' n; ans 'Apply this operation' y
    if br_run uninstall bao-run; then br_fail 'kept payload exited 0'; fi
    grep -q edited "$BR_TEST_ROOT/usr/local/bin/bao-run" || br_fail 'unmatched payload removed'
    ans 'Container ID' 101; ans 'Remove the unmatched payload' y; ans 'Apply this operation' y
    br_run uninstall bao-run || br_fail 'unmatched uninstall failed'
    [[ ! -e $BR_TEST_ROOT/usr/local/bin/bao-run ]] || br_fail 'unmatched payload kept'
}
br_mounting_container() { # A stopped container still holding the bind mount.
    printf '[{"Id":"aaaaaaaaaaaa","Name":"/periphery","State":{"Running":false},"Mounts":[{"Type":"bind","Source":"/etc/bao-run","Destination":"/etc/bao-run"}]}]' \
        > "$BR_TEST_ROOT/docker-inspect"
}
test_uninstall_refused_while_a_container_mounts_our_paths() {
    br_fixture
    br_install
    br_mounting_container
    local before
    before=$(br_guest_tree)
    # No answer is scripted for an override: the driver fails if one is offered.
    ans 'Container ID' 101; ans 'Apply this operation' y
    if br_run uninstall bao-run; then br_fail 'refused uninstall exited 0'; fi
    br_has 'periphery'; br_has 'remove those mounts'; br_has 'recreate'
    br_lacks 'without the mount check'
    br_lacks 'bao delete'
    [[ $(br_guest_tree) == "$before" ]] || br_fail 'guest changed'
    [[ $(br_conf bao-run BR_IDS) == 101 && -f $TOOLBOX_CONF_DIR/bao-run-101.conf && -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'records changed'
    br_no_stage; br_no_work
}
test_uninstall_mount_check_unavailable_needs_confirmation() {
    br_fixture
    br_install
    : > "$BR_TEST_ROOT/docker-down"
    local before
    before=$(br_guest_tree)
    # The default answer is no.
    ans 'Container ID' 101; ans 'Apply this operation' y; ans 'without the mount check'
    if br_run uninstall bao-run; then br_fail 'declined uninstall exited 0'; fi
    br_has 'mount check unavailable'; br_has 'check that it is running'
    br_has 'will not start again'
    br_lacks 'bao delete'
    [[ $(br_guest_tree) == "$before" ]] || br_fail 'declined uninstall changed the guest'
    [[ $(br_conf bao-run BR_IDS) == 101 && -z $(br_conf bao-run-101 BR_PENDING) ]] || br_fail 'declined uninstall changed the records'
    br_no_stage; br_no_work
    # Confirmed: a fresh request carries the override and the outcome rules are unchanged.
    ans 'Container ID' 101; ans 'Apply this operation' y; ans 'without the mount check' y
    br_run uninstall bao-run || br_fail 'confirmed uninstall failed'
    br_has 'bao delete auth/approle/role/komodo-docker01'
    [[ ! -e $BR_TEST_ROOT/etc/bao-run && ! -e $BR_TEST_ROOT/usr/local/bin/bao-run ]] || br_fail 'guest files left'
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run.conf && ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || br_fail 'records left'
    br_no_stage; br_no_work
    # Docker came back between the two tries and says the mount is there: no override.
    br_fixture
    br_install
    printf '[{"Id":"aaaaaaaaaaaa","Name":"/periphery","Mounts":[{"Type":"bind","Source":"/etc/bao-run"}]}]' > "$BR_TEST_ROOT/docker-inspect"
    : > "$BR_TEST_ROOT/docker-down"
    : > "$BR_HOST/docker-up-after-first-apply"
    ans 'Container ID' 101; ans 'Apply this operation' y; ans 'without the mount check' y
    if br_run uninstall bao-run; then br_fail 'override applied to a match'; fi
    br_has 'remove those mounts'
    br_lacks 'bao delete'
    [[ -e $BR_TEST_ROOT/etc/bao-run/secret_id && $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'match was overridden'
    br_no_stage; br_no_work
}
test_install_explains_a_directory_docker_left() {
    br_fixture
    mkdir "$BR_TEST_ROOT/usr/local/bin/bao-run"
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'directory accepted'; fi
    br_has 'rmdir /usr/local/bin/bao-run'; br_has 'recreate the container'
    if grep -q '^push' "$BR_PCT_LOG"; then br_fail 'pushed over a directory'; fi
}
test_login_not_checked_fails_status() {
    br_fixture
    br_install
    printf '%s' '.roles[0].login = "not-checked"' > "$BR_HOST/status-filter"
    br_status_fails 'valid files, no check' 'credentials ok, login not-checked'
}
test_uninstall_keeps_other_ct() {
    br_fixture
    br_install
    (source lib/common.sh; conf_set bao-run BR_IDS '101 102') || br_fail 'seeding'
    ans 'Container ID' 101; ans 'Apply this operation' y
    br_run uninstall bao-run || br_fail 'uninstall failed'
    [[ $(br_conf bao-run BR_IDS) == 102 ]] || br_fail 'other CT dropped'
}
test_uninstall_forget_destroyed_ct() {
    br_fixture
    br_install
    printf '[]' > "$BR_HOST/inventory"
    ans 'Container ID' 101; ans 'Forget' n
    if br_run uninstall bao-run; then br_fail 'declined forget exited 0'; fi
    [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'declined forget dropped records'
    ans 'Container ID' 101; ans 'Forget' y
    br_run uninstall bao-run || br_fail 'forget failed'
    br_has 'bao delete auth/approle/role/komodo-docker01'
    br_has 'stay valid'
    br_has 'only if the container was really destroyed; on a migrated container these break working logins'
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run.conf && ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || br_fail 'records left'
    if grep -Eq '^(exec|push)' "$BR_PCT_LOG"; then br_fail 'touched a destroyed CT'; fi
    # Recreated under the same ID: refused unless forgotten, never pushed.
    br_fixture
    br_install
    printf 'fedcba9876543210fedcba9876543210\n' > "$BR_TEST_ROOT/etc/machine-id"
    ans 'Container ID' 101; ans 'Forget' n
    if br_run uninstall bao-run; then br_fail 'mismatch uninstall exited 0'; fi
    [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'mismatch dropped records'
    ans 'Container ID' 101; ans 'Forget' y
    br_run uninstall bao-run || br_fail 'mismatch forget failed'
    br_has 'bao delete auth/approle/role/komodo-docker01'
    br_has 'only if the container was really destroyed; on a migrated container these break working logins'
    [[ ! -e $TOOLBOX_CONF_DIR/bao-run-101.conf ]] || br_fail 'record left'
    if grep -q '^push' "$BR_PCT_LOG"; then br_fail 'pushed to a recreated CT'; fi
    # Stopped: refused, records kept, no forget offered.
    br_fixture
    br_install
    printf '{"status":"stopped"}' > "$BR_HOST/status"
    ans 'Container ID' 101
    if br_run uninstall bao-run; then br_fail 'stopped uninstall exited 0'; fi
    br_lacks 'Forget'
    [[ $(br_conf bao-run BR_IDS) == 101 ]] || br_fail 'stopped dropped records'
}
test_config_show_hides_nothing_secret() {
    br_fixture
    br_install
    ./pve-toolbox config show bao-run > "$BR_SESSION" 2>&1 || br_fail 'config show failed'
    br_has 'BR_ADDR'; br_has 'https://bao.example:8200'; br_has 'default=komodo-docker01'
    br_lacks SENTINEL
    if grep -aqi 'secret_id\|role_id' "$BR_SESSION"; then br_fail 'credential key listed'; fi
}
test_unsafe_host_record_refused() {
    br_fixture
    mkdir -p "$TOOLBOX_CONF_DIR"
    printf 'touch %q\n' "$BR_T/unsafe-source" > "$TOOLBOX_CONF_DIR/bao-run-101.conf"
    chown 1000:1000 "$TOOLBOX_CONF_DIR/bao-run-101.conf"
    ans 'Container ID' 101
    if br_run install bao-run; then br_fail 'untrusted record accepted'; fi
    [[ ! -e $BR_T/unsafe-source ]] || br_fail 'untrusted record was sourced'
    # Each lifecycle action refuses the unsafe index instead of reading it as empty.
    br_fixture
    mkdir -p "$TOOLBOX_CONF_DIR"
    printf 'touch %q\n' "$BR_T/unsafe-source" > "$TOOLBOX_CONF_DIR/bao-run.conf"
    chown 1000:1000 "$TOOLBOX_CONF_DIR/bao-run.conf"
    local action
    for action in update uninstall; do
        if br_run "$action" bao-run; then br_fail "$action accepted an untrusted index"; fi
    done
    if ./pve-toolbox check bao-run > "$BR_SESSION" 2>&1; then br_fail 'check accepted an untrusted index'; fi
    [[ ! -e $BR_T/unsafe-source ]] || br_fail 'untrusted index was sourced'
}

failed=0
for test_name in $(declare -F | awk '$3 ~ /^portable_/ {print $3}'); do
    if ("$test_name"); then printf 'ok  %s\n' "$test_name"
    else printf 'FAIL %s\n' "$test_name" >&2; failed=1; fi
done
if [[ $EUID != 0 ]] || ! command -v expect > /dev/null; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || { printf 'FAIL bao-run host flow requires root and expect\n' >&2; exit 1; }
    printf 'skip bao-run host flow (root and expect required)\n'
    exit "$failed"
fi
br_base_ready
for test_name in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    if ("$test_name"); then printf 'ok  %s\n' "$test_name"
    else printf 'FAIL %s\n' "$test_name" >&2; failed=1; fi
done
exit "$failed"
