#!/usr/bin/env bash
# Periphery prompts re-ask a rejected answer instead of abandoning the change.
# Runs as a normal user: PVE, the guest and GitHub are stubbed, and every flow
# ends by declining the final consent prompt, so nothing is applied. The
# chroot-backed flows in tests/komodo-periphery*.sh cover the applied changes.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok %s\n' "$*"; }
WORK=$(mktemp -d)
OUTSIDE=$(mktemp -d)
trap 'rm -rf -- "$WORK" "$OUTSIDE"' EXIT
export TOOLBOX_ROOT=$ROOT TOOLBOX_CONF_DIR="$WORK/conf" TOOLBOX_STATE_DIR="$WORK/state"
source lib/common.sh
source lib/report.sh
source modules/komodo-periphery/host.sh
source modules/komodo-periphery/vm.sh

# --- validators ---------------------------------------------------------------

accepts() { # accepts <validator> <value> [normalized]
    ASK_REASON="" ASK_NORMALIZED=""
    "$1" "$2" || fail "$1 rejected [$2]: $ASK_REASON"
    [[ $# -lt 3 || $ASK_NORMALIZED == "$3" ]] || fail "$1 [$2] stored [$ASK_NORMALIZED], not [$3]"
}
rejects() { # rejects <validator> <value> <reason>
    ASK_REASON=""
    if "$1" "$2"; then fail "$1 accepted [$2]"; fi
    [[ $ASK_REASON == "$3" ]] || fail "$1 [$2] gave reason [$ASK_REASON]"
}

url_reason='provide an HTTP or HTTPS URL without credentials, query or fragment'
for url in https://core.example.invalid http://192.0.2.10:9120/komodo https://core.example.invalid:8120/a/b; do
    accepts kp_valid_core_url "$url"
    accepts kp_valid_core_url_or_blank "$url"
done
for url in '' ftp://core.example.invalid http://user:password@core.example.invalid \
    'http://core.example.invalid/?query=1' 'http://core.example.invalid/#fragment' \
    'https://core example.invalid' 'https://core.example.invalid/a b' core.example.invalid; do
    rejects kp_valid_core_url "$url" "$url_reason"
    [[ -z $url ]] || rejects kp_valid_core_url_or_blank "$url" "$url_reason"
done
accepts kp_valid_core_url_or_blank ''
pass 'Core URL validators'

release_reason='choose an exact stable v2 release, e.g. 2.3.3'
accepts kp_valid_release 2.3.3 2.3.3
accepts kp_valid_release v2.3.3 2.3.3
accepts kp_valid_release 2.10.0 2.10.0
for release in '' v 1.19.0 v1.19.0 2.3 2.3.3-rc1 vv2.3.3 V2.3.3 latest ' 2.3.3' '2.3.3;x'; do
    rejects kp_valid_release "$release" "$release_reason"
done
pass 'release validator normalizes a v prefix'

PVE_LXC_JSON='[{"vmid":101,"name":"one","status":"running"},{"vmid":102,"status":"stopped"}]'
PVE_QEMU_JSON='[{"vmid":201,"name":"vm","status":"running"}]'
accepts kp_valid_ctid 101
accepts kp_valid_ctid 102
for id in '' 103 201 99 0101 '101 ' '101;touch x' ../101 1e2; do
    rejects kp_valid_ctid "$id" 'select one listed local container'
done
accepts kp_valid_vmid 201
for id in '' 202 101 99 0201 '201 ' '201;touch x' ../201; do
    rejects kp_valid_vmid "$id" 'select one listed local VM'
done
pass 'guest ID validators accept only listed local guests'

# The real kp_host_safe needs root-owned files. Like the flows below, the test
# treats anything under $WORK that is not a symlink as safe, and anything else
# (such as $OUTSIDE) as unsafe.
kp_host_safe() { [[ $1 == "$WORK/"* && ! -L $1 ]]; }
mkdir -p "$WORK/ssh/dir"
printf 'key\n' > "$WORK/ssh/id_ed25519"
printf 'hosts\n' > "$WORK/ssh/known_hosts"
printf 'key\n' > "$OUTSIDE/id_ed25519"
ln -s id_ed25519 "$WORK/ssh/link"
# The prompt must be as strict as the file checks in kp_ssh_prepare.
file_reason='enter an absolute path to an existing root-owned regular file that only root can change, with no symlink in the path'
for path in "$WORK/ssh/id_ed25519" "$WORK/ssh/known_hosts"; do
    accepts kp_valid_ssh_file "$path"
    kp_ssh_file_ok "$path" || fail "kp_ssh_file_ok rejected [$path]"
done
# shellcheck disable=SC2088 # a literal tilde, as typed at the prompt
for path in '' id_ed25519 ./ssh/id_ed25519 '~/.ssh/id_ed25519' "$WORK/ssh/missing" \
    "$WORK/ssh/dir" "$WORK/ssh/link" "$OUTSIDE/id_ed25519"; do
    rejects kp_valid_ssh_file "$path" "$file_reason"
    if kp_ssh_file_ok "$path"; then fail "kp_ssh_file_ok accepted [$path]"; fi
done
pass 'SSH key and known-hosts file validator'

# The prompt must be as strict as kp_ssh_prepare, which checks it again later.
address_reason='enter a host name or IPv4 address (letters, digits, dots and hyphens)'
for address in vm.example.invalid 192.0.2.20 a vm-1 VM1.Example.invalid; do
    accepts kp_valid_ssh_address "$address"
done
for address in '' host_name 'a b' -vm vm- .vm vm. 'vm;touch x' '[fd00::1]' fd00::1 "$(printf 'a%.0s' {1..254})"; do
    rejects kp_valid_ssh_address "$address" "$address_reason"
done
pass 'SSH address validator'

# The guest refuses control characters in the server name and onboarding key
# only after the Apply confirm, so the prompts refuse them first.
printable_reason='use printable characters only (no tabs or other control characters)'
for text in '' ct-101 'Server one' 'Szerver ä' '#!$%&*'; do
    accepts kp_valid_printable "$text"
    [[ -z $text ]] || accepts kp_valid_required_printable "$text"
done
for text in $'ct\t101' $'ct\x01' $'ct\x1b[31m' $'ct\x7f' $'\x1f'; do
    rejects kp_valid_printable "$text" "$printable_reason"
    rejects kp_valid_required_printable "$text" "$printable_reason"
done
rejects kp_valid_required_printable '' 'a value is required'
ASK_REASON=""
kp_valid_required_printable $'tab-secret\tx' || true
[[ $ASK_REASON != *tab-secret* ]] || fail 'printable validator reason contains the value'
pass 'printable-only validators for the server name and onboarding key'

# --- VM flow through piped answers ----------------------------------------------

kp_host_require() { KP_NODE=pve1; }
pve_qemu_inventory() { PVE_QEMU_JSON='[{"vmid":201,"name":"fixture","status":"running"}]'; }
kp_ssh_prepare() {
    printf 'prepare %s\n' "$*" >> "$WORK/calls"
    KP_SSH_PORT=$3 KP_SSH_HOST_FINGERPRINT=SHA256:fixture
}
gh_release() { printf 'release %s\n' "$2" >> "$WORK/calls"; GH_TAG=$2; }
gh_exact_asset() {
    GH_ASSET_URL=https://github.com/moghtech/komodo/releases/download/$GH_TAG/$1
    GH_ASSET_SHA256=$(printf '%064d' 0)
}
curl() {
    while (($#)); do
        if [[ $1 == -o ]]; then printf 'binary' > "$2"; fi
        shift
    done
}
verify_sha256() { :; }
inspection() { # inspection <layout> [retained] -> a guest inspection for kp_vm_inspect
    jq -nc --arg layout "$1" --argjson retained "${2:-false}" '{schema:1,layout:$layout,retained:$retained,
        owned:true,transaction:"none",transaction_id:"",machine_id:"0123456789abcdef0123456789abcdef",
        fingerprint:"absent",version:(if $layout=="supported" then "2.3.2" else "" end),binary:"/usr/local/bin/periphery",
        service_user:"root",unit:"/etc/systemd/system/periphery.service",
        config_paths:(if $layout=="supported" or $retained then ["/etc/komodo/periphery.config.toml"] else [] end)}'
}
kp_vm_inspect() { KP_TARGET_IDENTITY=identity KP_INSPECTION_JSON=$KP_FIXTURE_INSPECTION; }
vm_run() { # vm_run <action> <answers> -> VM_OUT, VM_RC
    : > "$WORK/calls"
    VM_RC=0
    VM_OUT=$(printf '%s' "$2" | kp_vm_change "$1" 2>&1) || VM_RC=$?
}
vm_expect() { [[ $VM_OUT == *"$1"* ]] || fail "$2: missing [$1] in [$VM_OUT]"; }
vm_count() { # vm_count <text> <times> <what>; each rejected answer warns once
    local n
    n=$(grep -cF -- "$1" <<<"$VM_OUT" || true)
    [[ $n == "$2" ]] || fail "$3: [$1] shown $n times, not $2 [$VM_OUT]"
}
vm_clean() {
    [[ $VM_OUT != *fixture-secret* && $VM_OUT != *new-secret* && $VM_OUT != *tab-secret* ]] \
        || fail "$1: onboarding key echoed"
    [[ ! -e $TOOLBOX_CONF_DIR/komodo-periphery-qemu-201.conf ]] || fail "$1: declined change saved a VM record"
}

# A fresh SSH install: every prompt gets one bad answer first.
KP_FIXTURE_INSPECTION=$(inspection absent)
vm_run install "$(printf '%s\n' 202 201 sshx SSH '' host_name 'a b' 192.0.2.20 70000 '' \
    id_ed25519 "$WORK/ssh/link" "$WORK/ssh/id_ed25519" known "$WORK/ssh/missing" "$OUTSIDE/id_ed25519" \
    "$WORK/ssh/dir" "$WORK/ssh/known_hosts" 2.3 v2.3.3 ftp://core.example.invalid https://core.example.invalid \
    $'vm\x01one' '' '' $'tab-secret\tx' fixture-secret n)"
[[ $VM_RC == 0 ]] || fail "VM install flow exit $VM_RC [$VM_OUT]"
vm_count 'select one listed local VM' 1 'unlisted VM ID'
vm_count 'choose one of qga/ssh' 1 'unknown transport'
vm_count "$address_reason" 3 'blank, underscored and spaced SSH addresses'
vm_count 'a value is required' 1 'blank onboarding key'
vm_count 'enter a whole number from 1 to 65535' 1 'SSH port out of range'
vm_count "$file_reason" 6 'relative, symlinked, missing, unsafe and directory key and known-hosts paths'
vm_count 'choose an exact stable v2 release, e.g. 2.3.3' 1 'inexact release'
vm_count "$url_reason" 1 'FTP Core URL'
vm_count "$printable_reason" 2 'control character in the server name and tab in the key'
grep -Fxq "prepare 201 192.0.2.20 22 $WORK/ssh/id_ed25519 $WORK/ssh/known_hosts" "$WORK/calls" \
    || fail "SSH answers not passed on: $(cat "$WORK/calls")"
grep -Fxq 'release v2.3.3' "$WORK/calls" || fail 'v-prefixed release not normalized once'
vm_expect 'Node pve1 / VM 201 (ssh): install Periphery absent -> 2.3.3' 'install preview'
vm_expect 'SSH: 192.0.2.20:22;' 'blank SSH port did not default to 22'
vm_expect 'cancelled; VM unchanged' 'declined install'
vm_clean 'VM install flow'
pass 'VM install re-asks every rejected answer'

# The saved port is the default, and a saved transport can be kept with Enter.
mkdir -p "$TOOLBOX_CONF_DIR"
conf_set komodo-periphery-qemu-201 KP_TRANSPORT ssh
conf_set komodo-periphery-qemu-201 KP_ADDRESS 192.0.2.21
conf_set komodo-periphery-qemu-201 KP_PORT 2222
conf_set komodo-periphery-qemu-201 KP_KEY_FILE "$WORK/ssh/id_ed25519"
conf_set komodo-periphery-qemu-201 KP_KNOWN_HOSTS "$WORK/ssh/known_hosts"
vm_run install $'201\n\n\n\n\n\n2.3.3\nhttps://core.example.invalid\n\nfixture-secret\nn\n'
[[ $VM_RC == 0 ]] || fail "saved SSH defaults exit $VM_RC [$VM_OUT]"
grep -Fxq "prepare 201 192.0.2.21 2222 $WORK/ssh/id_ed25519 $WORK/ssh/known_hosts" "$WORK/calls" \
    || fail "saved SSH settings not offered as defaults: $(cat "$WORK/calls")"
[[ $VM_OUT != *'!!'* ]] || fail "saved SSH defaults warned [$VM_OUT]"
[[ $(conf_get komodo-periphery-qemu-201 KP_PORT) == 2222 ]] || fail 'declined change rewrote the saved record'
rm -f "$TOOLBOX_CONF_DIR/komodo-periphery-qemu-201.conf"
pass 'VM SSH prompts default to the saved connection'

# An existing agent: the action and key-action choices re-ask a typo.
KP_FIXTURE_INSPECTION=$(inspection supported)
vm_run install $'201\nqga\nreinstall\nCONFIGURE\nftp://core.example.invalid\n\nname\x1b[31m\n\nrotate\nreplace\n\ntab-secret\tx\nnew-secret\nn\n'
[[ $VM_RC == 0 ]] || fail "VM configure flow exit $VM_RC [$VM_OUT]"
vm_count 'choose one of update/configure' 1 'unknown existing-agent action'
vm_count "$url_reason" 1 'FTP Core URL on configure'
vm_count 'choose one of keep/replace/remove' 1 'unknown key action'
vm_count 'a value is required' 1 'blank replacement key'
vm_count "$printable_reason" 2 'escape sequence in the server name and tab in the replacement key'
vm_expect 'VM 201 (qga): configure Periphery 2.3.2 -> 2.3.2' 'configure preview'
if grep -q '^release ' "$WORK/calls"; then fail 'configure fetched a release'; fi
vm_clean 'VM configure flow'
pass 'VM configure re-asks choices and a blank replacement key'

# Retained configuration from an earlier uninstall.
KP_FIXTURE_INSPECTION=$(inspection absent true)
vm_run install $'201\nqga\nkeep\nreuse\n2.3.3\nn\n'
[[ $VM_RC == 0 ]] || fail "VM retained flow exit $VM_RC [$VM_OUT]"
vm_count 'choose one of configure/reuse' 1 'unknown retained-configuration action'
vm_expect 'install Periphery absent -> 2.3.3' 'retained reinstall preview'
vm_clean 'VM retained flow'
pass 'VM retained configuration re-asks its choice'

# Input that ends mid-flow is an error, never a default.
KP_FIXTURE_INSPECTION=$(inspection absent)
vm_run install $'201\nqga\n2.3.3\nftp://core.example.invalid\n'
[[ $VM_RC != 0 ]] || fail "closed input completed the VM flow [$VM_OUT]"
vm_expect 'no answer for "Core URL (HTTP or HTTPS)" (input closed)' 'closed input'
vm_clean 'closed input'
pass 'VM flow stops when answers run out'

# --- LXC flow through a terminal ----------------------------------------------
# kp_host_change refuses to run without a terminal, so expect drives it.
if ! command -v expect >/dev/null 2>&1; then
    [[ ${TUI_TEST_REQUIRED:-0} != 1 ]] || fail 'LXC prompt test requires expect'
    printf 'skip LXC prompt test, no expect\n'; exit 0
fi
cat > "$WORK/host.sh" <<'DRIVER'
set -euo pipefail
cd -- "$TOOLBOX_ROOT"
source lib/common.sh
source lib/report.sh
source modules/komodo-periphery/host.sh
kp_host_require() { KP_NODE=pve1; }
kp_host_safe() { [[ $1 == "$KP_INPUT_WORK/"* && ! -L $1 ]]; }
pve_lxc_inventory() { PVE_LXC_JSON='[{"vmid":101,"name":"fixture","status":"running"}]'; }
kp_host_inspect() { KP_TARGET_IDENTITY=identity KP_INSPECTION_JSON=$KP_FIXTURE_INSPECTION; }
kp_vm_change() { printf 'unexpected VM flow\n'; return 1; }
gh_release() { printf 'release %s\n' "$2" >> "$KP_INPUT_WORK/calls"; GH_TAG=$2; }
gh_exact_asset() {
    GH_ASSET_URL=https://github.com/moghtech/komodo/releases/download/$GH_TAG/$1
    GH_ASSET_SHA256=$(printf '%064d' 0)
}
curl() {
    while (($#)); do
        if [[ $1 == -o ]]; then printf 'binary' > "$2"; fi
        shift
    done
}
verify_sha256() { :; }
kp_host_change install
DRIVER
# Arguments are pattern/answer pairs. An answer of <none> only waits for the
# pattern; every other answer is typed followed by Enter.
cat > "$WORK/steps.exp" <<'EXPECT'
set timeout 10
log_user 1
spawn -noecho bash [lindex $argv 0]
foreach {pattern answer} [lrange $argv 1 end] {
    expect {
        -ex $pattern {}
        timeout { puts stderr "\nFAIL timed out waiting for: $pattern"; exit 90 }
        eof { puts stderr "\nFAIL flow ended before: $pattern"; exit 91 }
    }
    if {$answer ne "<none>"} { send -- "$answer\r" }
}
expect {
    eof {}
    timeout { puts stderr "\nFAIL flow did not finish"; exit 90 }
}
exit [lindex [wait] 3]
EXPECT
host_run() { # host_run <inspection> <pattern> <answer>... -> HOST_OUT, HOST_RC
    local inspected=$1
    shift
    : > "$WORK/calls"
    HOST_RC=0
    HOST_OUT=$(KP_INPUT_WORK=$WORK KP_FIXTURE_INSPECTION=$inspected \
        expect "$WORK/steps.exp" "$WORK/host.sh" "$@" 2>&1) || HOST_RC=$?
}
host_clean() {
    [[ $HOST_RC == 0 ]] || fail "$1: exit $HOST_RC [$HOST_OUT]"
    [[ $HOST_OUT != *fixture-secret* && $HOST_OUT != *new-secret* && $HOST_OUT != *tab-secret* ]] \
        || fail "$1: onboarding key echoed"
    [[ $HOST_OUT == *'cancelled; guest unchanged'* ]] || fail "$1: not declined [$HOST_OUT]"
    [[ ! -e $TOOLBOX_CONF_DIR/komodo-periphery-101.conf ]] || fail "$1: declined change saved a record"
}

host_run "$(inspection absent)" \
    'Guest type (lxc/vm) [' container 'choose one of lxc/vm' '<none>' 'Guest type (lxc/vm) [' LXC \
    'Container ID [' 103 'select one listed local container' '<none>' 'Container ID [' 101 \
    'Exact stable Periphery v2' 2.3.3-rc1 "$release_reason" '<none>' 'Exact stable Periphery v2' v2.3.3 \
    'Core URL (HTTP or HTTPS) [' 'http://user:pw@core.example.invalid' "$url_reason" '<none>' \
    'Core URL (HTTP or HTTPS) [' https://core.example.invalid \
    'Server name in Core [' $'ct\x01one' "$printable_reason" '<none>' 'Server name in Core [' '' \
    'Core v2 onboarding key: ' '' 'a value is required' '<none>' \
    'Core v2 onboarding key: ' $'tab-secret\tx' "$printable_reason" '<none>' 'Core v2 onboarding key: ' fixture-secret \
    'CT 101: install Periphery absent -> 2.3.3' '<none>' \
    'Apply this operation to the selected container (y/n) [' n
host_clean 'LXC install flow'
grep -Fxq 'release v2.3.3' "$WORK/calls" || fail 'LXC release not normalized once'
pass 'LXC install re-asks every rejected answer'

host_run "$(inspection supported)" \
    'Guest type (lxc/vm) [' '' 'Container ID [' 101 \
    'Existing agent action (update/configure) [' reinstall 'choose one of update/configure' '<none>' \
    'Existing agent action (update/configure) [' configure \
    'Core URL (HTTP or HTTPS; blank keeps current) [' ftp://core.example.invalid "$url_reason" '<none>' \
    'Core URL (HTTP or HTTPS; blank keeps current) [' '' \
    'Server name in Core (blank keeps current) [' $'name\x1b[31m' "$printable_reason" '<none>' \
    'Server name in Core (blank keeps current) [' '' \
    'Onboarding key action (keep/replace/remove) [' rotate 'choose one of keep/replace/remove' '<none>' \
    'Onboarding key action (keep/replace/remove) [' replace \
    'Core v2 onboarding key: ' '' 'a value is required' '<none>' \
    'Core v2 onboarding key: ' $'tab-secret\tx' "$printable_reason" '<none>' 'Core v2 onboarding key: ' new-secret \
    'CT 101: configure Periphery 2.3.2 -> 2.3.2' '<none>' \
    'onboarding key: replace' '<none>' \
    'Apply this operation to the selected container (y/n) [' n
host_clean 'LXC configure flow'
if grep -q '^release ' "$WORK/calls"; then fail 'LXC configure fetched a release'; fi
pass 'LXC configure re-asks choices and a blank replacement key'

host_run "$(inspection absent true)" \
    'Guest type (lxc/vm) [' lxc 'Container ID [' 101 \
    'Retained configuration action (configure/reuse) [' keep 'choose one of configure/reuse' '<none>' \
    'Retained configuration action (configure/reuse) [' reuse \
    'Exact stable Periphery v2' 2.3.3 \
    'Reinstall with the retained configuration unchanged.' '<none>' \
    'Apply this operation to the selected container (y/n) [' n
host_clean 'LXC retained flow'
[[ $HOST_OUT != *'Core URL'* ]] || fail 'LXC reuse asked for new connection settings'
pass 'LXC retained configuration re-asks its choice'

# A downgrade is still refused outright; it is not an input typo.
host_run "$(inspection supported)" \
    'Guest type (lxc/vm) [' lxc 'Container ID [' 101 \
    'Existing agent action (update/configure) [' update \
    'Exact stable Periphery v2' 2.3.1 'downgrades are unsupported' '<none>'
[[ $HOST_RC != 0 ]] || fail "downgrade accepted [$HOST_OUT]"
if grep -q '^release ' "$WORK/calls"; then fail 'downgrade fetched a release'; fi
pass 'LXC downgrade is still refused'
