# shellcheck shell=bash
# Local QGA transport for one already validated, running PVE VM.

kp_qga_bridge() {
    env -u PERL5LIB -u PERL5OPT timeout 20s /usr/bin/perl \
        "$TOOLBOX_ROOT/modules/komodo-periphery/qga-bridge.pl"
}

kp_qga_target() {
    [[ $# == 2 && $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ && $2 =~ ^[1-9][0-9]{2,8}$ ]]
}

kp_qga_stage_path() { [[ $1 =~ ^/run/pve-toolbox-komodo-[a-f0-9]{32}$ ]]; }

kp_qga_exec() { # <node> <vmid> <JSON command array> <stdin-file or empty>
    local node=$1 id=$2 command=$3 input=$4 response pid status deadline out rc
    kp_qga_target "$node" "$id" || return 1
    jq -e 'type=="array" and length>0 and length<=9 and all(.[];type=="string")' \
        <<<"$command" >/dev/null 2>&1 || return 1
    if [[ -n $input ]]; then
        [[ -f $input && ! -L $input && $(stat -c %s -- "$input") -le 49152 ]] || return 1
    fi
    response=$({
        if [[ -n $input ]]; then base64 -w0 -- "$input"; else printf ''; fi
    } | jq -Rs --arg node "$node" --argjson vmid "$id" --argjson command "$command" \
        '{schema:1,node:$node,vmid:$vmid,action:"exec",command:$command,input_data_b64:.}' \
        | kp_qga_bridge) || return 1
    pid=$(jq -er '.pid | select(type=="number" and .>0 and floor==.)' <<<"$response" 2>/dev/null) || return 1
    deadline=$((SECONDS + 120))
    while ((SECONDS <= deadline)); do
        status=$(jq -nc --arg node "$node" --argjson vmid "$id" --argjson pid "$pid" \
            '{schema:1,node:$node,vmid:$vmid,action:"exec-status",pid:$pid}' | kp_qga_bridge) || return 1
        [[ ${#status} -le 65536 ]] || return 1
        if jq -e '(.exited==1 or .exited==true)' <<<"$status" >/dev/null 2>&1; then
            jq -e '(.signal == null) and ((.["out-truncated"] // 0)==0 or .["out-truncated"]==false)
                and ((.["err-truncated"] // 0)==0 or .["err-truncated"]==false)
                and (.["out-data"] // "" | type=="string")
                and (.exitcode | type=="number" and .>=0 and .<=255 and floor==.)' \
                <<<"$status" >/dev/null 2>&1 || return 1
            out=$(jq -r '.["out-data"] // ""' <<<"$status") || return 1
            rc=$(jq -r .exitcode <<<"$status") || return 1
            printf '%s' "$out"
            return "$rc"
        fi
        sleep 1
    done
    return 1
}

kp_qga_bootstrap() { # <node> <vmid> <guest-stage-directory>
    local node=$1 id=$2 dir=$3 receiver="$TOOLBOX_ROOT/modules/komodo-periphery/stage-receiver.sh"
    local command response expected actual
    kp_qga_target "$node" "$id" && kp_qga_stage_path "$dir" || return 1
    [[ -f $receiver && ! -L $receiver && $(stat -c %s -- "$receiver") -le 49152 ]] || return 1
    command=$(jq -nc --arg dir "$dir" '["/usr/bin/mkdir","-m","0700","--",$dir]')
    kp_qga_exec "$node" "$id" "$command" '' >/dev/null || return 1
    command=$(jq -nc --arg dir "$dir" '["/usr/bin/stat","-c","%u:%a","--",$dir]')
    [[ $(kp_qga_exec "$node" "$id" "$command" '') == 0:700 ]] || return 1
    response=$(base64 -w0 -- "$receiver" | jq -Rs --arg node "$node" --argjson vmid "$id" \
        --arg file "$dir/receiver.sh" \
        '{schema:1,node:$node,vmid:$vmid,action:"file-write",file:$file,content_b64:.}' \
        | kp_qga_bridge) || return 1
    [[ $(jq -r '.written // -1' <<<"$response") == "$(stat -c %s -- "$receiver")" ]] || return 1
    command=$(jq -nc --arg file "$dir/receiver.sh" '["/usr/bin/chmod","0600","--",$file]')
    kp_qga_exec "$node" "$id" "$command" '' >/dev/null || return 1
    command=$(jq -nc --arg file "$dir/receiver.sh" '["/usr/bin/sha256sum","--",$file]')
    actual=$(kp_qga_exec "$node" "$id" "$command" '') || return 1
    expected=$(sha256sum -- "$receiver"); expected=${expected%% *}
    [[ ${actual%% *} == "$expected" ]]
}

kp_qga_stage() ( # <node> <vmid> <helper|binary|request> <host-file> <guest-stage-directory> <machine-id>
    local node=$1 id=$2 kind=$3 file=$4 dir=$5 machine=$6 receiver command chunk size offset=0 length digest output block=0
    kp_qga_target "$node" "$id" && kp_qga_stage_path "$dir" && [[ $machine =~ ^[a-f0-9]{32}$ ]] || return 1
    [[ $kind == helper || $kind == binary || $kind == request ]] || return 1
    [[ -f $file && ! -L $file ]] || return 1
    size=$(stat -c %s -- "$file") || return 1
    (( size > 0 && size <= 500000000 )) || return 1
    receiver=$dir/receiver.sh
    chunk=$(mktemp) || return 1
    trap 'rm -f -- "$chunk"' EXIT
    while ((offset < size)); do
        dd if="$file" of="$chunk" bs=49152 skip="$block" count=1 status=none || return 1
        length=$(stat -c %s -- "$chunk") || return 1
        ((length > 0 && length <= 49152)) || return 1
        digest=$(sha256sum -- "$chunk"); digest=${digest%% *}
        command=$(jq -nc --arg receiver "$receiver" --arg dir "$dir" --arg kind "$kind" \
            --arg offset "$offset" --arg length "$length" --arg digest "$digest" --arg machine "$machine" \
            '["/bin/bash",$receiver,"append",$dir,$kind,$offset,$length,$digest,$machine]')
        output=$(kp_qga_exec "$node" "$id" "$command" "$chunk") || return 1
        [[ $output == ok ]] || return 1
        offset=$((offset + length)); block=$((block + 1))
    done
    digest=$(sha256sum -- "$file"); digest=${digest%% *}
    command=$(jq -nc --arg receiver "$receiver" --arg dir "$dir" --arg kind "$kind" \
        --arg size "$size" --arg digest "$digest" --arg machine "$machine" \
        '["/bin/bash",$receiver,"verify",$dir,$kind,$size,$digest,$machine]')
    output=$(kp_qga_exec "$node" "$id" "$command" '') || return 1
    [[ $output == ok ]]
)
