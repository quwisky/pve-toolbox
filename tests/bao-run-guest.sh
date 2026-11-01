#!/usr/bin/env bash
# modules/bao-run/guest.sh in a chroot, against curl/systemctl/docker/runuser doubles.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 ]]; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'bao-run guest tests require root/chroot'
    printf 'skip bao-run guest tests (root/chroot required)\n'; exit 0
fi

BT_TX=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BT_MACHINE=0123456789abcdef0123456789abcdef
BT_WORK=$(mktemp -d)
trap 'rm -rf -- "$BT_WORK"' EXIT
BT_BASE=$BT_WORK/base
BT_ROOT=$BT_WORK/guest
BT_OUT=$BT_WORK/out
BT_ERR=$BT_WORK/err
BT_STAGE=$BT_ROOT/run/pve-toolbox-bao-run-$BT_TX
BT_REQ=/run/pve-toolbox-bao-run-$BT_TX/request.json

mkdir -p "$BT_BASE"/{usr/local/bin,etc,run,tmp,root,var/lib,dev}
bt_copy_bin() {
    local bin path
    bin=$(command -v "$1")
    cp --parents "$bin" "$BT_BASE"
    while IFS= read -r path; do cp --parents "$path" "$BT_BASE"; done < <(ldd "$bin" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}')
}
for cmd in bash jq env cat chmod cmp cp cut find flock head mkdir mktemp mv readlink realpath rm rmdir sed sha256sum sort stat sync timeout tr; do bt_copy_bin "$cmd"; done
ln -s usr/bin "$BT_BASE/bin"
: > "$BT_BASE/dev/null" # A regular file also collects whatever the guest hides from stderr.
cp /etc/ld.so.cache "$BT_BASE/etc/"
printf 'ID=debian\nVERSION_ID="13"\n' > "$BT_BASE/etc/os-release"
printf '%s\n' "$BT_MACHINE" > "$BT_BASE/etc/machine-id"
mv "$BT_BASE/usr/bin/mv" "$BT_BASE/usr/bin/mv-real"
mv "$BT_BASE/usr/bin/jq" "$BT_BASE/usr/bin/jq-real"
cat > "$BT_BASE/usr/bin/bt-double" <<'DOUBLE'
#!/bin/bash
# One double per command name. Every call is logged so tests can inspect argv.
[[ ${0##*/} != curl || ${1:-} != --version ]] || exit 0 # A tool check, not a network call.
printf '%s %s\n' "${0##*/}" "$*" >> /calls
case ${0##*/} in
    jq) exec /usr/bin/jq-real "$@" ;;
    uname) printf 'x86_64\n' ;;
    mv)
        dest=${*: -1}
        if [[ -f /signal-at-mv ]]; then # <call number> <signal>, sent to the guest during that mv.
            read -r at signal < /signal-at-mv
            count=$(($(cat /mv-count 2>/dev/null || printf 0) + 1)); printf '%s\n' "$count" > /mv-count
            [[ $count != "$at" ]] || kill "-$signal" "$PPID"
        fi
        [[ ! -f /fail-mv || $(</fail-mv) != "$dest" ]] || exit 1
        if [[ -f /fail-mv-second && $(</fail-mv-second) == "$dest" ]]; then
            [[ ! -f /mv-seen ]] || exit 1
            : > /mv-seen
        fi
        exec /usr/bin/mv-real "$@" ;;
    curl)
        IFS= read -r -d '' _ || true
        [[ $* != *revoke-self* ]] || exit 0
        mode=$(</curl-mode)
        # Only the candidate check runs with BAO_RUN_CONF set.
        [[ -n ${BAO_RUN_CONF:-} || ! -f /curl-final-mode ]] || mode=$(</curl-final-mode)
        case $mode in
            ok) printf '{"auth":{"client_token":"token"}}\n200' ;;
            rejected) printf '{"errors":["denied"]}\n400'; exit 22 ;;
            sealed) printf '{"errors":["sealed"]}\n503'; exit 22 ;;
            tls) exit 60 ;;
            down) exit 7 ;;
        esac ;;
    systemctl)
        [[ $1 == show ]] || exit 99
        cat /unit ;;
    runuser)
        [[ $* == '-u komodo -- test -r /etc/bao-run/addr' ]] || exit 99
        [[ -f /runuser-can-read ]] ;;
    docker)
        # /docker-inspect is the world: every container, running or stopped, as docker inspect shows it.
        [[ ! -f /docker-down ]] || { printf 'Cannot connect to the Docker daemon\n' >&2; exit 1; }
        case $1 in
            ps)
                [[ ! -f /docker-ps-raw ]] || { cat /docker-ps-raw; exit 0; }
                [[ -f /docker-inspect ]] || exit 0
                case $2 in
                    -aq) jq -r '.[].Id' /docker-inspect ;;
                    -q) jq -r '.[] | select(.State.Running).Id' /docker-inspect ;;
                    *) exit 99 ;;
                esac
                exit ;;
            inspect)
                [[ ! -f /docker-inspect-down ]] || exit 1
                [[ ! -f /docker-inspect-garbage ]] || { printf 'not json\n'; exit 0; }
                [[ $* == "inspect --type container $(jq -r 'map(.Id) | join(" ")' /docker-inspect)" ]] || exit 99
                cat /docker-inspect
                exit ;;
        esac
        [[ $1 == exec ]] || exit 99
        shift 2
        case $* in
            'sh -c :') ;;
            'sh -c bash -c : && curl --version && jq -n 1') [[ ! -f /docker-tools-broken ]] ;;
            'test -r /etc/bao-run/addr') ;;
            'sha256sum /usr/local/bin/bao-run') printf '%s  /usr/local/bin/bao-run\n' "$(</docker-sha)" ;;
            '/usr/local/bin/bao-run --check'*)
                word=$(</docker-login); printf '%s\n' "$word"; [[ $word == ok ]] ;;
            *) exit 99 ;;
        esac ;;
    *) exit 99 ;;
esac
DOUBLE
chmod 0755 "$BT_BASE/usr/bin/bt-double"
for cmd in uname mv jq curl systemctl runuser docker; do cp "$BT_BASE/usr/bin/bt-double" "$BT_BASE/usr/bin/$cmd"; done

