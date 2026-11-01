#!/usr/bin/env bash
# Runs inside the selected LXC. No production path-redirection overrides.
#   guest.sh status [--login] [--container <name>]
#   guest.sh apply /run/pve-toolbox-bao-run-<tx>/request.json
# All stdout is one JSON object of at most 65536 bytes, and never a secret.
# Secrets stay in the request and in files: no variable, argument or message holds one.
set -Eeuo pipefail
export LC_ALL=C
unset BAO_RUN_CONF
umask 077
shopt -s nullglob dotglob
BG_PAYLOAD=/usr/local/bin/bao-run
BG_CONF=/etc/bao-run
BG_STORE=/var/lib/pve-toolbox/bao-run
BG_OWNER=$BG_STORE/owner.json
BG_LOCK_FILE=/run/pve-toolbox-bao-run.lock
BG_ROLE_RE='^[A-Za-z0-9_-]+$'
BG_LIMIT=65536

BG_MODE="" BG_EMITTED=0 BG_SWAPPING=0 BG_CLEAN=0
BG_RESULT=failed BG_REASON='unexpected guest failure' BG_TX="" BG_STAGE="" BG_NEW_HASH=""
BG_MACHINE="" BG_PLATFORM_ERR="" BG_P_MODE=systemd
BG_ROLES=() BG_UNKNOWN=() BG_AFTER=() BG_REMAINING=() BG_ARGS=()
BG_TARGETS=() BG_SOURCES=() BG_MODES=() BG_DROP_DIRS=()
BG_UNDO_PATHS=() BG_UNDO_COPIES=() BG_NEW_DIRS=() BG_DIR_MODES=() BG_DROPPED_DIRS=()
declare -A BG_LOGIN=()

