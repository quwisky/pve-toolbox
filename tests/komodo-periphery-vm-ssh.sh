#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
[[ -f modules/komodo-periphery/transport-ssh.sh ]] || fail 'SSH transport missing'
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/id" >/dev/null
printf 'vm.example.invalid %s\n' "$(cat "$WORK/id.pub" | cut -d ' ' -f1-2)" > "$WORK/known_hosts"
cat > "$WORK/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$KP_SSH_CALLS"
command=${*: -1}
if [[ $command == 'actual=$(/bin/cat /sys/class/dmi/id/product_uuid | /usr/bin/tr A-F a-f) && '* ]]; then
    suffix=${command#*' && '}
    guard_re='^\[ "\$actual" = "([a-f0-9-]{36})" \] && (.*)$'
    [[ $suffix =~ $guard_re ]] || exit 98
    expected=${BASH_REMATCH[1]}
    command=${BASH_REMATCH[2]}
    [[ ${KP_SSH_UUID:-11111111-2222-3333-4444-555555555555} == "$expected" ]] || exit 99
fi
case $command in
    '/usr/bin/id -u') printf '%s\n' "${KP_SSH_UID:-0}" ;;
    '/bin/cat /sys/class/dmi/id/product_uuid') printf '%s\n' "${KP_SSH_UUID:-11111111-2222-3333-4444-555555555555}" ;;
    '/bin/bash -s -- inspect')
        cat >/dev/null
        printf '%s\n' '{"schema":1,"machine_id":"0123456789abcdef0123456789abcdef","layout":"absent","version":"","reason":"","fingerprint":"absent"}' ;;
    /usr/bin/mkdir\ -m\ 0700\ --\ /run/pve-toolbox-komodo-*|/usr/bin/stat\ -c\ %u:%a\ --\ /run/pve-toolbox-komodo-*|/bin/bash\ -c\ *|/usr/bin/sha256sum\ --\ /run/pve-toolbox-komodo-*|/usr/bin/chmod\ 0600\ --\ /run/pve-toolbox-komodo-*|/bin/bash\ /run/pve-toolbox-komodo-*)
        [[ $EUID == 0 ]] || exit 99
        /bin/bash -c "$command" ;;
    *) exit 98 ;;
esac
FAKE
chmod +x "$WORK/bin/ssh"
export KP_SSH_CALLS="$WORK/calls" PATH="$WORK/bin:$PATH" TOOLBOX_ROOT=$PWD
: > "$KP_SSH_CALLS"
source modules/komodo-periphery/host.sh
# The real host-path owner check needs root. This test keeps paths inside its
# isolated tree; a root integration run exercises the actual owner check.
kp_host_safe() { [[ $1 == "$WORK/"* && ! -L $1 ]]; }
source modules/komodo-periphery/transport-ssh.sh
uuid=11111111-2222-3333-4444-555555555555
kp_ssh_inspect 201 vm.example.invalid 22 "$WORK/id" "$WORK/known_hosts" "$uuid" || fail 'pinned SSH guest rejected'
kp_ssh_prepare 201 vm.example.invalid 022 "$WORK/id" "$WORK/known_hosts" || fail 'leading-zero port rejected'
[[ $KP_SSH_PORT == 22 ]] || fail 'SSH port not normalized'
[[ $(jq -r .machine_id <<<"$KP_SSH_INSPECTION_JSON") == 0123456789abcdef0123456789abcdef ]] || fail 'guest inspection lost'
for option in BatchMode=yes StrictHostKeyChecking=yes ForwardAgent=no IdentitiesOnly=yes; do
    grep -Fq "$option" "$KP_SSH_CALLS" || fail "missing SSH option $option"
done
grep -Fq "UserKnownHostsFile=$WORK/known_hosts" "$KP_SSH_CALLS" || fail 'dedicated host-key file missing'
grep -Fq "IdentityFile=$WORK/id" "$KP_SSH_CALLS" || fail 'exact key missing'
grep -Fq 'root@vm.example.invalid' "$KP_SSH_CALLS" || fail 'wrong SSH destination'
if kp_ssh_inspect 201 vm.example.invalid 22 "$WORK/id" "$WORK/known_hosts" aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee; then fail 'wrong VM UUID accepted'; fi
export KP_SSH_UID=1000
if kp_ssh_inspect 201 vm.example.invalid 22 "$WORK/id" "$WORK/known_hosts" "$uuid"; then fail 'non-root SSH user accepted'; fi
unset KP_SSH_UID
if kp_ssh_inspect 201 vm.example.invalid 22 "$WORK/id" "$WORK/missing" "$uuid"; then fail 'unknown host key accepted'; fi
cat "$WORK/known_hosts" >> "$WORK/known_hosts.duplicate"
cat "$WORK/known_hosts" >> "$WORK/known_hosts.duplicate"
if kp_ssh_inspect 201 vm.example.invalid 22 "$WORK/id" "$WORK/known_hosts.duplicate" "$uuid"; then fail 'ambiguous pinned host keys accepted'; fi
if kp_ssh_inspect 201 'vm.example.invalid;touch /tmp/unsafe' 22 "$WORK/id" "$WORK/known_hosts" "$uuid"; then fail 'unsafe address accepted'; fi
printf '[vm.example.invalid]:2222 %s\n' "$(cut -d ' ' -f1-2 "$WORK/id.pub")" > "$WORK/known_hosts-2222"
kp_ssh_inspect 201 vm.example.invalid 2222 "$WORK/id" "$WORK/known_hosts-2222" "$uuid" || fail 'pinned nonstandard SSH port rejected'
grep -Fq -- '-p 2222' "$KP_SSH_CALLS" || fail 'selected SSH port not used'
if [[ $EUID == 0 ]]; then
    if [[ -r /sys/class/dmi/id/product_uuid ]]; then
        (
            kp_ssh_run() { /bin/bash -c "$1"; }
            actual_uuid=$(tr A-F a-f < /sys/class/dmi/id/product_uuid)
            [[ $(kp_ssh_verified_run "$actual_uuid" '/usr/bin/printf ok') == ok ]] || fail 'same-session UUID guard rejected the right VM'
            if kp_ssh_verified_run aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee '/usr/bin/printf unsafe' >/dev/null; then fail 'same-session UUID guard accepted another VM'; fi
        )
    fi
    dir=/run/pve-toolbox-komodo-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    trap 'rm -rf -- "$WORK" "$dir"' EXIT
    kp_ssh_prepare 201 vm.example.invalid 22 "$WORK/id" "$WORK/known_hosts" || fail 'SSH pairing lost'
    kp_ssh_bootstrap "$dir" "$uuid" || fail 'SSH staging bootstrap failed'
    printf '%s' 'secret;$(touch /tmp/never-run)' > "$WORK/request"
    machine=$(cat /etc/machine-id)
    export KP_SSH_UUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    if kp_ssh_stage request "$WORK/request" "$dir" "$uuid" "$machine"; then fail 'swapped SSH endpoint received request'; fi
    [[ ! -e $dir/request.json ]] || fail 'swapped endpoint received secret bytes'
    unset KP_SSH_UUID
    kp_ssh_stage request "$WORK/request" "$dir" "$uuid" "$machine" || fail 'SSH request staging failed'
    cmp -s "$WORK/request" "$dir/request.json" || fail 'SSH request changed during transfer'
    if grep -Fq 'secret;' "$KP_SSH_CALLS"; then fail 'SSH argv contained request secret'; fi
fi
printf 'ok SSH transport pins host identity and rejects wrong VM or account\n'
