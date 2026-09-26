# shellcheck shell=bash
# Pinned, root-only SSH transport. The caller revalidates PVE identity before mutation.
# shellcheck disable=SC2034 # Public inspection result read by the VM orchestration file.

kp_ssh_prepare() { # <vmid> <address> <port> <key> <known-hosts>
    local id=$1 address=$2 port=$3 key=$4 hosts=$5 lookup fingerprint matches
    local -a entries=()
    kp_target_key qemu "$id" >/dev/null || return 1
    kp_ssh_address_ok "$address" || return 1 # host.sh; a missing helper fails closed
    [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || return 1
    port=$((10#$port))
    for lookup in "$key" "$hosts"; do
        kp_host_safe "$lookup" && [[ -f $lookup && -r $lookup && ! -L $lookup ]] || return 1
    done
    if [[ $port == 22 ]]; then lookup=$address; else lookup="[$address]:$port"; fi
    matches=$(ssh-keygen -F "$lookup" -f "$hosts" 2>/dev/null) || return 1
    mapfile -t entries < <(sed '/^#/d;/^$/d' <<<"$matches")
    ((${#entries[@]} == 1)) || return 1
    fingerprint=$(printf '%s\n' "${entries[0]}" | ssh-keygen -lf - 2>/dev/null) || return 1
    [[ -n $fingerprint ]] || return 1
    KP_SSH_HOST_FINGERPRINT=$(awk '{print $2}' <<<"$fingerprint")
    [[ $KP_SSH_HOST_FINGERPRINT == SHA256:* ]] || return 1
    KP_SSH_ADDRESS=$address KP_SSH_PORT=$port KP_SSH_KEY=$key KP_SSH_HOSTS=$hosts
}

kp_ssh_run() { # <remote command> [stdin file]
    local command=$1 input=${2:-}
    [[ -z $input || ( -f $input && ! -L $input ) ]] || return 1
    local -a args=(-F /dev/null -T -o BatchMode=yes -o PasswordAuthentication=no
        -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes
        -o GlobalKnownHostsFile=/dev/null -o "UserKnownHostsFile=$KP_SSH_HOSTS"
        -o "IdentityFile=$KP_SSH_KEY"
        -o IdentitiesOnly=yes -o ForwardAgent=no -o ClearAllForwardings=yes
        -o ControlMaster=no -o ConnectTimeout=8 -p "$KP_SSH_PORT"
        "root@$KP_SSH_ADDRESS" "$command")
    if [[ -n $input ]]; then timeout 130s ssh "${args[@]}" < "$input"; else timeout 130s ssh "${args[@]}" < /dev/null; fi
}

kp_ssh_verified_run() { # <PVE UUID> <remote command> [stdin file]
    local expected=${1,,} command=$2 input=${3:-} guarded
    [[ $expected =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || return 1
    # The DMI check and the requested command run in one SSH session. Every
    # chunk opens a new session, so a changed DNS answer cannot skip the proof.
    guarded='actual=$(/bin/cat /sys/class/dmi/id/product_uuid | /usr/bin/tr A-F a-f) && [ "$actual" = "'"$expected"'" ] && '"$command"
    kp_ssh_run "$guarded" "$input"
}

kp_ssh_prove() { # <expected PVE UUID>; called before every mutation phase
    local expected=${1,,} uid uuid
    [[ $expected =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || return 1
    uid=$(kp_ssh_run '/usr/bin/id -u' 2>/dev/null) || return 1
    [[ $uid == 0 ]] || return 1
    uuid=$(kp_ssh_run '/bin/cat /sys/class/dmi/id/product_uuid' 2>/dev/null) || return 1
    [[ ${uuid,,} == "$expected" ]]
}

kp_ssh_inspect() { # <vmid> <address> <port> <key> <known-hosts> <PVE UUID>
    local result
    KP_SSH_INSPECTION_JSON=
    kp_ssh_prepare "$1" "$2" "$3" "$4" "$5" && kp_ssh_prove "$6" || return 1
    result=$(kp_ssh_verified_run "$6" '/bin/bash -s -- inspect' "$(kp_guest_source)" 2>/dev/null | head -c 65537) || return 1
    [[ ${#result} -le 65536 ]] && jq -e 'type=="object" and .schema==1 and
        (.layout=="absent" or .layout=="supported" or .layout=="unsupported") and
        (.machine_id|type=="string" and test("^[a-f0-9]{32}$")) and
        (.fingerprint|type=="string") and (.version|type=="string") and
        (.reason|type=="string")' <<<"$result" >/dev/null 2>&1 || return 1
    KP_SSH_INSPECTION_JSON=$result
}

kp_ssh_stage_path() { [[ $1 =~ ^/run/pve-toolbox-komodo-[a-f0-9]{32}$ ]]; }

kp_ssh_bootstrap() { # <stage-directory> <PVE UUID>
    local dir=$1 uuid=$2 receiver="$TOOLBOX_ROOT/modules/komodo-periphery/stage-receiver.sh" expected actual
    kp_ssh_stage_path "$dir" && [[ -f $receiver && ! -L $receiver ]] || return 1
    kp_ssh_verified_run "$uuid" "/usr/bin/mkdir -m 0700 -- $dir" >/dev/null || return 1
    [[ $(kp_ssh_verified_run "$uuid" "/usr/bin/stat -c %u:%a -- $dir") == 0:700 ]] || return 1
    kp_ssh_verified_run "$uuid" "/bin/bash -c 'umask 077; /usr/bin/tee $dir/receiver.sh >/dev/null'" "$receiver" >/dev/null || return 1
    expected=$(sha256sum -- "$receiver"); expected=${expected%% *}
    actual=$(kp_ssh_verified_run "$uuid" "/usr/bin/sha256sum -- $dir/receiver.sh") || return 1
    [[ ${actual%% *} == "$expected" ]] || return 1
    kp_ssh_verified_run "$uuid" "/usr/bin/chmod 0600 -- $dir/receiver.sh" >/dev/null
}

kp_ssh_stage() ( # <helper|binary|request> <host-file> <stage-directory> <PVE UUID> <machine-id>
    local kind=$1 file=$2 dir=$3 uuid=$4 machine=$5 receiver size offset=0 length digest chunk result
    [[ $kind == helper || $kind == binary || $kind == request ]] && kp_ssh_stage_path "$dir" &&
        [[ $machine =~ ^[a-f0-9]{32}$ ]] || return 1
    [[ -f $file && ! -L $file ]] || return 1
    size=$(stat -c %s -- "$file") || return 1
    ((size > 0 && size <= 500000000)) || return 1
    receiver=$dir/receiver.sh
    chunk=$(mktemp) || return 1
    trap 'rm -f -- "$chunk"' EXIT
    while ((offset < size)); do
        dd if="$file" of="$chunk" bs=49152 skip="$((offset / 49152))" count=1 status=none || return 1
        length=$(stat -c %s -- "$chunk") || return 1
        ((length > 0 && length <= 49152)) || return 1
        digest=$(sha256sum -- "$chunk"); digest=${digest%% *}
        result=$(kp_ssh_verified_run "$uuid" "/bin/bash $receiver append $dir $kind $offset $length $digest $machine" "$chunk") || return 1
        [[ $result == ok ]] || return 1
        offset=$((offset + length))
    done
    digest=$(sha256sum -- "$file"); digest=${digest%% *}
    [[ $(kp_ssh_verified_run "$uuid" "/bin/bash $receiver verify $dir $kind $size $digest $machine") == ok ]]
)