bt_fixture() {
    rm -rf -- "$BT_ROOT"
    cp -a "$BT_BASE" "$BT_ROOT"
    cp modules/bao-run/guest.sh "$BT_ROOT/guest.sh"
    : > "$BT_ROOT/calls"
    printf 'ok\n' > "$BT_ROOT/curl-mode"
    printf 'LoadState=loaded\nActiveState=active\nUser=\n' > "$BT_ROOT/unit"
    mkdir -m 0700 "$BT_STAGE"
    cp modules/bao-run/bao-run.sh "$BT_STAGE/bao-run"
}
# Every guest run must keep the output contract, whatever it did.
bt_guest() {
    local rc=0 where
    chroot "$BT_ROOT" /bin/bash /guest.sh "$@" > "$BT_OUT" 2> "$BT_ERR" || rc=$?
    for where in "$BT_OUT" "$BT_ERR" "$BT_ROOT/calls" "$BT_ROOT/dev/null"; do
        if grep -aq SENTINEL "$where"; then fail "secret leaked to ${where##*/}"; fi
    done
    [[ ! -s $BT_ERR ]] || fail "guest wrote to stderr: $(<"$BT_ERR")"
    (( $(stat -c %s "$BT_OUT") <= 65536 )) || fail 'output exceeds 65536 bytes'
    jq -e 'type == "object"' "$BT_OUT" > /dev/null || fail "output is not one JSON object: $(<"$BT_OUT")"
    [[ ! -e $BT_STAGE/conf ]] || fail 'stage conf left behind'
    # After an incomplete restore the backup is the only copy of the previous files.
    [[ ! -e $BT_STAGE/backup ]] || grep -q 'restore incomplete' "$BT_OUT" || fail 'stage backup left behind'
    return "$rc"
}
bt_out() { jq -e "$1" "$BT_OUT" > /dev/null || fail "${2:-unexpected output}: $1: $(<"$BT_OUT")"; }
bt_hash() { sha256sum "$1" | cut -d ' ' -f1; }
# A valid request for the current state; the filter breaks or extends it.
bt_request() {
    local cur=absent sha
    sha=$(bt_hash "$BT_STAGE/bao-run")
    [[ ! -f $BT_ROOT/usr/local/bin/bao-run ]] || cur=$(bt_hash "$BT_ROOT/usr/local/bin/bao-run")
    rm -f "$BT_ROOT$BT_REQ"
    jq -n --arg tx "$BT_TX" --arg m "$BT_MACHINE" --arg sha "$sha" --arg cur "$cur" '{schema:1,action:"install",
        transaction_id:$tx,machine_id:$m,expected_payload_sha256:$cur,adopt:false,payload_sha256:$sha,
        addr:"https://bao.example:8200",ca_action:"keep",ca_pem:"",
        roles:[{name:"default",action:"replace",role_id:"ROLE-SENTINEL",secret_id:"SECRET-SENTINEL"}],
        remove_unmatched_payload:false}' | jq "${1:-.}" > "$BT_ROOT$BT_REQ"
    chmod 0600 "$BT_ROOT$BT_REQ"
}
bt_new_payload() { printf '# %s\n' "$1" >> "$BT_STAGE/bao-run"; }
bt_apply() { bt_guest apply "$BT_REQ"; }
bt_install() { bt_fixture; bt_request "${1:-.}"; bt_apply || fail "install failed: $(<"$BT_OUT")"; : > "$BT_ROOT/calls"; }
bt_tree() { # Paths, types, modes, owners and contents.
    (cd "$BT_ROOT" && find etc usr/local var/lib -printf '%p %y %m %u %l\n' | sort
     find etc usr/local var/lib -type f -exec sha256sum {} + | sort)
}
bt_times() { (cd "$BT_ROOT" && find etc usr/local var/lib -printf '%p %T@ %C@\n' | sort); }
bt_snapshot() { BT_TREE=$(bt_tree); BT_TIMES=$(bt_times); }
bt_unchanged() { # Nothing was even rewritten.
    [[ $(bt_tree) == "$BT_TREE" ]] || fail "$1: tree changed"
    [[ $(bt_times) == "$BT_TIMES" ]] || fail "$1: files were rewritten"
}
bt_no_network() { if grep -q '^curl' "$BT_ROOT/calls"; then fail "$1: unexpected network call"; fi; }
bt_refused() { # <label>: applying the current request fails and touches nothing.
    bt_snapshot
    if bt_apply; then fail "$1: accepted"; fi
    bt_out '.result == "failed" and .reason != ""' "$1"
    bt_unchanged "$1"
}
bt_mode() { [[ $(stat -c '%a %U' "$BT_ROOT$2") == "$1 root" ]] || fail "$2 is $(stat -c '%a %U' "$BT_ROOT$2"), wanted $1 root"; }
bt_gone() { local path; for path; do [[ ! -e $BT_ROOT$path && ! -L $BT_ROOT$path ]] || fail "$path still exists"; done; }