bg_fail() { BG_REASON=$1; exit 1; }
bg_safe_path() { # Absolute canonical path, root-owned and not writable by others.
    local path=$1 mode
    [[ ! $path =~ [[:cntrl:]] ]] || return 1
    [[ $path == /* && $path != *'/../'* && $path != *'/./'* && $path != *'//'* && $path != */ && $path != / ]] || return 1
    [[ $(realpath -m -- "$path") == "$path" ]] || return 1
    while [[ $path != / ]]; do
        [[ ! -L $path ]] || return 1
        if [[ -e $path ]]; then
            [[ $(stat -c %u -- "$path") == 0 ]] || return 1
            mode=$(stat -c %a -- "$path") || return 1
            (( (8#$mode & 0022) == 0 )) || return 1
        fi
        path=${path%/*}; [[ -n $path ]] || path=/
    done
}
bg_regular() { [[ -f $1 && ! -L $1 ]] && bg_safe_path "$1"; }
bg_cred_ok() { [[ -s $1 ]] && bg_regular "$1" && [[ $(stat -c '%a %u' -- "$1") == '600 0' ]]; }
bg_target_ok() { bg_safe_path "$1" && [[ ! -e $1 || -f $1 ]]; }
bg_dir_ok() { bg_safe_path "$1" && [[ ! -e $1 || -d $1 ]]; }
bg_hash() { local value; value=$(sha256sum -- "$1") || return 1; printf '%s' "${value%% *}"; }
bg_role_dir() { if [[ $2 == default ]]; then printf '%s' "$1"; else printf '%s/roles/%s' "$1" "$2"; fi; }
bg_role_args() { BG_ARGS=(--check); [[ $1 == default ]] || BG_ARGS+=(-r "$1"); }
bg_tool() { if command -v "$1" > /dev/null 2>&1; then printf true; else printf false; fi; }

bg_platform() {
    local os version arch machine
    BG_MACHINE="" BG_PLATFORM_ERR=""
    machine=$(head -n 1 /etc/machine-id 2>/dev/null) || machine=""
    if [[ $machine =~ ^[0-9a-f]{32}$ && $machine != 00000000000000000000000000000000 ]]; then BG_MACHINE=$machine
    else BG_PLATFORM_ERR='invalid guest machine-id'; fi
    # Do not source guest-supplied shell configuration to inspect its OS.
    os=$(sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d "\"'") || os=""
    version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d "\"'") || version=""
    arch=$(uname -m 2>/dev/null) || arch=""
    [[ $os == debian && $version == 13 && $arch == x86_64 ]] || BG_PLATFORM_ERR='requires Debian 13 amd64 guest'
    [[ $EUID == 0 ]] || BG_PLATFORM_ERR='guest root required'
}
bg_owned() { # <current payload hash>
    [[ -n $1 ]] && bg_regular "$BG_OWNER" \
        && jq -e --arg m "$BG_MACHINE" --arg h "$1" '.schema == 1 and .machine_id == $m and .payload_sha256 == $h' "$BG_OWNER" > /dev/null 2>&1
}
bg_scan() { # Existing roles and unknown files. Never follows a symlink.
    local entry name sub
    BG_ROLES=() BG_UNKNOWN=()
    [[ -d $BG_CONF && ! -L $BG_CONF ]] || return 0
    if [[ -e $BG_CONF/role_id || -L $BG_CONF/role_id || -e $BG_CONF/secret_id || -L $BG_CONF/secret_id ]]; then BG_ROLES+=(default); fi
    for entry in "$BG_CONF"/*; do
        case ${entry##*/} in
            addr|ca.pem|mount|role_id|secret_id) [[ -f $entry && ! -L $entry ]] || BG_UNKNOWN+=("$entry") ;;
            roles) [[ -d $entry && ! -L $entry ]] || BG_UNKNOWN+=("$entry") ;;
            *) BG_UNKNOWN+=("$entry") ;;
        esac
    done
    [[ -d $BG_CONF/roles && ! -L $BG_CONF/roles ]] || return 0
    for entry in "$BG_CONF"/roles/*; do
        name=${entry##*/}
        if [[ $name =~ $BG_ROLE_RE && $name != default && -d $entry && ! -L $entry ]]; then
            BG_ROLES+=("$name")
            for sub in "$entry"/*; do
                case ${sub##*/} in
                    role_id|secret_id) [[ -f $sub && ! -L $sub ]] || BG_UNKNOWN+=("$sub") ;;
                    *) BG_UNKNOWN+=("$sub") ;;
                esac
            done
        else
            BG_UNKNOWN+=("$entry")
        fi
    done
}
bg_word() { # Runs a check. Only the exact --check words count; the rest was not checked.
    local out
    out=$("$@" 2>/dev/null < /dev/null | head -c 32) || true
    case $out in ok|rejected|unavailable|tls|unreachable) printf '%s' "$out" ;; *) printf 'not-checked' ;; esac
}
bg_json_list() { printf '%s\0' "$@" | jq -Rsc 'split("\u0000") | map(select(length > 0))'; }
bg_emit() { # Lists shrink only on absurd trees; the transport limit is part of the contract.
    local json=$1
    while (( ${#json} >= BG_LIMIT )); do
        json=$(jq -c 'reduce ("unknown_files","remaining","roles","login") as $k (.;
                if has($k) then .[$k] |= .[:(length / 2 | floor)] else . end)
            | .reason = "output truncated" | if has("supported") then .supported = false else . end' <<<"$json")
    done
    printf '%s\n' "$json"
    BG_EMITTED=1
}

bg_status_fallback() { # <static reason> No jq to rely on: only validated and static values go in.
    local present=false
    if [[ -e $BG_PAYLOAD || -L $BG_PAYLOAD ]]; then present=true; fi
    printf '{"schema":1,"machine_id":"%s","supported":false,"reason":"%s","tools":{"bash":true,"curl":%s,"jq":%s},"payload":{"present":%s,"sha256":"","owned":false},"addr_present":false,"ca_present":false,"roles":[],"periphery":{"mode":"%s","active":"unknown","user":"","can_read":false,"sha256":"","tools_ok":false},"unknown_files":[]}\n' \
        "$BG_MACHINE" "$1" "$(bg_tool curl)" "$(bg_tool jq)" "$present" "$BG_P_MODE"
    BG_EMITTED=1
}
bg_status() {
    local want_login=0 container="" use_container=0 active=unknown user="" can_read=false p_sha="" tools_ok=false
    local supported=true reason="" conf_ok=1 present=false sha="" owned=false addr_present=false ca_present=false
    local tool_bash tool_curl tool_jq role dir files_ok login reachable=0 show word roles_json unknown_json
    local rows=()
    while (($#)); do
        case $1 in
            --login) want_login=1; shift ;;
            --container)
                (($# >= 2)) || bg_usage
                container=$2; use_container=1; BG_P_MODE=container; shift 2 ;;
            *) bg_usage ;;
        esac
    done
    bg_platform
    command -v jq > /dev/null 2>&1 || { bg_status_fallback 'jq is required'; exit 0; }
    tool_bash=$(bg_tool bash); tool_curl=$(bg_tool curl); tool_jq=$(bg_tool jq)
    [[ -z $BG_PLATFORM_ERR ]] || { supported=false; reason=$BG_PLATFORM_ERR; }

    if [[ -e $BG_PAYLOAD || -L $BG_PAYLOAD ]]; then
        present=true
        if bg_regular "$BG_PAYLOAD"; then
            sha=$(bg_hash "$BG_PAYLOAD") || sha=""
            if bg_owned "$sha"; then owned=true; fi
        fi
    fi
    if ! { bg_dir_ok "$BG_CONF" && bg_dir_ok "$BG_CONF/roles"; }; then
        conf_ok=0; supported=false; reason="unsafe $BG_CONF"
    else
        bg_scan
        if [[ -s $BG_CONF/addr && ! -L $BG_CONF/addr && -f $BG_CONF/addr ]]; then addr_present=true; fi
        if [[ -f $BG_CONF/ca.pem && ! -L $BG_CONF/ca.pem ]]; then ca_present=true; fi
    fi

    if ((use_container)); then
        if [[ $container =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && timeout 20 docker exec "$container" sh -c : > /dev/null 2>&1 < /dev/null; then
            reachable=1; active=active
            if timeout 20 docker exec "$container" sh -c 'command -v bash && command -v curl && command -v jq' > /dev/null 2>&1 < /dev/null; then tools_ok=true; fi
            if timeout 20 docker exec "$container" test -r /etc/bao-run/addr > /dev/null 2>&1 < /dev/null; then can_read=true; fi
            word=$(timeout 20 docker exec "$container" sha256sum /usr/local/bin/bao-run 2>/dev/null < /dev/null | head -c 128) || word=""
            word=${word%% *}
            if [[ $word =~ ^[0-9a-f]{64}$ ]]; then p_sha=$word; fi
        else
            active=unreachable
        fi
    else
        if show=$(timeout 10 systemctl show periphery.service --no-pager --property=LoadState,ActiveState,User 2>/dev/null); then
            active=$(sed -n 's/^ActiveState=//p' <<<"$show")
            user=$(sed -n 's/^User=//p' <<<"$show"); user=${user:-root}
            [[ $(sed -n 's/^LoadState=//p' <<<"$show") != not-found ]] || active=absent
            if ((conf_ok)); then
                if [[ $user == root ]] || timeout 20 runuser -u "$user" -- test -r "$BG_CONF/addr" > /dev/null 2>&1 < /dev/null; then can_read=true; fi
            fi
        fi
        if [[ $tool_bash == true && $tool_curl == true && $tool_jq == true ]]; then tools_ok=true; fi
    fi

    for role in "${BG_ROLES[@]}"; do
        dir=$(bg_role_dir "$BG_CONF" "$role")
        files_ok=false
        if bg_cred_ok "$dir/role_id" && bg_cred_ok "$dir/secret_id"; then files_ok=true; fi
        login=not-checked
        if ((want_login)) && [[ $files_ok == true ]]; then
            bg_role_args "$role"
            if ((use_container)); then
                if ((reachable)); then login=$(bg_word timeout 20 docker exec "$container" /usr/local/bin/bao-run "${BG_ARGS[@]}"); fi
            elif bg_regular "$BG_PAYLOAD"; then
                login=$(bg_word timeout 20 "$BG_PAYLOAD" "${BG_ARGS[@]}")
            fi
        fi
        rows+=("$role"$'\t'"$files_ok"$'\t'"$login")
    done
    roles_json=$(printf '%s\n' "${rows[@]}" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {name:.[0],files_ok:(.[1] == "true"),login:.[2]})')
    unknown_json=$(bg_json_list "${BG_UNKNOWN[@]}")
    bg_emit "$(printf '%s\n%s\n' "$roles_json" "$unknown_json" | jq -cs --arg machine "$BG_MACHINE" --argjson supported "$supported" --arg reason "$reason" \
        --argjson bash "$tool_bash" --argjson curl "$tool_curl" --argjson jq "$tool_jq" \
        --argjson present "$present" --arg sha "$sha" --argjson owned "$owned" \
        --argjson addr "$addr_present" --argjson ca "$ca_present" \
        --arg mode "$BG_P_MODE" --arg active "$active" --arg user "$user" --argjson can_read "$can_read" --arg p_sha "$p_sha" --argjson tools_ok "$tools_ok" \
        '{schema:1,machine_id:$machine,supported:$supported,reason:$reason,
          tools:{bash:$bash,curl:$curl,jq:$jq},
          payload:{present:$present,sha256:$sha,owned:$owned},
          addr_present:$addr,ca_present:$ca,roles:.[0],
          periphery:{mode:$mode,active:$active,user:$user,can_read:$can_read,sha256:$p_sha,tools_ok:$tools_ok},
          unknown_files:.[1]}')"
}

# The reason is always one of these fixed strings: a request value never reaches it.
# shellcheck disable=SC2016 # jq program, not shell.
BG_VALIDATE='
def hex($n): type == "string" and test("\\A[0-9a-f]{\($n)}\\z");
def role_name: type == "string" and test("\\A[A-Za-z0-9_-]+\\z");
def credential: type == "string" and test("\\A[!-~]+\\z");
if type != "object" then "invalid request"
elif .schema != 1 then "unsupported request schema"
elif (.action | IN("install","update","uninstall") | not) then "invalid request action"
elif .transaction_id != $tx then "transaction id does not match the request path"
elif .machine_id != $machine then "machine id does not match this guest"
elif .action == "uninstall" then
    (if (.remove_unmatched_payload | type) != "boolean" then "invalid remove_unmatched_payload" else "" end)
elif (.payload_sha256 | hex(64) | not) then "invalid payload_sha256"
elif ((.expected_payload_sha256 == "absent") or (.expected_payload_sha256 | hex(64)) | not) then "invalid expected_payload_sha256"
elif (.adopt | type) != "boolean" then "invalid adopt"
elif (.addr | type) != "string" then "invalid addr"
elif .addr != "" and (.addr | test("\\Ahttps://[A-Za-z0-9.-]+(:[0-9]+)?\\z") | not) then "invalid addr"
elif (.ca_action | IN("keep","replace","remove") | not) then "invalid ca_action"
elif .ca_action == "replace" and (((.ca_pem | type) == "string" and (.ca_pem | contains("-----BEGIN CERTIFICATE-----"))) | not) then "invalid ca_pem"
elif (.roles | type) != "array" then "invalid roles"
elif any(.roles[]; type != "object" or (.name | role_name | not) or (.action | IN("replace","remove") | not)) then "invalid role"
elif ([.roles[].name] | length) != ([.roles[].name] | unique | length) then "duplicate role"
elif any(.roles[]; .action == "replace" and ((.role_id | credential | not) or (.secret_id | credential | not))) then "invalid role credentials"
else "" end'

bg_check_paths() {
    local path entry name
    for path in "$BG_STORE" "$BG_CONF" "$BG_CONF/roles"; do
        bg_dir_ok "$path" || bg_fail "unsafe path: $path"
    done
    for path in "$BG_PAYLOAD" "$BG_OWNER" "$BG_CONF/addr" "$BG_CONF/ca.pem" "$BG_CONF/mount" "$BG_CONF/role_id" "$BG_CONF/secret_id"; do
        bg_target_ok "$path" || bg_fail "unsafe path: $path"
    done
    for entry in "$BG_CONF"/roles/*; do
        name=${entry##*/}
        [[ $name =~ $BG_ROLE_RE && $name != default ]] || continue
        bg_dir_ok "$entry" || bg_fail "unsafe path: $entry"
        for path in "$entry/role_id" "$entry/secret_id"; do
            bg_target_ok "$path" || bg_fail "unsafe path: $path"
        done
    done
}
bg_same() { [[ -f $2 ]] && cmp -s -- "$1" "$2" && [[ $(stat -c %a -- "$2") == "$3" ]]; }
bg_plan() { BG_TARGETS+=("$1"); BG_SOURCES+=("$2"); BG_MODES+=("$3"); }
bg_backup() {
    local copy=""
    if [[ -e $1 ]]; then
        copy=$BG_STAGE/backup/${#BG_UNDO_PATHS[@]}
        cp -a -- "$1" "$copy" || return 1
    fi
    BG_UNDO_PATHS+=("$1"); BG_UNDO_COPIES+=("$copy")
}
bg_swap() { # <source> <target> <mode>
    local tmp
    tmp=$(mktemp "${2%/*}/.bao-run.XXXXXXXX") || return 1
    { cat -- "$1" > "$tmp" && chmod "$3" -- "$tmp" && sync -f "$tmp" && mv -fT -- "$tmp" "$2" && sync -f "${2%/*}"; } 2>/dev/null \
        || { rm -f -- "$tmp"; return 1; }
}
bg_ensure_dir() { # <path> <mode>
    local mode
    if [[ -d $1 ]]; then
        mode=$(stat -c %a -- "$1")
        if [[ $mode != "$2" ]]; then BG_DIR_MODES+=("$mode:$1"); chmod "$2" -- "$1"; fi
    else
        mkdir -m "$2" -- "$1"; BG_NEW_DIRS+=("$1")
    fi
}
bg_restore() { # Returns non-zero when any previous file could not be put back.
    local i entry target copy tmp bad=0
    for entry in "${BG_DROPPED_DIRS[@]}"; do mkdir -m "${entry%%:*}" -- "${entry#*:}" 2>/dev/null || bad=1; done
    for ((i = ${#BG_UNDO_PATHS[@]} - 1; i >= 0; i--)); do
        target=${BG_UNDO_PATHS[i]} copy=${BG_UNDO_COPIES[i]}
        if [[ -z $copy ]]; then
            rm -f -- "$target" 2>/dev/null || bad=1
        elif ! { [[ -f $target ]] && cmp -s -- "$copy" "$target" && [[ $(stat -c %a -- "$copy") == "$(stat -c %a -- "$target")" ]]; }; then
            tmp=$(mktemp "${target%/*}/.bao-run.XXXXXXXX" 2>/dev/null) || { bad=1; continue; }
            { cp -a -- "$copy" "$tmp" && mv -fT -- "$tmp" "$target" && sync -f "${target%/*}"; } 2>/dev/null || { rm -f -- "$tmp"; bad=1; }
        fi
    done
    for ((i = ${#BG_NEW_DIRS[@]} - 1; i >= 0; i--)); do rmdir -- "${BG_NEW_DIRS[i]}" 2>/dev/null || bad=1; done
    for entry in "${BG_DIR_MODES[@]}"; do chmod "${entry%%:*}" -- "${entry#*:}" 2>/dev/null || bad=1; done
    return "$bad"
}

bg_apply_prepare() { # Everything both install and uninstall need before reading their rules.
    local request=$1 reason cmd
    [[ $request =~ ^/run/pve-toolbox-bao-run-([0-9a-f]{32})/request\.json$ ]] || bg_fail 'invalid request path'
    BG_TX=${BASH_REMATCH[1]}
    BG_STAGE=${request%/*}
    for cmd in jq stat realpath sha256sum sed head tr uname flock mktemp mkdir chmod rm rmdir find; do
        command -v "$cmd" > /dev/null 2>&1 || bg_fail "missing guest prerequisite: $cmd"
    done
    bg_platform
    [[ -z $BG_PLATFORM_ERR ]] || bg_fail "$BG_PLATFORM_ERR"
    [[ -d $BG_STAGE ]] && bg_safe_path "$BG_STAGE" && [[ $(stat -c %a -- "$BG_STAGE") == 700 ]] || bg_fail 'unsafe staging directory'
    bg_target_ok "$BG_LOCK_FILE" || bg_fail "unsafe path: $BG_LOCK_FILE"
    exec {BG_LOCK}> "$BG_LOCK_FILE"
    flock -n "$BG_LOCK" || bg_fail 'another bao-run transaction is active'
    # Only the lock holder may touch the stage: a retry must not delete a running backup.
    BG_CLEAN=1
    rm -rf -- "${BG_STAGE:?}/conf" "${BG_STAGE:?}/backup"
    bg_regular "$request" && [[ $(stat -c '%a %u' -- "$request") == '600 0' ]] || bg_fail 'unsafe request file'
    (( $(stat -c %s -- "$request") <= 262144 )) || bg_fail 'request file too large'
    # jq error text can quote request values, so it never leaves this process.
    reason=$(jq -r --arg tx "$BG_TX" --arg machine "$BG_MACHINE" "$BG_VALIDATE" "$request" 2>/dev/null) || bg_fail 'invalid request'
    [[ -z $reason ]] || bg_fail "$reason"
    mkdir -m 0700 -- "$BG_STAGE/backup"
}

bg_install() { # <request>
    local req=$1 cmd staged conf live want current=absent adopt addr ca_action rows row name action i=0 role dir word bad=0
    local shared=0 creds=0 keep target
    local -A wanted=() index=() changed=()
    local removals=() names=()
    for cmd in curl timeout env sync mv cp cat cmp; do
        command -v "$cmd" > /dev/null 2>&1 || bg_fail "missing guest prerequisite: $cmd"
    done
    bg_check_paths
    [[ ! -e $BG_CONF/roles/default && ! -L $BG_CONF/roles/default ]] || bg_fail "refusing $BG_CONF/roles/default: default means the top-level files"
    [[ -d ${BG_PAYLOAD%/*} ]] || bg_fail "missing directory: ${BG_PAYLOAD%/*}"

    staged=$BG_STAGE/bao-run
    bg_regular "$staged" || bg_fail 'staged payload is missing or unsafe'
    want=$(jq -r .payload_sha256 "$req" 2>/dev/null)
    [[ $(bg_hash "$staged") == "$want" ]] || bg_fail 'staged payload hash does not match the request'
    if [[ -e $BG_PAYLOAD ]]; then current=$(bg_hash "$BG_PAYLOAD"); fi
    [[ $current == "$(jq -r .expected_payload_sha256 "$req" 2>/dev/null)" ]] || bg_fail 'current payload does not match the expected state'
    adopt=$(jq -r .adopt "$req" 2>/dev/null)
    if [[ $current != absent && $adopt != true ]] && ! bg_owned "$current"; then
        bg_fail 'existing payload is not owned; adoption required'
    fi

    rows=$(jq -r '.roles[] | "\(.name)\t\(.action)"' "$req" 2>/dev/null)
    while IFS=$'\t' read -r name action; do
        [[ -n $name ]] || continue
        wanted[$name]=$action; index[$name]=$i; names+=("$name"); i=$((i + 1))
    done <<<"$rows"
    bg_scan
    # rmdir would fail on these and leave a role without credentials that blocks every update.
    for role in "${names[@]}"; do
        [[ ${wanted[$role]} == remove && $role != default ]] || continue
        for row in "$BG_CONF/roles/$role"/*; do
            case ${row##*/} in
                role_id|secret_id) ;;
                *) bg_fail "cannot remove role $role: unknown file $row" ;;
            esac
        done
    done
    for role in "${BG_ROLES[@]}"; do
        [[ ${wanted[$role]:-keep} == remove ]] || BG_AFTER+=("$role")
    done
    for role in "${names[@]}"; do
        [[ ${wanted[$role]} == replace ]] || continue
        keep=0
        for row in "${BG_AFTER[@]}"; do [[ $row != "$role" ]] || keep=1; done
        ((keep)) || BG_AFTER+=("$role")
    done
    ((${#BG_AFTER[@]} > 0)) || bg_fail 'no role credentials provided or present'

    # Candidate tree: everything that will be in force afterward.
    conf=$BG_STAGE/conf
    mkdir -m 0700 -- "$conf"
    addr=$(jq -r .addr "$req" 2>/dev/null)
    if [[ -n $addr ]]; then printf '%s\n' "$addr" > "$conf/addr"
    elif [[ -s $BG_CONF/addr ]]; then cat -- "$BG_CONF/addr" > "$conf/addr"
    else bg_fail 'no OpenBao address provided or present'; fi
    ca_action=$(jq -r .ca_action "$req" 2>/dev/null)
    case $ca_action in
        replace) jq -j .ca_pem "$req" > "$conf/ca.pem" 2>/dev/null ;;
        keep) if [[ -f $BG_CONF/ca.pem ]]; then cat -- "$BG_CONF/ca.pem" > "$conf/ca.pem"; fi ;;
    esac
    for role in "${BG_AFTER[@]}"; do
        dir=$(bg_role_dir "$conf" "$role")
        live=$(bg_role_dir "$BG_CONF" "$role")
        mkdir -p -- "$dir"
        if [[ ${wanted[$role]:-keep} == replace ]]; then
            jq -r --argjson i "${index[$role]}" '.roles[$i].role_id' "$req" > "$dir/role_id" 2>/dev/null
            jq -r --argjson i "${index[$role]}" '.roles[$i].secret_id' "$req" > "$dir/secret_id" 2>/dev/null
        else
            [[ -f $live/role_id && -f $live/secret_id ]] || bg_fail "existing role $role is incomplete; replace or remove it"
            cat -- "$live/role_id" > "$dir/role_id"
            cat -- "$live/secret_id" > "$dir/secret_id"
        fi
    done

    # Plan in swap order: payload, addr, CA, credentials, removals.
    bg_same "$staged" "$BG_PAYLOAD" 755 || bg_plan "$BG_PAYLOAD" "$staged" 755
    if ! bg_same "$conf/addr" "$BG_CONF/addr" 600 && [[ -n $addr ]]; then bg_plan "$BG_CONF/addr" "$conf/addr" 600; shared=1; fi
    if [[ $ca_action == replace ]] && ! bg_same "$conf/ca.pem" "$BG_CONF/ca.pem" 600; then bg_plan "$BG_CONF/ca.pem" "$conf/ca.pem" 600; shared=1; fi
    if [[ $ca_action == remove && -e $BG_CONF/ca.pem ]]; then removals+=("$BG_CONF/ca.pem"); shared=1; fi
    for role in "${BG_AFTER[@]}"; do
        [[ ${wanted[$role]:-keep} == replace ]] || continue
        dir=$(bg_role_dir "$conf" "$role")
        live=$(bg_role_dir "$BG_CONF" "$role")
        for name in role_id secret_id; do
            if ! bg_same "$dir/$name" "$live/$name" 600; then
                bg_plan "$live/$name" "$dir/$name" 600
                changed[$role]=1; creds=1
            fi
        done
    done
    for role in "${names[@]}"; do
        [[ ${wanted[$role]} == remove ]] || continue
        live=$(bg_role_dir "$BG_CONF" "$role")
        for name in role_id secret_id; do
            if [[ -e $live/$name ]]; then removals+=("$live/$name"); creds=1; fi
        done
        if [[ $role != default && -d $live ]]; then BG_DROP_DIRS+=("$live"); fi
    done
    for target in "${removals[@]}"; do bg_plan "$target" "" ""; done

    # Candidate check: no change happens unless every resulting role logs in.
    if ((shared || creds)); then
        for role in "${BG_AFTER[@]}"; do
            bg_role_args "$role"
            word=$(bg_word env "BAO_RUN_CONF=$conf" timeout 20 bash "$staged" "${BG_ARGS[@]}")
            BG_LOGIN[$role]=$word
            [[ $word == ok ]] || bad=1
        done
        ((bad == 0)) || bg_fail 'login check failed'
    fi

    # Swap. From here on, any exit restores the previous files.
    for target in "${BG_TARGETS[@]}"; do bg_backup "$target" || bg_fail 'could not back up the current files'; done
    BG_SWAPPING=1
    BG_REASON='could not replace the current files'
    bg_ensure_dir "$BG_CONF" 700
    if [[ -d $BG_CONF/roles ]] || [[ ${BG_AFTER[*]} != default ]]; then bg_ensure_dir "$BG_CONF/roles" 700; fi
    for role in "${BG_AFTER[@]}"; do
        [[ $role == default ]] || bg_ensure_dir "$BG_CONF/roles/$role" 700
    done
    for ((i = 0; i < ${#BG_TARGETS[@]}; i++)); do
        target=${BG_TARGETS[i]}
        if [[ -n ${BG_SOURCES[i]} ]]; then
            bg_swap "${BG_SOURCES[i]}" "$target" "${BG_MODES[i]}" || bg_fail "could not replace $target"
        else
            rm -f -- "$target" && sync -f "${target%/*}" || bg_fail "could not remove $target"
        fi
    done
    for dir in "${BG_DROP_DIRS[@]}"; do
        row=$(stat -c %a -- "$dir")
        if rmdir -- "$dir" 2>/dev/null; then BG_DROPPED_DIRS+=("$row:$dir"); fi
    done

    # Final check through the installed wrapper and files.
    bad=0
    for role in "${BG_AFTER[@]}"; do
        ((shared)) || [[ -n ${changed[$role]:-} ]] || continue
        bg_role_args "$role"
        word=$(bg_word timeout 20 "$BG_PAYLOAD" "${BG_ARGS[@]}")
        BG_LOGIN[$role]=$word
        [[ $word == ok ]] || bad=1
    done
    ((bad == 0)) || bg_fail 'final login check failed'

    jq -nc --arg m "$BG_MACHINE" --arg h "$want" '{schema:1,machine_id:$m,payload_sha256:$h}' > "$BG_STAGE/backup/owner.new"
    if ! bg_same "$BG_STAGE/backup/owner.new" "$BG_OWNER" 600; then
        BG_REASON='could not record ownership'
        bg_backup "$BG_OWNER" || bg_fail 'could not record ownership'
        if [[ ! -d ${BG_STORE%/*} ]]; then bg_ensure_dir "${BG_STORE%/*}" 755; fi
        bg_ensure_dir "$BG_STORE" 700
        bg_swap "$BG_STAGE/backup/owner.new" "$BG_OWNER" 600 || bg_fail 'could not record ownership'
    fi
    BG_SWAPPING=0 BG_RESULT=success BG_REASON="" BG_NEW_HASH=$want
    exit 0
}

bg_uninstall() { # <request>
    local req=$1 sha file entry name left=$BG_STAGE/backup/left remaining=() unmatched
    bg_check_paths
    unmatched=$(jq -r .remove_unmatched_payload "$req" 2>/dev/null)
    if [[ -e $BG_PAYLOAD ]]; then
        sha=$(bg_hash "$BG_PAYLOAD")
        if [[ $unmatched == true ]] || bg_owned "$sha"; then rm -f -- "$BG_PAYLOAD" 2>/dev/null || true; fi
        if [[ -e $BG_PAYLOAD ]]; then remaining+=("$BG_PAYLOAD"); fi
    fi
    for file in addr ca.pem mount role_id secret_id; do rm -f -- "${BG_CONF:?}/$file" 2>/dev/null || true; done
    for entry in "$BG_CONF"/roles/*; do
        name=${entry##*/}
        [[ $name =~ $BG_ROLE_RE && $name != default ]] || continue
        rm -f -- "$entry/role_id" "$entry/secret_id" 2>/dev/null || true
        rmdir -- "$entry" 2>/dev/null || true
    done
    # Never rm -rf: whatever is not ours stays and is reported.
    if [[ -d $BG_CONF ]]; then
        rmdir -- "$BG_CONF/roles" 2>/dev/null || true
        rmdir -- "$BG_CONF" 2>/dev/null || true
    fi
    if [[ -d $BG_CONF ]]; then
        find "$BG_CONF" -mindepth 1 \( ! -type d -o -empty \) -print0 > "$left" 2>/dev/null || true
        mapfile -d '' -t BG_REMAINING < "$left"
        ((${#BG_REMAINING[@]} > 0)) || BG_REMAINING=("$BG_CONF")
    fi
    BG_REMAINING+=("${remaining[@]}")
    if ((${#BG_REMAINING[@]} == 0)); then
        rm -f -- "$BG_OWNER" 2>/dev/null || true
        if [[ -d $BG_STORE ]]; then rmdir -- "$BG_STORE" 2>/dev/null || BG_REMAINING+=("$BG_STORE"); fi
    fi
    if ((${#BG_REMAINING[@]} == 0)); then BG_RESULT=success BG_REASON=""
    else BG_RESULT=partial BG_REASON='some files remain'; fi
    exit 0
}

bg_apply() { # <request>
    BG_MODE=apply
    (($# == 1)) || bg_fail 'invalid request path'
    bg_apply_prepare "$1"
    if [[ $(jq -r .action "$1" 2>/dev/null) == uninstall ]]; then bg_uninstall "$1"; else bg_install "$1"; fi
}

bg_result_json() {
    local role rows=() login_json remaining_json
    for role in "${BG_AFTER[@]}"; do
        [[ -z ${BG_LOGIN[$role]:-} ]] || rows+=("$role"$'\t'"${BG_LOGIN[$role]}")
    done
    login_json=$(printf '%s\n' "${rows[@]}" | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {name:.[0],login:.[1]})') || return 1
    remaining_json=$(bg_json_list "${BG_REMAINING[@]}") || return 1
    printf '%s\n%s\n' "$login_json" "$remaining_json" | jq -cs --arg result "$BG_RESULT" --arg reason "$BG_REASON" --arg tx "$BG_TX" --arg sha "$BG_NEW_HASH" \
        '{schema:1,result:$result,reason:$reason,transaction_id:$tx,payload_sha256:$sha,login:.[0],remaining:.[1]}'
}
bg_exit() { # <status of the exiting shell>
    trap '' HUP INT TERM # A signal now would abort the restore and the one JSON outcome.
    local rc=$1 json
    trap - EXIT
    case $BG_MODE in
        apply)
            if ((BG_SWAPPING)); then
                if bg_restore; then BG_REASON+='; previous files restored'
                else BG_REASON+='; restore incomplete, manual repair required'; fi
            fi
            if ((BG_CLEAN)); then rm -rf -- "${BG_STAGE:?}/conf" "${BG_STAGE:?}/backup" 2>/dev/null || true; fi
            if json=$(bg_result_json 2>/dev/null); then
                bg_emit "$json"
            else # jq is missing: reasons, the id and the result are all validated or static.
                [[ $BG_RESULT == success ]] && BG_RESULT=failed
                printf '{"schema":1,"result":"%s","reason":"%s","transaction_id":"%s","payload_sha256":"","login":[],"remaining":[]}\n' "$BG_RESULT" "$BG_REASON" "$BG_TX"
            fi
            [[ $BG_RESULT == success ]] && exit 0
            exit 1 ;;
        status)
            if ((!BG_EMITTED)); then
                bg_status_fallback 'status could not complete' 2>/dev/null
                exit 1
            fi
            exit "$rc" ;;
        *) exit "$rc" ;;
    esac
}
bg_usage() {
    printf '{"schema":1,"result":"failed","reason":"usage: guest.sh status [--login] [--container <name>] | apply <request>"}\n'
    BG_MODE=""
    exit 2
}

trap 'bg_exit "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
case ${1:-} in
    status) shift; BG_MODE=status; bg_status "$@" ;;
    apply) shift; bg_apply "$@" ;;
    *) bg_usage ;;
esac