test_fresh_install_success() {
    bt_fixture
    bt_request '.ca_action="replace" | .ca_pem="-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----\n"
        | .roles += [{name:"app",action:"replace",role_id:"ROLE-SENTINEL-2",secret_id:"SECRET-SENTINEL-2"}]'
    bt_apply || fail "install failed: $(<"$BT_OUT")"
    bt_out '.schema == 1 and .result == "success" and .reason == "" and .changed == false'
    bt_out ".transaction_id == \"$BT_TX\" and .payload_sha256 == \"$(bt_hash "$BT_STAGE/bao-run")\""
    bt_out '.login == [{name:"default",login:"ok"},{name:"app",login:"ok"}] and .remaining == []'
    bt_mode 755 /usr/local/bin/bao-run
    bt_mode 700 /etc/bao-run; bt_mode 700 /etc/bao-run/roles; bt_mode 700 /etc/bao-run/roles/app
    local file
    for file in addr ca.pem role_id secret_id roles/app/role_id roles/app/secret_id; do bt_mode 600 "/etc/bao-run/$file"; done
    bt_mode 600 /var/lib/pve-toolbox/bao-run/owner.json
    [[ $(<"$BT_ROOT/etc/bao-run/addr") == https://bao.example:8200 ]] || fail 'addr content'
    [[ $(<"$BT_ROOT/etc/bao-run/secret_id") == SECRET-SENTINEL ]] || fail 'secret_id content'
    [[ $(<"$BT_ROOT/etc/bao-run/roles/app/role_id") == ROLE-SENTINEL-2 ]] || fail 'role content'
    [[ $(bt_hash "$BT_ROOT/usr/local/bin/bao-run") == "$(bt_hash "$BT_STAGE/bao-run")" ]] || fail 'payload content'
    jq -e --arg m "$BT_MACHINE" --arg h "$(bt_hash "$BT_STAGE/bao-run")" \
        '. == {schema:1,machine_id:$m,payload_sha256:$h}' "$BT_ROOT/var/lib/pve-toolbox/bao-run/owner.json" > /dev/null || fail 'owner record'
    # Candidate and final check for two roles: four logins, four revocations.
    [[ $(grep -c '^curl' "$BT_ROOT/calls") == 8 ]] || fail 'expected candidate and final checks'
}

test_failed_candidate_login_changes_nothing() {
    bt_fixture
    printf 'rejected\n' > "$BT_ROOT/curl-mode"
    bt_request
    bt_refused 'fresh host'
    bt_out '.reason == "login check failed" and .login == [{name:"default",login:"rejected"}]'
    bt_install
    printf 'rejected\n' > "$BT_ROOT/curl-mode"
    bt_request '.action="update" | .roles[0].secret_id="SECRET-SENTINEL-NEW"'
    bt_refused 'existing credentials'
    bt_out '.reason == "login check failed"'
}

test_sealed_openbao_reports_unavailable() {
    bt_fixture
    printf 'sealed\n' > "$BT_ROOT/curl-mode"
    bt_request
    bt_refused 'sealed apply'
    bt_out '.login == [{name:"default",login:"unavailable"}]'
    bt_install
    printf 'sealed\n' > "$BT_ROOT/curl-mode"
    bt_guest status --login || fail 'status failed'
    bt_out '.roles == [{name:"default",files_ok:true,login:"unavailable"}]'
}

test_final_check_failure_restores() {
    bt_install
    local tree
    tree=$(bt_tree)
    printf 'rejected\n' > "$BT_ROOT/curl-final-mode"
    bt_new_payload v2
    bt_request '.action="update" | .addr="https://other.example:8200" | .ca_action="replace" | .ca_pem="-----BEGIN CERTIFICATE-----\nx\n"
        | .roles=[{name:"default",action:"replace",role_id:"ROLE-SENTINEL-NEW",secret_id:"SECRET-SENTINEL-NEW"},
                  {name:"app",action:"replace",role_id:"ROLE-SENTINEL-2",secret_id:"SECRET-SENTINEL-2"}]'
    if bt_apply; then fail 'final failure accepted'; fi
    bt_out '.result == "failed" and .reason == "final login check failed; previous files restored"'
    bt_out '.login | map(.login) | index("rejected") != null'
    [[ $(bt_tree) == "$tree" ]] || fail 'previous files not restored'
}

test_swap_failure_restores() {
    bt_install
    local tree
    tree=$(bt_tree)
    printf '/etc/bao-run/secret_id\n' > "$BT_ROOT/fail-mv"
    bt_new_payload v2
    bt_request '.action="update" | .roles[0].role_id="ROLE-SENTINEL-NEW" | .roles[0].secret_id="SECRET-SENTINEL-NEW"'
    if bt_apply; then fail 'swap failure accepted'; fi
    bt_out '.result == "failed" and (.reason | endswith("previous files restored")) and .changed == false'
    [[ $(bt_tree) == "$tree" ]] || fail 'previous files not restored'
}

test_signal_during_swap_leaves_no_temp() {
    local signal tree
    for signal in TERM INT HUP; do
        bt_install
        tree=$(bt_tree)
        # The signal lands during the first swap's mv, which fails, so the temp with the new secret is still there.
        printf '/etc/bao-run/role_id\n' > "$BT_ROOT/fail-mv"
        printf '1 %s\n' "$signal" > "$BT_ROOT/signal-at-mv"
        bt_request '.action="update" | .roles[0].role_id="ROLE-SENTINEL-NEW" | .roles[0].secret_id="SECRET-SENTINEL-NEW"'
        if bt_apply; then fail "$signal: interrupted swap accepted"; fi
        bt_out '.result == "failed" and (.reason | endswith("previous files restored"))' "$signal"
        [[ -z $(find "$BT_ROOT/etc/bao-run" -name '.bao-run.*') ]] || fail "$signal: temp left: $(find "$BT_ROOT/etc/bao-run" -name '.bao-run.*')"
        [[ $(bt_tree) == "$tree" ]] || fail "$signal: previous files not restored"
    done
}

test_restore_failure_is_visible() {
    bt_install
    printf 'rejected\n' > "$BT_ROOT/curl-final-mode"
    printf '/etc/bao-run/secret_id\n' > "$BT_ROOT/fail-mv-second"
    bt_request '.action="update" | .roles[0].secret_id="SECRET-SENTINEL-NEW"'
    if bt_apply; then fail 'restore failure accepted'; fi
    bt_out '.result == "failed" and (.reason | test("restore incomplete")) and .changed == true'
    [[ $(<"$BT_ROOT/etc/bao-run/secret_id") == SECRET-SENTINEL-NEW ]] || fail 'expected the failed restore to leave the new secret'
    [[ -d $BT_STAGE/backup && ! -e $BT_STAGE/conf ]] || fail 'incomplete restore must keep backup and remove conf'
    [[ $(<"$BT_STAGE/backup/0") == SECRET-SENTINEL ]] || fail 'backup lost the previous secret'
    [[ $(stat -c %a "$BT_STAGE/backup/0") == 600 ]] || fail 'backup copy mode'
}

test_signal_during_restore_is_ignored() {
    local signal tree
    for signal in TERM INT HUP; do
        bt_install
        tree=$(bt_tree)
        printf 'rejected\n' > "$BT_ROOT/curl-final-mode"
        # Swaps are calls 1 and 2, so call 3 is the restore of secret_id, with role_id still to go.
        printf '3 %s\n' "$signal" > "$BT_ROOT/signal-at-mv"
        bt_request '.action="update" | .roles[0].role_id="ROLE-SENTINEL-NEW" | .roles[0].secret_id="SECRET-SENTINEL-NEW"'
        if bt_apply; then fail "$signal: final failure accepted"; fi
        [[ $(<"$BT_ROOT/mv-count") == 4 ]] || fail "$signal: restore did not finish"
        bt_out '.result == "failed" and .reason == "final login check failed; previous files restored"' "$signal"
        [[ $(bt_tree) == "$tree" ]] || fail "$signal: previous files not restored"
    done
}

test_repeat_install_writes_nothing() {
    bt_install
    bt_request '.action="update"'
    bt_snapshot
    bt_apply || fail "repeat failed: $(<"$BT_OUT")"
    bt_out '.result == "success"'
    bt_unchanged 'repeat'
    bt_no_network 'repeat'
}

test_update_payload_only_keeps_credentials() {
    bt_install
    local role secret
    role=$(bt_hash "$BT_ROOT/etc/bao-run/role_id"); secret=$(bt_hash "$BT_ROOT/etc/bao-run/secret_id")
    bt_new_payload v2
    bt_request '.action="update" | .addr="" | .roles=[]'
    bt_apply || fail "update failed: $(<"$BT_OUT")"
    [[ $(bt_hash "$BT_ROOT/etc/bao-run/role_id") == "$role" && $(bt_hash "$BT_ROOT/etc/bao-run/secret_id") == "$secret" ]] || fail 'credentials changed'
    [[ $(bt_hash "$BT_ROOT/usr/local/bin/bao-run") == "$(bt_hash "$BT_STAGE/bao-run")" ]] || fail 'payload not updated'
    jq -e --arg h "$(bt_hash "$BT_STAGE/bao-run")" '.payload_sha256 == $h' "$BT_ROOT/var/lib/pve-toolbox/bao-run/owner.json" > /dev/null || fail 'owner not updated'
    [[ $(<"$BT_ROOT/etc/bao-run/addr") == https://bao.example:8200 ]] || fail 'addr changed'
    bt_no_network 'payload-only update'
}

test_adoption_required_then_keeps_credentials() {
    bt_fixture
    cp modules/bao-run/bao-run.sh "$BT_ROOT/usr/local/bin/bao-run"; chmod 0755 "$BT_ROOT/usr/local/bin/bao-run"
    mkdir -m 0700 "$BT_ROOT/etc/bao-run"
    printf 'https://manual.example:8200\n' > "$BT_ROOT/etc/bao-run/addr"
    printf 'ROLE-SENTINEL-MANUAL\n' > "$BT_ROOT/etc/bao-run/role_id"
    printf 'SECRET-SENTINEL-MANUAL\n' > "$BT_ROOT/etc/bao-run/secret_id"
    chmod 0600 "$BT_ROOT"/etc/bao-run/*
    local creds
    creds=$(cat "$BT_ROOT"/etc/bao-run/*; stat -c '%n %a %Y' "$BT_ROOT"/etc/bao-run/*)
    bt_new_payload v2
    bt_request '.action="update" | .addr="" | .roles=[]'
    bt_refused 'no adoption'
    bt_guest status
    bt_out '.payload.present and (.payload.owned | not)'
    bt_request '.action="update" | .addr="" | .roles=[] | .adopt=true'
    bt_apply || fail "adoption failed: $(<"$BT_OUT")"
    [[ $(cat "$BT_ROOT"/etc/bao-run/*; stat -c '%n %a %Y' "$BT_ROOT"/etc/bao-run/*) == "$creds" ]] || fail 'credentials changed'
    bt_guest status
    bt_out '.payload.owned and .addr_present'
    # An owner record for another hash needs adoption too.
    printf '# edited by hand\n' >> "$BT_ROOT/usr/local/bin/bao-run"
    bt_request '.action="update" | .addr="" | .roles=[]'
    bt_refused 'modified payload'
}

test_adoption_tightens_kept_credentials() {
    bt_fixture
    cp modules/bao-run/bao-run.sh "$BT_ROOT/usr/local/bin/bao-run"; chmod 0755 "$BT_ROOT/usr/local/bin/bao-run"
    mkdir -m 0700 "$BT_ROOT/etc/bao-run" "$BT_ROOT/etc/bao-run/roles" "$BT_ROOT/etc/bao-run/roles/app"
    printf 'https://manual.example:8200\n' > "$BT_ROOT/etc/bao-run/addr"
    local file
    for file in role_id secret_id roles/app/role_id roles/app/secret_id; do
        printf 'SENTINEL-MANUAL-%s\n' "$file" > "$BT_ROOT/etc/bao-run/$file"
        chmod 0640 "$BT_ROOT/etc/bao-run/$file"
    done
    chmod 0600 "$BT_ROOT/etc/bao-run/addr"
    bt_guest status
    bt_out '[.roles[].files_ok] == [false, false]'
    # Without adoption a kept role is left exactly as it is.
    bt_new_payload v2
    bt_request '.action="install" | .addr="" | .roles=[] | .adopt=false'
    bt_refused 'no adoption'
    bt_request '.action="install" | .addr="" | .roles=[] | .adopt=true'
    bt_apply || fail "adoption failed: $(<"$BT_OUT")"
    for file in role_id secret_id roles/app/role_id roles/app/secret_id; do
        bt_mode 600 "/etc/bao-run/$file"
        [[ $(<"$BT_ROOT/etc/bao-run/$file") == "SENTINEL-MANUAL-$file" ]] || fail "$file content changed"
    done
    bt_no_network 'same-content swap'
    bt_guest status
    bt_out '[.roles[].files_ok] == [true, true]'
    # Once owned, a repeat run has nothing to tighten and rewrites nothing.
    bt_request '.action="install" | .addr="" | .roles=[]'
    bt_snapshot
    bt_apply || fail "repeat failed: $(<"$BT_OUT")"
    bt_unchanged 'repeat after adoption'
}

test_symlink_targets_refused() {
    local action
    for action in install uninstall; do
        bt_fixture
        mkdir -m 0700 "$BT_ROOT/victim"
        printf 'SECRET-SENTINEL-VICTIM\n' > "$BT_ROOT/victim/secret_id"
        ln -s /victim "$BT_ROOT/etc/bao-run"
        bt_request ".action=\"$action\""
        local victim
        victim=$(stat -c '%Y %a' "$BT_ROOT/victim/secret_id"; cat "$BT_ROOT/victim/secret_id")
        bt_refused "$action through a symlinked /etc/bao-run"
        [[ $(stat -c '%Y %a' "$BT_ROOT/victim/secret_id"; cat "$BT_ROOT/victim/secret_id") == "$victim" ]] || fail 'target changed'
        [[ -L $BT_ROOT/etc/bao-run ]] || fail 'symlink replaced'
    done
    bt_guest status || fail 'status failed on a symlinked directory'
    bt_out '(.supported | not) and .reason != "" and .roles == [] and (.addr_present | not)'
    for action in update uninstall; do
        bt_install
        printf 'SECRET-SENTINEL-VICTIM\n' > "$BT_ROOT/victim"
        ln -sf /victim "$BT_ROOT/etc/bao-run/secret_id"
        bt_request ".action=\"$action\" | .roles[0].secret_id=\"SECRET-SENTINEL-NEW\""
        bt_refused "$action through a symlinked secret_id"
        [[ $(<"$BT_ROOT/victim") == SECRET-SENTINEL-VICTIM ]] || fail 'target changed'
    done
    bt_guest status
    bt_out '.roles == [{name:"default",files_ok:false,login:"not-checked"}]'
    bt_install
    ln -sf /usr/bin/env "$BT_ROOT/usr/local/bin/bao-run"
    bt_request '.action="uninstall"'
    bt_refused 'uninstall of a symlinked payload'
}

test_bad_request_refused() {
    local path filter
    bt_install
    bt_request '.action="update" | .roles[0].secret_id="SECRET-SENTINEL-NEW"'
    bt_snapshot
    for path in /tmp/request.json /run/pve-toolbox-bao-run-zz/request.json "/run/pve-toolbox-bao-run-$BT_TX/../request.json" "/run/pve-toolbox-bao-run-$BT_TX/other.json" ''; do
        if bt_guest apply "$path"; then fail "accepted path $path"; fi
        bt_out '.result == "failed"'
        bt_unchanged "path $path"
    done
    chmod 0644 "$BT_ROOT$BT_REQ"
    bt_refused 'request mode 0644'
    chmod 0600 "$BT_ROOT$BT_REQ"
    chmod 0755 "$BT_STAGE"
    bt_refused 'stage mode 0755'
    chmod 0700 "$BT_STAGE"
    for filter in '.schema=2' '.action="reinstall"' '.machine_id="ffffffffffffffffffffffffffffffff"' \
        '.transaction_id="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
        '.roles[0].name="../x"' '.roles[0].name="roles/default"' '.roles[0].name=7' \
        '.roles+=[.roles[0]]' '.roles[0].secret_id=""' '.roles[0].role_id="two\nlines"' '.roles="default"' \
        '.addr="http://bao.example:8200"' '.addr="https://bao.example:8200\nhttps://x.example"' '.addr="https://user@bao.example"' \
        '.payload_sha256="0000000000000000000000000000000000000000000000000000000000000000"' \
        '.expected_payload_sha256="absent"' '.ca_action="replace"' '.ca_action="drop"'; do
        bt_request ".action=\"update\" | $filter"
        bt_refused "request $filter"
    done
    # A role literally named default under roles/ is ambiguous with the top-level files.
    mkdir -m 0700 "$BT_ROOT/etc/bao-run/roles" "$BT_ROOT/etc/bao-run/roles/default"
    bt_request '.action="update"'
    bt_refused 'roles/default on disk'
    bt_guest status
    bt_out '(.roles | map(.name)) == ["default"] and .unknown_files == ["/etc/bao-run/roles/default"]'
    # Nothing to log in with, on a host with no roles and no address.
    bt_fixture
    bt_request '.roles=[]'
    bt_refused 'fresh install without roles'
    bt_request '.addr=""'
    bt_refused 'fresh install without addr'
    # A role that cannot be kept or is the last one left.
    bt_install
    bt_request '.action="update" | .roles=[{name:"default",action:"remove"}]'
    bt_refused 'removing the last role'
    rm "$BT_ROOT/etc/bao-run/secret_id"
    bt_request '.action="update" | .roles=[]'
    bt_refused 'keeping an incomplete role'
}

test_remove_role_and_missing_role() {
    bt_install '.roles += [{name:"app",action:"replace",role_id:"ROLE-SENTINEL-2",secret_id:"SECRET-SENTINEL-2"}]'
    bt_request '.action="update" | .roles=[{name:"app",action:"remove"},{name:"ghost",action:"remove"}]'
    bt_apply || fail "removal failed: $(<"$BT_OUT")"
    bt_gone /etc/bao-run/roles/app
    [[ -f $BT_ROOT/etc/bao-run/secret_id ]] || fail 'kept role removed'
    # Only the role that went away changed: the survivor needs no final check.
    [[ $(grep -c '^curl' "$BT_ROOT/calls") == 2 ]] || fail 'expected only the candidate check'
}

test_remove_role_with_stray_file_refused() {
    local stray
    for stray in notes .hidden; do
        bt_install '.roles += [{name:"app",action:"replace",role_id:"ROLE-SENTINEL-2",secret_id:"SECRET-SENTINEL-2"}]'
        printf 'SENTINEL-STRAY-CONTENT\n' > "$BT_ROOT/etc/bao-run/roles/app/$stray"
        bt_new_payload v2
        bt_request '.action="update" | .roles=[{name:"app",action:"remove"}]'
        bt_refused "stray $stray"
        bt_out ".reason | contains(\"/etc/bao-run/roles/app/$stray\")" "stray $stray"
        bt_no_network "stray $stray"
    done
}

test_missing_prerequisite_reported() {
    bt_fixture
    rm "$BT_ROOT/usr/bin/curl"
    bt_guest status
    bt_out '(.tools.curl | not) and .tools.jq and .tools.bash and (.periphery.tools_ok | not)'
    bt_request
    bt_refused 'no curl'
    bt_out '.reason | test("curl")'
    # Without jq the guest still has to answer in JSON.
    bt_fixture
    bt_request
    rm "$BT_ROOT/usr/bin/jq" "$BT_ROOT/usr/bin/jq-real"
    bt_guest status
    bt_out '(.tools.jq | not) and (.supported | not) and .roles == []'
    bt_refused 'no jq'
    bt_out '(.reason | test("jq")) and .changed == false'
}

test_unsupported_platform_reported() {
    bt_fixture
    printf 'ID=debian\nVERSION_ID="12"\n' > "$BT_ROOT/etc/os-release"
    bt_guest status
    bt_out '(.supported | not) and .reason != ""'
    bt_request
    bt_refused 'Debian 12'
    bt_fixture
    printf 'not-a-machine-id\n' > "$BT_ROOT/etc/machine-id"
    bt_guest status
    bt_out '(.supported | not) and .machine_id == ""'
}

test_non_root_service_user_cannot_read() {
    bt_install
    printf 'LoadState=loaded\nActiveState=active\nUser=komodo\n' > "$BT_ROOT/unit"
    bt_guest status
    bt_out '.periphery == {mode:"systemd",active:"active",user:"komodo",can_read:false,sha256:"",tools_ok:true}'
    : > "$BT_ROOT/runuser-can-read"
    bt_guest status
    bt_out '.periphery.can_read'
    printf 'LoadState=loaded\nActiveState=inactive\nUser=\n' > "$BT_ROOT/unit"
    bt_guest status
    bt_out '.periphery.user == "root" and .periphery.can_read and .periphery.active == "inactive"'
    printf 'LoadState=not-found\nActiveState=inactive\nUser=\n' > "$BT_ROOT/unit"
    bt_guest status
    bt_out '.periphery.active == "absent"'
}

test_container_stale_payload_detected() {
    bt_install
    printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$BT_ROOT/docker-sha"
    printf 'rejected\n' > "$BT_ROOT/docker-login"
    bt_guest status --container periphery
    bt_out '.periphery.mode == "container" and .periphery.active == "active" and .periphery.tools_ok and .periphery.can_read'
    bt_out '.periphery.sha256 == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" and .periphery.sha256 != .payload.sha256'
    bt_out '.roles[0].login == "not-checked"'
    bt_guest status --login --container periphery
    bt_out '.roles[0].login == "rejected"'
    bt_no_network 'container login'
}

test_container_unreachable_does_not_fail_status() {
    bt_install
    : > "$BT_ROOT/docker-down"
    bt_guest status --login --container periphery || fail 'status failed'
    bt_out '.periphery.active == "unreachable" and (.periphery.tools_ok | not) and .periphery.sha256 == "" and .roles[0].login == "not-checked"'
    : > "$BT_ROOT/calls"
    rm "$BT_ROOT/docker-down"
    bt_guest status --container 'bad;name' || fail 'status failed'
    bt_out '.periphery.active == "unreachable"'
    if grep -q '^docker' "$BT_ROOT/calls"; then fail 'invalid container name reached docker'; fi
    rm "$BT_ROOT/usr/bin/docker"
    bt_guest status --container periphery || fail 'status failed without docker'
    bt_out '.periphery.active == "unreachable"'
}

test_status_without_login_makes_no_network_call() {
    bt_install
    bt_guest status
    bt_out '.schema == 1 and .supported and .machine_id == "'"$BT_MACHINE"'" and .reason == ""'
    bt_out '.tools == {bash:true,curl:true,jq:true} and .payload.present and .payload.owned and .addr_present and (.ca_present | not)'
    bt_out '.roles == [{name:"default",files_ok:true,login:"not-checked"}] and .unknown_files == []'
    bt_no_network 'status'
    bt_guest status --login
    bt_out '.roles[0].login == "ok"'
    grep -q '^curl' "$BT_ROOT/calls" || fail '--login made no network call'
    # A role that is not intact is never tried, and bad flags still answer in JSON.
    : > "$BT_ROOT/calls"
    chmod 0644 "$BT_ROOT/etc/bao-run/secret_id"
    bt_guest status --login
    bt_out '.roles == [{name:"default",files_ok:false,login:"not-checked"}]'
    bt_no_network 'status --login on a broken role'
    if bt_guest status --nonsense; then fail 'bad flag accepted'; fi
}

test_status_on_absent_tree() {
    bt_fixture
    bt_guest status
    bt_out '.supported and .roles == [] and (.addr_present | not) and (.payload.present | not) and .payload.sha256 == "" and .unknown_files == []'
    bt_snapshot
    bt_guest status --login
    bt_unchanged 'status'
}

test_status_lists_unknown_files() {
    bt_install '.roles += [{name:"app",action:"replace",role_id:"ROLE-SENTINEL-2",secret_id:"SECRET-SENTINEL-2"}]'
    printf 'kv\n' > "$BT_ROOT/etc/bao-run/mount"
    : > "$BT_ROOT/etc/bao-run/my notes"
    : > "$BT_ROOT/etc/bao-run/.hidden"
    : > "$BT_ROOT/etc/bao-run/roles/app/extra"
    mkdir "$BT_ROOT/etc/bao-run/roles/bad.name"
    bt_guest status
    bt_out '(.unknown_files | sort) == ["/etc/bao-run/.hidden","/etc/bao-run/my notes","/etc/bao-run/roles/app/extra","/etc/bao-run/roles/bad.name"]'
    bt_out '(.roles | map(.name)) == ["default","app"]'
}

test_status_output_is_bounded() {
    bt_install
    local i name
    name=$(printf 'x%.0s' {1..240})
    for ((i = 0; i < 400; i++)); do : > "$BT_ROOT/etc/bao-run/$name$i"; done
    bt_guest status # bt_guest enforces the size limit.
    bt_out '(.supported | not) and (.reason | test("truncated"))'
}

test_status_never_contains_secret() {
    # bt_guest fails the test on any sentinel in stdout, stderr, argv logs or /dev/null.
    local mode
    bt_install
    bt_guest status
    for mode in ok rejected sealed tls down; do
        printf '%s\n' "$mode" > "$BT_ROOT/curl-mode"
        bt_guest status --login
        bt_request '.action="update" | .roles[0].secret_id="SECRET-SENTINEL-NEW"'
        bt_guest apply "$BT_REQ" || true
        printf 'ok\n' > "$BT_ROOT/curl-mode"
        bt_install
    done
    grep -q '^curl' "$BT_ROOT/calls" || bt_guest status --login
    if grep -rlaq SENTINEL "$BT_ROOT/var/lib/pve-toolbox"; then fail 'secret in the owner store'; fi
    [[ -z $(find "$BT_STAGE" -name 'conf' -o -name 'backup') ]] || fail 'secret copies left in the stage'
}

test_concurrent_apply_refused() {
    bt_fixture
    bt_request
    local lock
    exec {lock}> "$BT_ROOT/run/pve-toolbox-bao-run.lock"
    flock -n "$lock"
    # A refused retry must not delete the backup of the run that holds the lock.
    mkdir "$BT_STAGE/backup"; : > "$BT_STAGE/backup/marker"
    if chroot "$BT_ROOT" /bin/bash /guest.sh apply "$BT_REQ" > "$BT_OUT" 2>/dev/null; then fail 'locked: accepted'; fi
    bt_out '.reason | test("another")'
    [[ -f $BT_STAGE/backup/marker ]] || fail 'refused retry deleted the running backup'
    rm -r "$BT_STAGE/backup"
    bt_refused 'locked'
    exec {lock}>&-
}

test_uninstall_removes_only_known_files() {
    bt_install '.roles += [{name:"app",action:"replace",role_id:"ROLE-SENTINEL-2",secret_id:"SECRET-SENTINEL-2"}]'
    printf 'kv\n' > "$BT_ROOT/etc/bao-run/mount"
    printf 'keep me\n' > "$BT_ROOT/etc/bao-run/notes"
    printf 'keep me\n' > "$BT_ROOT/etc/bao-run/roles/app/notes"
    bt_request '.action="uninstall"'
    if bt_apply; then fail 'partial uninstall exited 0'; fi
    bt_out '.result == "partial" and (.remaining | sort) == ["/etc/bao-run/notes","/etc/bao-run/roles/app/notes"]'
    bt_gone /usr/local/bin/bao-run /etc/bao-run/addr /etc/bao-run/mount /etc/bao-run/role_id /etc/bao-run/secret_id /etc/bao-run/roles/app/role_id /etc/bao-run/roles/app/secret_id
    [[ $(<"$BT_ROOT/etc/bao-run/notes") == 'keep me' ]] || fail 'unknown file changed'
    [[ -f $BT_ROOT/var/lib/pve-toolbox/bao-run/owner.json ]] || fail 'owner removed while files remain'
    rm "$BT_ROOT/etc/bao-run/notes" "$BT_ROOT/etc/bao-run/roles/app/notes"
    bt_apply || fail "second uninstall failed: $(<"$BT_OUT")"
    bt_out '.result == "success" and .remaining == []'
    bt_gone /etc/bao-run /var/lib/pve-toolbox/bao-run
    bt_install
    bt_request '.action="uninstall"'
    rm "$BT_ROOT/usr/bin/curl" # Removal needs no OpenBao tooling.
    : > "$BT_ROOT/calls"
    bt_apply || fail "clean uninstall failed: $(<"$BT_OUT")"
    bt_out '.result == "success"'
    bt_gone /usr/local/bin/bao-run /etc/bao-run /var/lib/pve-toolbox/bao-run
}

test_uninstall_keeps_unmatched_payload() {
    bt_install
    printf '# edited by hand\n' >> "$BT_ROOT/usr/local/bin/bao-run"
    bt_request '.action="uninstall"'
    if bt_apply; then fail 'unmatched payload uninstall exited 0'; fi
    bt_out '.result == "partial" and .remaining == ["/usr/local/bin/bao-run"]'
    grep -q 'edited by hand' "$BT_ROOT/usr/local/bin/bao-run" || fail 'unmatched payload removed'
    bt_gone /etc/bao-run
    [[ -f $BT_ROOT/var/lib/pve-toolbox/bao-run/owner.json ]] || fail 'owner removed while the payload remains'
    bt_request '.action="uninstall" | .remove_unmatched_payload=true'
    bt_apply || fail "forced uninstall failed: $(<"$BT_OUT")"
    bt_out '.result == "success"'
    bt_gone /usr/local/bin/bao-run /var/lib/pve-toolbox/bao-run
}

bt_container() { # <id> <name> <running> <mount type> <mount source>: one docker inspect entry.
    jq -nc --arg id "$1" --arg name "$2" --argjson running "$3" --arg type "$4" --arg source "$5" \
        '{Id:$id,Name:$name,State:{Running:$running},Mounts:[{Type:$type,Source:$source,Destination:"/mounted"}]}'
}
bt_containers() { jq -s . > "$BT_ROOT/docker-inspect"; } # Entries on stdin.
bt_mount_refused() { # <label> <request filter>: an installed guest refuses, whatever else the request says.
    bt_request ".action=\"uninstall\" | ${2:-.}"
    bt_refused "$1"
    bt_out '.changed == false and .remaining == []' "$1"
    bt_out '(.reason | contains("remove those mounts")) and (.reason | contains("recreate"))' "$1"
}

test_uninstall_refused_while_a_container_mounts_our_paths() {
    local source running
    for source in /usr/local/bin/bao-run /etc/bao-run /etc/bao-run/role_id /etc/bao-run/roles/app; do
        for running in true false; do
            bt_install
            bt_container aaaaaaaaaaaa /periphery "$running" bind "$source" | bt_containers
            bt_mount_refused "$source running=$running"
            bt_out '.reason | contains("periphery")'
            grep -q '^docker ps -aq' "$BT_ROOT/calls" || fail 'stopped containers were not listed'
        done
    done
    # Only the matching containers are named.
    bt_install
    { bt_container aaaaaaaaaaaa /periphery true bind /etc/bao-run
      bt_container bbbbbbbbbbbb /unrelated true bind /srv/data
      bt_container cccccccccccc /second false bind /usr/local/bin/bao-run; } | bt_containers
    bt_mount_refused 'several containers'
    bt_out '(.reason | contains("periphery, second")) and (.reason | contains("unrelated") | not)'
    # The override is for a Docker that cannot answer, never for one that says yes.
    bt_mount_refused 'ignore_mount_check on a match' '.ignore_mount_check=true'
}

test_uninstall_proceeds_without_a_matching_mount() {
    bt_install
    { bt_container aaaaaaaaaaaa /sibling-dir true bind /etc/bao-run-other
      bt_container bbbbbbbbbbbb /sibling-file false bind /usr/local/bin/bao-run.bak
      bt_container cccccccccccc /below-payload true bind /usr/local/bin/bao-run/x
      bt_container dddddddddddd /parent true bind /etc
      bt_container eeeeeeeeeeee /named-volume true volume /etc/bao-run; } | bt_containers
    bt_request '.action="uninstall"'
    bt_apply || fail "uninstall failed: $(<"$BT_OUT")"
    bt_out '.result == "success"'
    grep -q '^docker inspect' "$BT_ROOT/calls" || fail 'containers were not inspected'
    bt_gone /usr/local/bin/bao-run /etc/bao-run
    # No containers at all, and no Docker at all.
    bt_install
    bt_request '.action="uninstall"'
    bt_apply || fail "uninstall without containers failed: $(<"$BT_OUT")"
    bt_install
    rm "$BT_ROOT/usr/bin/docker"
    bt_request '.action="uninstall"'
    bt_apply || fail "uninstall without docker failed: $(<"$BT_OUT")"
    bt_gone /usr/local/bin/bao-run /etc/bao-run
}

test_uninstall_refused_when_docker_cannot_answer() {
    local flag
    local unavailable='mount check unavailable: cannot query Docker; start Docker and try again'
    for flag in docker-down docker-inspect-down docker-inspect-garbage docker-ps-raw non-executable; do
        bt_install
        bt_container aaaaaaaaaaaa /unrelated true bind /srv/data | bt_containers
        case $flag in
            docker-ps-raw) printf -- '--help\n' > "$BT_ROOT/$flag" ;;
            non-executable) chmod 0644 "$BT_ROOT/usr/bin/docker" ;;
            *) : > "$BT_ROOT/$flag" ;;
        esac
        bt_request '.action="uninstall"'
        bt_refused "$flag"
        bt_out ".reason == \"$unavailable\" and .changed == false" "$flag"
        bt_request '.action="uninstall" | .ignore_mount_check=false'
        bt_refused "$flag, explicit false"
        bt_request '.action="uninstall" | .ignore_mount_check=true'
        bt_apply || fail "$flag: ignore_mount_check failed: $(<"$BT_OUT")"
        bt_out '.result == "success"' "$flag"
        bt_gone /usr/local/bin/bao-run /etc/bao-run
    done
    bt_install
    local bad
    for bad in '"yes"' 1 null; do
        bt_request ".action=\"uninstall\" | .ignore_mount_check=$bad"
        bt_refused "ignore_mount_check=$bad"
        bt_out '.reason == "invalid ignore_mount_check"'
    done
    # Install has nothing to ask Docker.
    : > "$BT_ROOT/docker-down"
    bt_request '.action="update"'
    bt_apply || fail "update failed: $(<"$BT_OUT")"
    if grep -q '^docker' "$BT_ROOT/calls"; then fail 'install asked Docker'; fi
}

test_uninstall_refusal_cannot_carry_a_hostile_container_name() {
    local name
    for name in $'/evil\e[31m' '/evil;$(touch /pwned)' $'/evil\nforged' '/evil name' '/-evil' '//evil' ''; do
        bt_install
        { bt_container aaaaaaaaaaaa "$name" true bind /etc/bao-run
          bt_container bbbbbbbbbbbb /good_1.x-y false bind /etc/bao-run; } | bt_containers
        bt_mount_refused "name [$name]"
        bt_out '(.reason | contains("(unnamed), good_1.x-y")) and (.reason | contains("evil") | not)' "name [$name]"
        [[ ! -e $BT_ROOT/pwned ]] || fail 'a container name ran'
    done
    # A name that is not even a string.
    bt_install
    bt_container aaaaaaaaaaaa /x true bind /etc/bao-run | jq -c '.Name = 7' | bt_containers
    bt_mount_refused 'numeric name'
    bt_out '.reason | contains("(unnamed)")'
}

test_install_explains_a_directory_docker_left() {
    bt_fixture
    mkdir "$BT_ROOT/usr/local/bin/bao-run"
    mkdir -m 0755 "$BT_ROOT/etc/bao-run"
    bt_request
    bt_refused 'directory at the payload path'
    bt_out '(.reason | contains("rmdir /usr/local/bin/bao-run")) and (.reason | contains("restart the container"))'
    # Following that advice works: the empty /etc/bao-run Docker also left is taken over.
    rmdir "$BT_ROOT/usr/local/bin/bao-run"
    bt_request
    bt_apply || fail "install after rmdir failed: $(<"$BT_OUT")"
    bt_mode 755 /usr/local/bin/bao-run
    bt_mode 700 /etc/bao-run
}

test_tools_that_will_not_run_are_false() {
    bt_fixture
    chmod 0644 "$BT_ROOT/usr/bin/curl"
    bt_guest status
    bt_out '(.tools.curl | not) and .tools.jq and .tools.bash and (.periphery.tools_ok | not)'
    bt_request
    bt_refused 'curl will not run'
    bt_out '.reason | test("curl")'
    bt_fixture
    bt_request
    chmod 0644 "$BT_ROOT/usr/bin/jq"
    bt_guest status
    bt_out '(.tools.jq | not) and (.supported | not) and .roles == [] and (.periphery.tools_ok | not)'
    bt_refused 'jq will not run'
    bt_out '(.reason | test("jq")) and .changed == false'
    # In the container, the same proof.
    bt_install
    printf '%s\n' "$(printf '0%.0s' {1..64})" > "$BT_ROOT/docker-sha"
    bt_guest status --container periphery
    bt_out '.periphery.tools_ok'
    : > "$BT_ROOT/docker-tools-broken"
    bt_guest status --container periphery
    bt_out '(.periphery.tools_ok | not) and .periphery.active == "active"'
}

failed=0
for test_name in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
    if ("$test_name"); then printf 'ok  %s\n' "$test_name"
    else printf 'FAIL %s\n' "$test_name" >&2; failed=1; fi
done
exit "$failed"
