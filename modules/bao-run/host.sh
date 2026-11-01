# shellcheck shell=bash
# Host orchestration for one selected CT. Source time must remain side-effect free.
# Secrets exist on the host only in prompt variables and under BR_WORK in /run:
# never in an argument, a host record, a message or status output.
BR_ROLE_RE='^[A-Za-z0-9_-]+$'
BR_JQ_DOCS=https://quwisky.github.io/pve-toolbox/modules/bao-run/#adding-jq-to-the-official-image
BR_APPROLE_RE='^[A-Za-z0-9._-]+$'
BR_LOGIN_REJECTED_HINT="check the role and secret ID, and that this CT's IP matches the AppRole's bound address"
BR_LOGIN_UNAVAILABLE_HINT='OpenBao is reachable but not serving requests; it may be sealed'
BR_MOUNT_UNAVAILABLE='mount check unavailable: cannot query Docker; check that it is running and try again' # As guest.sh reports it.
declare -gA BR_APPROLE=() BR_ROLE_ACTION=()
BR_SAVED_ROLES=() BR_MANAGED=() BR_INSPECT_LIMIT=(timeout 120)
# shellcheck disable=SC2016 # jq program, not shell.
BR_STATUS_SHAPE='type == "object" and .schema == 1 and (.machine_id | type == "string")
    and (.supported | type == "boolean") and (.reason | type == "string")
    and (.tools | type == "object" and (keys == ["bash", "curl", "jq"]) and all(.[]; type == "boolean"))
    and (.payload | type == "object" and (.present | type == "boolean") and (.sha256 | type == "string" and test("\\A([0-9a-f]{64})?\\z")) and (.owned | type == "boolean"))
    and (.roles | type == "array" and all(.[]; (.name | type == "string" and test("\\A[A-Za-z0-9_-]+\\z"))
        and (.files_ok | type == "boolean") and (.login | type == "string")))
    and (.periphery | type == "object" and (.mode | type == "string") and (.active | type == "string")
        and (.user | type == "string") and (.can_read | type == "boolean") and (.sha256 | type == "string" and test("\\A([0-9a-f]{64})?\\z")) and (.tools_ok | type == "boolean")
        and (.missing_tools | type == "array" and all(.[]; . == "bash" or . == "curl" or . == "jq")))
    and (.unknown_files | type == "array" and all(.[]; type == "string"))'
# shellcheck disable=SC2016 # jq program, not shell.
BR_OUTCOME_SHAPE='type == "object" and .schema == 1 and .transaction_id == $tx
    and (.result == "success" or .result == "failed" or .result == "partial")
    and (.reason | type == "string")
    and (.login | type == "array" and all(.[]; (.name | type == "string") and (.login | type == "string")))
    and (.remaining | type == "array" and all(.[]; type == "string"))
    and (.changed | type == "boolean")'

# Prompt validators for ask_valid and ask_secret (lib/common.sh), which read
# ASK_REASON. A reason never repeats the value.
# shellcheck disable=SC2034
br_valid_addr() {
    [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
        || { ASK_REASON='enter an https:// URL without credentials or a path, e.g. https://openbao.lan:8200'; return 1; }
}
# shellcheck disable=SC2034
br_valid_credential() {
    valid_required "$1" && valid_printable "$1" || return 1
    local LC_ALL=C
    [[ $1 =~ ^[!-~]+$ ]] || { ASK_REASON='use printable ASCII without spaces'; return 1; }
    ((${#1} <= 512)) || { ASK_REASON='a credential is at most 512 bytes'; return 1; }
}
br_ca_file_ok() {
    pve_host_path_safe "$1" && [[ -f $1 && ! -L $1 ]] && (($(stat -c %s -- "$1") <= 65536)) \
        && grep -q -- '-----BEGIN CERTIFICATE-----' "$1" && openssl x509 -noout -in "$1" > /dev/null 2>&1
}
# shellcheck disable=SC2034
br_valid_ca() {
    [[ -z $1 || $1 == none ]] || br_ca_file_ok "$1" \
        || { ASK_REASON='enter the absolute path of a root-owned PEM certificate of at most 64 KiB, blank, or none'; return 1; }
}
# shellcheck disable=SC2034
br_valid_role_name() {
    [[ $1 =~ $BR_ROLE_RE ]] || { ASK_REASON='use letters, digits, hyphens and underscores; default means the top-level files'; return 1; }
}
# shellcheck disable=SC2034
br_valid_new_role() {
    br_valid_role_name "$1" || return 1
    [[ -z ${BR_ROLE_ACTION[$1]:-} ]] || { ASK_REASON='this role already has an action in this run'; return 1; }
}
# shellcheck disable=SC2034
br_valid_approle() {
    [[ $1 =~ $BR_APPROLE_RE ]] || { ASK_REASON='use letters, digits, dots, hyphens and underscores'; return 1; }
}
# shellcheck disable=SC2034
br_valid_container() {
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { ASK_REASON='enter a Docker container name'; return 1; }
}
# shellcheck disable=SC2034
br_valid_ctid() { # a container listed in PVE_LXC_JSON by pve_lxc_inventory
    [[ $1 =~ ^[1-9][0-9]{2,8}$ ]] && jq -e --argjson id "$1" 'any(.[]; .vmid == $id)' <<<"$PVE_LXC_JSON" > /dev/null \
        || { ASK_REASON='select one listed local container'; return 1; }
}
# shellcheck disable=SC2034
br_valid_managed() {
    [[ " ${BR_MANAGED[*]} " == *" $1 "* && $1 =~ ^[1-9][0-9]{2,8}$ ]] || { ASK_REASON='select one managed container'; return 1; }
}

br_host_require() {
    require_root
    local cmd
    for cmd in pveversion pvesh pct jq flock sha256sum openssl; do
        command -v "$cmd" > /dev/null || { warn "missing host command: $cmd"; return 1; }
    done
    [[ $(pveversion) == pve-manager/9.* ]] && ! in_lxc || { warn 'run on a PVE 9 host'; return 1; }
    BR_NODE=$(hostname -s)
    [[ $BR_NODE =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
}
br_records_safe() { # <ctid>; validated before anything sources them.
    local file
    for file in "$(conf_file "bao-run-$1")" "$TOOLBOX_STATE_DIR/bao-run-$1.state" "$(conf_file bao-run)"; do
        pve_host_path_safe "$file" && [[ ! -e $file || -f $file ]] || return 1
    done
}
br_ids() { # -> BR_MANAGED
    local id ids
    BR_MANAGED=()
    pve_host_path_safe "$(conf_file bao-run)" || { warn 'unsafe managed-container record'; return 1; }
    ids=$(conf_get bao-run BR_IDS)
    for id in $ids; do # Saved format is a whitespace-separated numeric ID list.
        [[ $id =~ ^[1-9][0-9]{2,8}$ ]] || { warn 'invalid saved container ID'; return 1; }
        br_records_safe "$id" || { warn 'unsafe managed-container record'; return 1; }
        BR_MANAGED+=("$id")
    done
}
br_load_roles() { # <ctid> -> BR_SAVED_ROLES in saved order, BR_APPROLE by role
    local word words=()
    BR_SAVED_ROLES=() BR_APPROLE=()
    read -r -a words <<<"$(conf_get "bao-run-$1" BR_ROLES)"
    for word in "${words[@]}"; do
        [[ ${word%%=*} =~ $BR_ROLE_RE && ${word#*=} =~ $BR_APPROLE_RE && $word == *=* ]] \
            || { warn 'invalid saved role record'; return 1; }
        BR_SAVED_ROLES+=("${word%%=*}")
        BR_APPROLE[${word%%=*}]=${word#*=}
    done
}
br_identity() { # <ctid> <rootfs> <machine-id>
    printf '%s\n' "$BR_NODE" "$1" "$2" "$3" | sha256sum | cut -d ' ' -f1
}
br_guest_source() { printf '%s/modules/bao-run/guest.sh' "$TOOLBOX_ROOT"; }
br_payload_source() { printf '%s/modules/bao-run/bao-run.sh' "$TOOLBOX_ROOT"; }
br_json() { jq -r "$1" <<<"$BR_STATUS_JSON"; }
br_inspect() { # <ctid> [--login] [--container <name>] -> BR_STATUS_JSON, BR_TARGET_IDENTITY, BR_INSPECT_ERROR
    local id=$1 result rootfs machine
    shift
    BR_STATUS_JSON="" BR_TARGET_IDENTITY="" BR_INSPECT_ERROR=""
    pve_lxc_ready "$BR_NODE" "$id" || { BR_INSPECT_ERROR=$PVE_LXC_ERROR; return 1; }
    # A failing status can still explain itself in JSON, so the shape decides.
    result=$("${BR_INSPECT_LIMIT[@]}" pct exec "$id" -- bash -s -- status "$@" < "$(br_guest_source)" 2>/dev/null | head -c 65537) || true
    [[ ${#result} -le 65536 ]] || { BR_INSPECT_ERROR='oversized guest status'; return 1; }
    jq -se "length == 1 and (.[0] | $BR_STATUS_SHAPE)" <<<"$result" > /dev/null 2>&1 \
        || { BR_INSPECT_ERROR='guest status unavailable or invalid'; return 1; }
    rootfs=$(jq -er '.rootfs | select(type == "string" and length > 0) | split(",")[0]' <<<"$PVE_LXC_CONFIG_JSON") \
        || { BR_INSPECT_ERROR='guest rootfs identity unavailable'; return 1; }
    machine=$(jq -r .machine_id <<<"$result")
    # An invalid machine ID comes with supported:false and gives no identity.
    if [[ $machine =~ ^[0-9a-f]{32}$ ]]; then BR_TARGET_IDENTITY=$(br_identity "$id" "$rootfs" "$machine"); fi
    BR_STATUS_JSON=$result
}
br_match() { # <ctid> <expected identity>
    br_inspect "$1" || { warn "$BR_INSPECT_ERROR"; return 1; }
    [[ -n $BR_TARGET_IDENTITY && $BR_TARGET_IDENTITY == "$2" ]] || { warn 'container identity changed; nothing further applied'; return 1; }
}
br_lock() { # <ctid>
    local path=$TOOLBOX_STATE_DIR/bao-run-$1.lock
    pve_host_path_safe "$path" && [[ ! -e $path || -f $path ]] || { warn 'unsafe lock path'; return 1; }
    mkdir -p "$TOOLBOX_STATE_DIR" || return 1
    exec {BR_LOCK}> "$path"
    flock -n "$BR_LOCK" || { warn 'another bao-run operation is active for this CT'; return 1; }
}
br_listed() { [[ " $(conf_get bao-run BR_IDS) " == *" $1 "* ]]; }
br_save_ids() { # <add|drop> <ctid>; the list is shared between CTs, so not under the per-CT lock.
    local path=$TOOLBOX_STATE_DIR/bao-run.lock
    pve_host_path_safe "$path" && [[ ! -e $path || -f $path ]] || { warn 'unsafe lock path'; return 1; }
    mkdir -p "$TOOLBOX_STATE_DIR" || return 1
    (
        local kept=() old found=0
        flock -w 30 9 || { warn 'could not lock the managed-container list'; exit 1; }
        br_ids || exit 1
        for old in "${BR_MANAGED[@]}"; do
            if [[ $old == "$2" ]]; then found=1; [[ $1 != drop ]] || continue; fi
            kept+=("$old")
        done
        if [[ $1 == add && $found == 0 ]]; then kept+=("$2"); fi
        if ((${#kept[@]})); then conf_set bao-run BR_IDS "${kept[*]}" || exit 1
        else conf_clear bao-run || exit 1; fi
    ) 9> "$path"
}
br_forget() { # <ctid>
    conf_clear "bao-run-$1" && state_clear "bao-run-$1" && br_save_ids drop "$1" \
        || { warn 'could not clear the host records'; return 1; }
}
br_stage_clean() { # Removes guest staging and settles BR_PENDING. Keeps both when it cannot.
    local id=$BR_CTID rc=0
    if ((BR_APPLYING)); then
        warn "the guest outcome is unknown, so its staging stays; it can hold credentials. Run the operation again to clean it up"
        return 1
    fi
    if ! br_match "$id" "$BR_IDENTITY" > /dev/null 2>&1; then
        warn 'guest became unavailable; protected staging path retained in pending configuration'
        return 1
    fi
    # A guest still holding its lock keeps its request, and a lock that cannot be
    # checked counts as held. A guest killed outright leaves conf and backup behind:
    # conf only holds copies, but a non-empty backup may be the only previous files.
    timeout -k 5 120 pct exec "$id" -- bash -c '
        [[ $1 =~ ^/run/pve-toolbox-bao-run-[a-f0-9]{32}$ && ! -L $1 ]] || exit 1
        [[ -e $1 ]] || exit 0
        [[ -d $1 && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == 700 ]] || exit 1
        lock=/run/pve-toolbox-bao-run.lock
        if [[ -e $lock || -L $lock ]]; then
            [[ -f $lock && ! -L $lock ]] || exit 1
            exec 9< "$lock"; flock -n 9 || exit 1
        fi
        rm -f -- "$1/guest.sh" "$1/bao-run" "$1/request.json"
        rm -rf -- "$1/conf"
        if [[ -d $1/backup && ! -L $1/backup ]]; then rmdir -- "$1/backup" 2>/dev/null || exit 3; fi
        rmdir -- "$1"
    ' _ "$BR_STAGE" < /dev/null > /dev/null 2>&1 || rc=$?
    if ((rc == 3)); then
        warn "$BR_STAGE/backup in CT $id still holds previous files, so a swap may be half done. To repair: compare its numbered copies (of the files that existed, in order: payload, addr, CA, credentials, removed files, owner record; owner.new and left are working files, not copies) with /usr/local/bin/bao-run, /etc/bao-run and /var/lib/pve-toolbox/bao-run/owner.json and put back what is wrong, then remove that backup directory and run the operation again. A reboot of the CT clears /run and this backup with it"
        return 1
    elif ((rc)); then
        warn "guest staging cleanup incomplete; inspect $BR_STAGE in CT $id and the saved pending record"
        return 1
    fi
    BR_STAGE=""
    if ((BR_FORGET)); then br_forget "$id"
    else conf_set "bao-run-$id" BR_PENDING "" || { warn 'could not clear host pending record'; return 1; }
    fi
}
br_cleanup() {
    local rc=$?
    # Another interrupt must not strand credentials here or an unsettled record.
    trap '' INT TERM HUP
    trap - EXIT
    [[ -z ${BR_WORK:-} ]] || rm -rf -- "$BR_WORK" || rc=1
    # An interrupted read -s never gets to turn terminal echo back on.
    if [[ -t 0 ]]; then stty echo 2>/dev/null || true; fi
    # Children inherit the ignored TERM, so only -k bounds them from here on.
    BR_INSPECT_LIMIT=(timeout -k 5 120)
    if [[ -n ${BR_STAGE:-} ]]; then br_stage_clean || rc=1; fi
    exit "$rc"
}
br_work() { # Protected host files; created before the first secret is read.
    BR_WORK=$(mktemp -d /run/pve-toolbox-bao-run.XXXXXXXX) || { warn 'could not create protected working files'; return 1; }
}
br_new_transaction() {
    BR_TX=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [[ $BR_TX =~ ^[a-f0-9]{32}$ ]]
}
br_login_hint() { # <login word>
    case $1 in
        rejected) printf '%s' "$BR_LOGIN_REJECTED_HINT" ;;
        unavailable) printf '%s' "$BR_LOGIN_UNAVAILABLE_HINT" ;;
    esac
}
br_show_unknown() { # Files found in the CT's /etc/bao-run. False if any is a temp from an interrupted swap.
    local path rc=0
    while IFS= read -r -d '' path; do
        if [[ ${path##*/} == .bao-run.* ]]; then
            printf '  interrupted swap left a temporary file that can hold a secret; remove it in the CT: %s\n' "$(pve_display "$path")"
            rc=1
        else
            printf '  unknown file, left in place: %s\n' "$(pve_display "$path")"
        fi
    done < <(jq -j '.unknown_files[] | ., "\u0000"' <<<"$BR_STATUS_JSON")
    return "$rc"
}
br_show_outcome() { # Reason and per-role results from BR_OUTCOME_JSON.
    local reason name word hint
    reason=$(jq -r .reason <<<"$BR_OUTCOME_JSON")
    [[ -z $reason ]] || warn "guest: $(pve_display "$reason")"
    while IFS=$'\t' read -r name word; do
        [[ -n $name ]] || continue
        info "role $(pve_display "$name"): login $(pve_display "$word")"
        hint=$(br_login_hint "$word")
        [[ -z $hint ]] || warn "$hint"
    done < <(jq -r '.login[] | [.name, .login] | @tsv' <<<"$BR_OUTCOME_JSON")
}
br_revocation() { # <approle-name>...; printed whenever a role leaves management.
    local name
    (($#)) || return 0
    info 'Credentials stay valid at OpenBao until revoked there:'
    for name; do printf '  bao delete auth/approle/role/%s\n' "$name"; done
}
br_push() { # <ctid> <source> <stage file>
    br_match "$1" "$BR_IDENTITY" || return 1
    pct push "$1" "$2" "$BR_STAGE/$3" --perms 0600 > /dev/null 2>&1 || { warn "could not push $3"; return 1; }
}
br_apply() { # <ctid> <request> <resulting roles> <push payload: 0|1> -> BR_OUTCOME_JSON
    local id=$1 request=$2 roles=$3 payload=$4 result rc=0
    BR_STAGE=/run/pve-toolbox-bao-run-$BR_TX
    # A first install is listed before staging, so an unknown outcome stays visible
    # to status, doctor and uninstall. It leaves the list only once staging is gone
    # and the guest is known to be unchanged: a failed outcome that says so, or apply never ran.
    br_listed "$id" || BR_FORGET=1
    br_save_ids add "$id" && conf_set "bao-run-$id" BR_PENDING "$BR_TX" && conf_set "bao-run-$id" BR_IDENTITY "$BR_IDENTITY" || return 1
    pct exec "$id" -- mkdir -m 0700 -- "$BR_STAGE" < /dev/null > /dev/null 2>&1 || { warn 'could not create protected guest staging'; return 1; }
    br_push "$id" "$(br_guest_source)" guest.sh || return 1
    if ((payload)); then br_push "$id" "$(br_payload_source)" bao-run || return 1; fi
    br_push "$id" "$request" request.json || return 1
    br_match "$id" "$BR_IDENTITY" || return 1
    BR_APPLYING=1
    # No -k: the guest restores its files on TERM and must be left to finish.
    # stdin is not the terminal: timeout runs pct in a background process group.
    result=$(timeout "$((120 + 60 * roles))" pct exec "$id" -- bash "$BR_STAGE/guest.sh" apply "$BR_STAGE/request.json" < /dev/null 2>/dev/null | head -c 65537; exit "${PIPESTATUS[0]}") || rc=$?
    if ! { [[ ${#result} -le 65536 ]] && jq -se --arg tx "$BR_TX" "length == 1 and (.[0] | $BR_OUTCOME_SHAPE)" <<<"$result" > /dev/null 2>&1; } \
        || { [[ $rc != 0 ]] && [[ $(jq -r .result <<<"$result") == success ]]; }; then
        warn 'guest outcome unavailable; inspect the CT before retrying'
        return 1
    fi
    BR_APPLYING=0
    BR_OUTCOME_JSON=$result
    if [[ $(jq -r 'if .result == "success" or .changed then "keep" else "" end' <<<"$result") == keep ]]; then BR_FORGET=0; fi
    br_show_outcome
}
br_missing_tools() { # <tool>...; prints the install command and fails if any is missing.
    local tool missing=()
    for tool; do
        [[ $(br_json ".tools.$tool") == true ]] || missing+=("$tool")
    done
    ((${#missing[@]} == 0)) && return 0
    warn "CT $BR_CTID lacks ${missing[*]}. Run this in the CT, then try again: apt install ${missing[*]}"
    return 1
}
br_can_manage() { # Tools first: a CT without jq also reports supported:false.
    br_missing_tools "$@" || return 1
    [[ $(br_json .supported) == true ]] || { warn "cannot manage CT $BR_CTID: $(pve_display "$(br_json .reason)")"; return 1; }
}
br_pending_handled() { # Offers cleanup of earlier staging. 0: nothing pending. 1: stop. 2: cleaned, stop.
    local pending
    pending=$(conf_get "bao-run-$BR_CTID" BR_PENDING)
    [[ -n $pending ]] || return 0
    [[ $pending =~ ^[a-f0-9]{32}$ ]] || { warn 'invalid saved transaction identifier'; return 1; }
    info "CT $BR_CTID has staging from an earlier incomplete attempt; it can hold credentials."
    confirm 'Clean up that protected staging before a new operation' n || return 1
    br_lock "$BR_CTID" && br_match "$BR_CTID" "$BR_IDENTITY" || return 1
    BR_STAGE=/run/pve-toolbox-bao-run-$pending
    if ! br_stage_clean; then BR_STAGE=""; return 1; fi
    ok 'staging removed; run the selected operation again'
    return 2
}
br_open() { # <ctid> <record required: 0|1>; inspection and every refusal shared by install and update.
    local id=$1 saved
    BR_CTID=$id
    br_inspect "$id" || { warn "$BR_INSPECT_ERROR"; return 1; }
    br_can_manage bash curl jq || return 1
    BR_IDENTITY=$BR_TARGET_IDENTITY
    saved=$(conf_get "bao-run-$id" BR_IDENTITY)
    if [[ $saved != "$BR_IDENTITY" ]] && [[ -n $saved || $2 == 1 ]]; then
        warn 'recorded CT identity differs; inspect replacement or migration, or forget it with uninstall'
        return 1
    fi
}
br_select_managed() { # <var>
    info "Managed containers: ${BR_MANAGED[*]}"
    ask_valid "$1" 'Container ID' '' br_valid_managed
}
br_short() { if [[ -n $1 ]]; then printf '%s' "${1:0:12}"; else printf absent; fi; }

br_ask_credentials() { # <role> <default AppRole name>; secrets go straight to protected files.
    local role=$1 approle=${BR_APPROLE[$1]:-} role_id="" secret_id="" n=${#BR_REQUEST_ROLES[@]}
    ask_valid approle "AppRole name for $role" "$2" br_valid_approle
    ask_secret role_id "Role ID for $role" br_valid_credential
    ask_secret secret_id "Secret ID for $role" br_valid_credential
    (
        umask 077
        printf '%s' "$role_id" > "$BR_WORK/$n.role_id" && printf '%s' "$secret_id" > "$BR_WORK/$n.secret_id"
    ) || { warn 'could not write protected working files'; return 1; }
    unset role_id secret_id
    BR_APPROLE[$role]=$approle
    BR_REQUEST_ROLES+=("$role")
}
br_default_approle() { # <hostname> <role>
    if [[ $2 == default ]]; then printf 'komodo-%s' "$1"; else printf 'komodo-%s-%s' "$1" "$2"; fi
}
br_ask_roles() { # <ct-hostname> -> BR_ROLE_ACTION, BR_ROLE_ORDER, BR_REQUEST_ROLES, BR_REMOVED
    local host=$1 role choice add name count=0 names=()
    BR_ROLE_ACTION=() BR_ROLE_ORDER=() BR_REQUEST_ROLES=() BR_REMOVED=()
    mapfile -t names < <(br_json '.roles[].name')
    for role in "${names[@]}"; do
        choice=""
        ask_choice choice "Role $role" keep keep replace remove
        BR_ROLE_ACTION[$role]=$choice
        case $choice in
            keep)
                # A guest role the host has no record of, as after a failed save or for adoption.
                if [[ -z ${BR_APPROLE[$role]:-} ]]; then
                    name=""
                    ask_valid name "AppRole name for $role" "$(br_default_approle "$host" "$role")" br_valid_approle
                    BR_APPROLE[$role]=$name
                fi
                BR_ROLE_ORDER+=("$role"); count=$((count + 1)) ;;
            replace)
                br_ask_credentials "$role" "$(br_default_approle "$host" "$role")" || return 1
                BR_ROLE_ORDER+=("$role"); count=$((count + 1)) ;;
            remove)
                [[ -z ${BR_APPROLE[$role]:-} ]] || BR_REMOVED+=("${BR_APPROLE[$role]}") ;;
        esac
    done
    while :; do
        add=""
        if ((count)); then ask_yn add 'Add a role?' n; else ask_yn add 'Add a role?' y; fi
        if [[ $add == n ]]; then
            ((count == 0)) || break
            warn 'at least one role must exist afterward'
            continue
        fi
        name=""
        ask_valid name 'Role name (default means the top-level files)' '' br_valid_new_role
        BR_ROLE_ACTION[$name]=add
        br_ask_credentials "$name" "$(br_default_approle "$host" "$name")" || return 1
        BR_ROLE_ORDER+=("$name"); count=$((count + 1))
    done
    # A recorded role the guest no longer has leaves the record too.
    for role in "${BR_SAVED_ROLES[@]}"; do
        [[ -n ${BR_ROLE_ACTION[$role]:-} ]] || BR_REMOVED+=("${BR_APPROLE[$role]}")
    done
}
br_install_request() { # <file> <expected hash> <adopt> <addr> <ca action>; secrets only through --rawfile.
    local file=$1 role n=0 action
    (
        umask 077
        jq -n --arg tx "$BR_TX" --arg machine "$(br_json .machine_id)" --arg action "$BR_ACTION" \
            --arg want "$(sha256sum < "$(br_payload_source)" | cut -d ' ' -f1)" --arg expected "$2" --argjson adopt "$3" \
            --arg addr "$4" --arg ca_action "$5" --rawfile ca "$BR_WORK/ca.pem" \
            '{schema:1,action:$action,transaction_id:$tx,machine_id:$machine,payload_sha256:$want,
              expected_payload_sha256:$expected,adopt:$adopt,addr:$addr,ca_action:$ca_action,ca_pem:$ca,
              roles:[],remove_unmatched_payload:false}' > "$file" || exit 1
        for role in "${BR_REQUEST_ROLES[@]}"; do
            jq --arg name "$role" --rawfile id "$BR_WORK/$n.role_id" --rawfile secret "$BR_WORK/$n.secret_id" \
                '.roles += [{name:$name,action:"replace",role_id:$id,secret_id:$secret}]' "$file" > "$file.new" 2>/dev/null \
                && mv -f -- "$file.new" "$file" || exit 1
            n=$((n + 1))
        done
        for role in "${!BR_ROLE_ACTION[@]}"; do
            action=${BR_ROLE_ACTION[$role]}
            [[ $action == remove ]] || continue
            jq --arg name "$role" '.roles += [{name:$name,action:"remove"}]' "$file" > "$file.new" \
                && mv -f -- "$file.new" "$file" || exit 1
        done
        chmod 0600 "$file"
    )
}
br_expected_payload() { # The current hash, or absent; refuses what the guest could not replace.
    if [[ $(br_json .payload.present) != true ]]; then printf absent; return 0; fi
    local sha
    sha=$(br_json .payload.sha256)
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || { warn 'the existing payload is not a safe regular file. If Docker left an empty directory there, run rmdir /usr/local/bin/bao-run in the CT, install, then recreate the container; otherwise inspect it in the CT' >&2; return 1; }
    printf '%s' "$sha"
}
br_jq_help() {
    info 'This adds a static jq that this module does not manage. Run these as root in the LXC:'
    cat <<'EOF'
curl -fsSL -o /tmp/jq-linux-amd64 https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64
echo 'b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f  /tmp/jq-linux-amd64' | sha256sum -c - \
  && install -m 0755 /tmp/jq-linux-amd64 /usr/local/lib/bao-run-jq
rm -f /tmp/jq-linux-amd64
EOF
    info 'Then add the mount /usr/local/lib/bao-run-jq:/usr/local/bin/jq:ro to that container and recreate it.'
    info "Details: $BR_JQ_DOCS"
}
br_preview_common() { # <ctid> <action> <expected hash> <packaged hash>
    local ips name
    name=$(jq -r --argjson id "$1" '.[] | select(.vmid == $id) | .name // "unnamed"' <<<"$PVE_LXC_JSON")
    ips=$(timeout 20 pct exec "$1" -- hostname -I < /dev/null 2>/dev/null) || ips=unavailable
    info "Node $BR_NODE / CT $1 ($(pve_display "$name")): $2 bao-run"
    info "Current IPs: $(pve_display "$ips")"
    if [[ $3 == "$4" ]]; then info "Payload: unchanged (${4:0:12})"
    else info "Payload: $(br_short "${3#absent}") -> ${4:0:12}"; fi
    if jq -e '[to_entries[] | select(.key | test("^net[0-9]+$")) | .value | strings | contains("ip=dhcp")] | any' <<<"$PVE_LXC_CONFIG_JSON" > /dev/null 2>&1; then
        warn 'this CT uses DHCP; AppRoles are bound to one IP, so a new lease stops logins'
    fi
}
br_preview_periphery() { # <systemd|container> <changes payload: 0|1>
    if [[ $1 == container ]]; then
        info 'The Periphery container needs read-only mounts of /usr/local/bin/bao-run and /etc/bao-run.'
        info 'Restart that container after every payload update: a single-file mount keeps the old file.'
    elif [[ -n $(br_json .periphery.user) && $(br_json .periphery.user) != root ]]; then
        warn "non-root Periphery ($(pve_display "$(br_json .periphery.user)")) cannot read 0700 credentials"
    fi
}

br_preview_container_jq() { # <ctid> <container>. Never blocks: the mounts may come after install.
    # The subshell keeps this inspection out of the state the flow goes on to use.
    if ( br_inspect "$1" --container "$2" > /dev/null 2>&1 && [[ $(br_json '.periphery.missing_tools | index("jq") != null') == true ]] ); then
        warn 'the Periphery container lacks jq, so its stacks will fail to deploy until it is added'
        br_jq_help
    fi
}

br_flow_install() {
    local id="" saved_mode saved_container mode="" container="" addr="" ca="" ca_action=keep expected adopt=false host want rc=0 role
    info 'Existing local containers:'
    jq -r '.[] | [.vmid, (.name // "unnamed"), .status] | @tsv' <<<"$PVE_LXC_JSON" | while IFS= read -r row; do pve_display "$row"; printf '\n'; done
    ask_valid id 'Container ID' '' br_valid_ctid
    br_records_safe "$id" || { warn 'unsafe host record path'; return 1; }
    br_open "$id" 0 || return 1
    br_pending_handled; rc=$?
    case $rc in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    br_load_roles "$id" || return 1
    expected=$(br_expected_payload) || return 1
    if [[ $(br_json .payload.present) == true && $(br_json .payload.owned) != true ]]; then
        info "CT $id already has an unmanaged /usr/local/bin/bao-run (${expected:0:12})."
        confirm 'Adopt this existing payload for management' n || return 1
        adopt=true
    fi
    saved_mode=$(conf_get "bao-run-$id" BR_PERIPHERY)
    saved_container=$(conf_get "bao-run-$id" BR_CONTAINER)
    ask_choice mode 'Periphery runs as' "${saved_mode:-systemd}" systemd container
    if [[ $mode == container ]]; then ask_valid container 'Periphery container name' "$saved_container" br_valid_container; fi
    ask_valid addr 'OpenBao URL' "$(conf_get "bao-run-$id" BR_ADDR)" br_valid_addr
    ask_valid ca 'CA file on this host (blank keeps, none removes)' '' br_valid_ca
    br_work || return 1
    ( umask 077; : > "$BR_WORK/ca.pem" ) || return 1
    case $ca in
        '') ;;
        none) ca_action=remove ;;
        *)
            ca_action=replace
            ( umask 077; cat -- "$ca" > "$BR_WORK/ca.pem" ) && br_ca_file_ok "$BR_WORK/ca.pem" \
                || { warn 'could not read that CA file'; return 1; } ;;
    esac
    host=$(jq -r '.hostname // ""' <<<"$PVE_LXC_CONFIG_JSON")
    [[ $host =~ ^[A-Za-z0-9.-]+$ ]] || host=ct-$id
    br_ask_roles "$host" || return 1
    want=$(sha256sum < "$(br_payload_source)" | cut -d ' ' -f1)
    br_preview_common "$id" install "$expected" "$want"
    info "OpenBao: $addr; CA: $ca_action; Periphery: $mode${container:+ ($container)}"
    for role in "${BR_ROLE_ORDER[@]}"; do info "Role $role (${BR_APPROLE[$role]}): ${BR_ROLE_ACTION[$role]}"; done
    for role in "${!BR_ROLE_ACTION[@]}"; do [[ ${BR_ROLE_ACTION[$role]} != remove ]] || info "Role $role: remove"; done
    br_show_unknown || true
    br_preview_periphery "$mode"
    if [[ $mode == container ]]; then br_preview_container_jq "$id" "$container"; fi
    confirm 'Apply this operation to the selected container' n || { info 'cancelled; guest unchanged'; return 0; }
    br_lock "$id" && br_match "$id" "$BR_IDENTITY" || return 1
    br_new_transaction || return 1
    BR_ACTION=install
    br_install_request "$BR_WORK/request.json" "$expected" "$adopt" "$addr" "$ca_action" || { warn 'could not build the request'; return 1; }
    br_apply "$id" "$BR_WORK/request.json" "${#BR_ROLE_ORDER[@]}" 1 || return 1
    if [[ $(jq -r .result <<<"$BR_OUTCOME_JSON") != success ]]; then
        if [[ " ${BR_ROLE_ACTION[*]} " == *' remove '* ]]; then
            warn 'removing a role fails if its directory holds other files, and needs the remaining roles to log in, so it cannot complete while OpenBao is down'
        fi
        return 1
    fi
    local words=()
    for role in "${BR_ROLE_ORDER[@]}"; do words+=("$role=${BR_APPROLE[$role]}"); done
    if ! { conf_set "bao-run-$id" BR_ADDR "$addr" && conf_set "bao-run-$id" BR_ROLES "${words[*]}" &&
        conf_set "bao-run-$id" BR_PERIPHERY "$mode" && conf_set "bao-run-$id" BR_CONTAINER "$container" &&
        state_set "bao-run-$id" payload_sha256 "$want" && state_set "bao-run-$id" result "install completed" &&
        br_save_ids add "$id"; }; then
        warn 'guest operation succeeded but host records failed; run install again to reconcile'
        return 1
    fi
    br_revocation "${BR_REMOVED[@]}"
    ok "CT $id: bao-run installed"
    if [[ $mode == container && $expected != "$want" ]]; then warn 'restart the Periphery container to load the new payload'; fi
}
br_flow_update() {
    local id="" expected want recorded adopt=false rc=0 role_count mode
    br_ids || return 1
    ((${#BR_MANAGED[@]})) || { info 'no managed containers'; return 0; }
    br_select_managed id
    br_open "$id" 1 || return 1
    br_pending_handled; rc=$?
    case $rc in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    expected=$(br_expected_payload) || return 1
    want=$(sha256sum < "$(br_payload_source)" | cut -d ' ' -f1)
    recorded=$(state_get "bao-run-$id" payload_sha256)
    if [[ $expected == "$want" ]]; then
        # An unknown outcome may have really succeeded, or a host save failed afterward.
        if [[ $recorded != "$want" ]]; then
            br_lock "$id" && state_set "bao-run-$id" payload_sha256 "$want" || { warn 'could not refresh the host record'; return 1; }
        fi
        ok "CT $id: up to date"
        return 0
    fi
    if [[ $expected != "$recorded" || $(br_json .payload.owned) != true ]]; then
        info "CT $id: payload ${expected:0:12} matches neither the recorded $(br_short "$recorded") nor the packaged ${want:0:12}."
        confirm 'Adopt this edited payload and replace it' n || return 1
        adopt=true
    fi
    mode=$(conf_get "bao-run-$id" BR_PERIPHERY)
    br_preview_common "$id" update "$expected" "$want"
    info 'Credentials, address and CA stay as they are.'
    br_preview_periphery "$mode"
    confirm 'Apply this operation to the selected container' n || { info 'cancelled; guest unchanged'; return 0; }
    br_lock "$id" && br_match "$id" "$BR_IDENTITY" || return 1
    br_new_transaction && br_work || return 1
    ( umask 077; : > "$BR_WORK/ca.pem" ) || return 1
    BR_ACTION=update BR_ROLE_ACTION=() BR_REQUEST_ROLES=()
    br_install_request "$BR_WORK/request.json" "$expected" "$adopt" "" keep || { warn 'could not build the request'; return 1; }
    role_count=$(br_json '.roles | length')
    br_apply "$id" "$BR_WORK/request.json" "$role_count" 1 || return 1
    [[ $(jq -r .result <<<"$BR_OUTCOME_JSON") == success ]] || return 1
    if ! { state_set "bao-run-$id" payload_sha256 "$want" && state_set "bao-run-$id" result "update completed"; }; then
        warn 'guest operation succeeded but host records failed; run update again to reconcile'
        return 1
    fi
    ok "CT $id: payload updated"
    if [[ $mode == container ]]; then warn 'restart the Periphery container to load the new payload'; fi
}
br_revoke_saved() { # What a CT leaving management owes OpenBao.
    local role names=()
    for role in "${BR_SAVED_ROLES[@]}"; do names+=("${BR_APPROLE[$role]}"); done
    br_revocation "${names[@]}"
    info 'CT backups and snapshots may still contain these credentials.'
}
br_forget_revoke() { # The guest was never inspected, so what happened to it is the operator's call.
    br_revoke_saved
    warn 'Run those only if the container was really destroyed; on a migrated container these break working logins.'
}
br_uninstall_apply() { # <remove unmatched> <ignore mount check>
    br_new_transaction || return 1
    ( umask 077; jq -n --arg tx "$BR_TX" --arg machine "$(br_json .machine_id)" --argjson unmatched "$1" --argjson ignore "$2" \
        '{schema:1,action:"uninstall",transaction_id:$tx,machine_id:$machine,remove_unmatched_payload:$unmatched,ignore_mount_check:$ignore}' > "$BR_WORK/request.json" ) \
        || { warn 'could not build the request'; return 1; }
    # Revocation breaks credentials still in use, so its commands wait for a guest that removed them.
    if ! br_apply "$BR_CTID" "$BR_WORK/request.json" 0 0; then
        if ((BR_APPLYING)); then info 'Outcome unknown: revoke these AppRoles at OpenBao only after confirming the credentials are gone or no longer wanted.'; fi
        return 1
    fi
}
br_flow_uninstall() {
    local id="" saved rc=0 remove_unmatched=false result path
    br_ids || return 1
    ((${#BR_MANAGED[@]})) || { info 'no managed containers'; return 0; }
    br_select_managed id
    BR_CTID=$id
    br_load_roles "$id" || return 1
    if ! jq -e --argjson id "$id" 'any(.[]; .vmid == $id)' <<<"$PVE_LXC_JSON" > /dev/null; then
        info "CT $id is not on this node: destroyed, or moved to another node. Forgetting leaves anything inside it as it is."
        confirm 'Forget this container and clear its host records' n || return 1
        br_forget "$id" || return 1
        br_forget_revoke
        return 0
    fi
    br_inspect "$id" || { warn "$BR_INSPECT_ERROR; records kept"; return 1; }
    saved=$(conf_get "bao-run-$id" BR_IDENTITY)
    if [[ -z $BR_TARGET_IDENTITY || $BR_TARGET_IDENTITY != "$saved" ]]; then
        warn "CT $id does not match its recorded identity: replaced or recreated, so nothing will be changed inside it."
        confirm 'Forget this container and clear its host records' n || return 1
        br_forget "$id" || return 1
        br_forget_revoke
        return 0
    fi
    br_can_manage jq || return 1
    BR_IDENTITY=$BR_TARGET_IDENTITY
    br_pending_handled; rc=$?
    case $rc in 0) ;; 2) return 0 ;; *) return 1 ;; esac
    if [[ $(br_json .payload.present) == true && $(br_json .payload.owned) != true ]]; then
        info "/usr/local/bin/bao-run in CT $id does not match what this module installed."
        if confirm 'Remove the unmatched payload too' n; then remove_unmatched=true; fi
    fi
    info "Node $BR_NODE / CT $id: remove /usr/local/bin/bao-run, /etc/bao-run and /var/lib/pve-toolbox/bao-run"
    warn 'Stacks using the wrapper will fail on their next deploy; running containers are untouched.'
    confirm 'Apply this operation to the selected container' n || { info 'cancelled; guest unchanged'; return 0; }
    br_lock "$id" && br_match "$id" "$BR_IDENTITY" || return 1
    br_work || return 1
    br_uninstall_apply "$remove_unmatched" false || return 1
    # The guest stays the judge: asked again with the override, it still refuses a mount it can see.
    if [[ $(jq -r 'if .result == "failed" then .reason else "" end' <<<"$BR_OUTCOME_JSON") == "$BR_MOUNT_UNAVAILABLE" ]]; then
        warn 'Docker could not say whether a container still bind-mounts these paths. A container still using those mounts will not start again after this removal.'
        confirm 'Remove bao-run without the mount check' n || { info 'cancelled; guest unchanged'; return 1; }
        if ! br_stage_clean; then BR_STAGE=""; return 1; fi
        br_uninstall_apply "$remove_unmatched" true || return 1
    fi
    result=$(jq -r .result <<<"$BR_OUTCOME_JSON")
    case $result in
        success)
            br_revoke_saved
            BR_FORGET=1
            ok "CT $id: bao-run removed" ;;
        partial)
            br_revoke_saved
            warn "CT $id: some files remain; host records kept:"
            while IFS= read -r path; do printf '  %s\n' "$(pve_display "$path")"; done < <(jq -r '.remaining[]' <<<"$BR_OUTCOME_JSON")
            return 1 ;;
        *) return 1 ;;
    esac
}
br_change() ( # Subshell owns locks, protected temporary files and traps.
    set +x # Secrets pass through the prompt variables below.
    local action=$1
    [[ ${ASSUME_YES:-0} == 0 && ${FORCE:-0} == 0 && -t 0 && -t 1 ]] || { warn 'bao-run changes require a terminal and explicit confirmation; --yes/--force are unsupported'; return 1; }
    br_host_require || return 1
    pve_lxc_inventory "$BR_NODE" || { warn "$PVE_LXC_ERROR"; return 1; }
    BR_STAGE="" BR_WORK="" BR_CTID="" BR_IDENTITY="" BR_APPLYING=0 BR_FORGET=0
    trap br_cleanup EXIT
    trap 'warn "interrupted"; exit 130' INT TERM HUP
    case $action in
        install) br_flow_install ;;
        update) br_flow_update ;;
        uninstall) br_flow_uninstall ;;
        *) warn 'unsupported action'; return 1 ;;
    esac
)

br_status_one() { # <ctid> [brief]; prints one block. False when anything needs attention.
    local id=$1 brief=${2:-} missing expected mode container failed=0 want tools payload line role files login approle hint args=(--login)
    local -A seen=()
    expected=$(conf_get "bao-run-$id" BR_IDENTITY)
    mode=$(conf_get "bao-run-$id" BR_PERIPHERY)
    container=$(conf_get "bao-run-$id" BR_CONTAINER)
    if [[ $mode == container ]]; then
        [[ $container =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { printf 'CT %s: invalid saved container name\n' "$id"; return 1; }
        args+=(--container "$container")
    fi
    br_load_roles "$id" > /dev/null || { printf 'CT %s: invalid saved role record\n' "$id"; return 1; }
    if ! br_inspect "$id" "${args[@]}"; then printf 'CT %s: unreachable: %s\n' "$id" "$BR_INSPECT_ERROR"; return 1; fi
    if [[ -z $BR_TARGET_IDENTITY || $BR_TARGET_IDENTITY != "$expected" ]]; then printf 'CT %s: identity mismatch\n' "$id"; return 1; fi
    want=$(sha256sum < "$(br_payload_source)" | cut -d ' ' -f1)
    if [[ $(br_json .payload.sha256) == "$want" ]]; then payload='payload current'; else payload='payload differs from packaged'; failed=1; fi
    if [[ $(br_json '.tools.curl and .tools.jq and .tools.bash') == true ]]; then tools='curl jq ok'
    else
        tools=$(pve_display "$(br_json '[.tools | to_entries[] | select(.value != true) | .key + " missing"] | join(", ")')")
        failed=1
    fi
    printf 'CT %s: %s, %s, periphery %s %s\n' "$id" "$payload" "$tools" \
        "$(pve_display "$(br_json .periphery.mode)")" "$(pve_display "$(br_json .periphery.active)")"
    if [[ $(br_json .supported) != true ]]; then
        printf '  cannot manage this CT: %s\n' "$(pve_display "$(br_json .reason)")"; failed=1
    fi
    if [[ $(br_json .periphery.can_read) != true ]]; then printf '  service user cannot read credentials\n'; failed=1; fi
    if [[ $mode == container ]]; then
        if [[ $(br_json .periphery.tools_ok) != true ]]; then
            failed=1
            missing=$(br_json '.periphery.missing_tools | join(", ")') # Only the three names, by BR_STATUS_SHAPE.
            if [[ -z $missing ]]; then printf '  could not check bash, curl and jq in the Periphery container\n'
            elif [[ $missing != *jq* ]]; then printf '  the Periphery container lacks %s\n' "$missing"
            elif [[ -n $brief ]]; then printf '  the Periphery container lacks %s; see %s\n' "$missing" "$BR_JQ_DOCS"
            else printf '  the Periphery container lacks %s\n' "$missing"; br_jq_help; fi
        fi
        if [[ $(br_json .periphery.sha256) != "$(br_json .payload.sha256)" ]]; then
            printf '  restart the Periphery container to load the new payload\n'; failed=1
        fi
    fi
    while IFS=$'\t' read -r role files login; do
        [[ -n $role ]] || continue
        seen[$role]=1
        approle=${BR_APPROLE[$role]:-not recorded}
        [[ $files == true ]] && files='credentials ok' || { files='credentials bad'; failed=1; }
        line="  $role ($approle): $files, login $(pve_display "$login")"
        printf '%s\n' "$line"
        [[ $login == ok ]] || failed=1
        hint=$(br_login_hint "$login")
        [[ -z $hint ]] || printf '    %s\n' "$hint"
    done < <(br_json '.roles[] | [.name, .files_ok, .login] | @tsv')
    for role in "${BR_SAVED_ROLES[@]}"; do
        [[ -n ${seen[$role]:-} ]] || { printf '  %s (%s): missing from the CT\n' "$role" "${BR_APPROLE[$role]}"; failed=1; }
    done
    if ((${#seen[@]} == 0 && ${#BR_SAVED_ROLES[@]} == 0)); then printf '  no roles\n'; failed=1; fi
    br_show_unknown || failed=1
    return "$failed"
}
br_status() { # [brief]: one line per fact, for doctor's single-line detail.
    br_ids || return 1
    ((${#BR_MANAGED[@]})) || { printf 'no managed containers\n'; return 0; }
    br_host_require || return 1
    local id failed=0
    for id in "${BR_MANAGED[@]}"; do
        br_status_one "$id" "${1:-}" || failed=1
        if [[ -n $(conf_get "bao-run-$id" BR_PENDING) ]]; then # Also when the CT cannot be reached.
            printf '  pending: staging left by an incomplete operation; run install or uninstall bao-run to clean it up\n'; failed=1
        fi
    done
    return "$failed"
}
br_check() { # Read-only and no login.
    br_ids || return 1
    ((${#BR_MANAGED[@]})) || { printf 'no managed containers\n'; return 0; }
    br_host_require || return 1
    local id failed=0 want current
    want=$(sha256sum < "$(br_payload_source)" | cut -d ' ' -f1)
    for id in "${BR_MANAGED[@]}"; do
        if ! br_inspect "$id"; then printf 'CT %s: cannot inspect: %s\n' "$id" "$BR_INSPECT_ERROR"; failed=1; continue; fi
        if [[ -z $BR_TARGET_IDENTITY || $BR_TARGET_IDENTITY != "$(conf_get "bao-run-$id" BR_IDENTITY)" ]]; then
            printf 'CT %s: identity mismatch\n' "$id"; failed=1; continue
        fi
        current=$(br_json .payload.sha256)
        if [[ $current == "$want" ]]; then printf 'CT %s: up to date\n' "$id"
        else printf 'update available: CT %s %s -> %s\n' "$id" "$(pve_display "$(br_short "$current")")" "${want:0:12}"; fi
    done
    return "$failed"
}
br_doctor() {
    local output rc=0
    output=$(br_status brief 2>&1) || rc=$?
    if [[ $rc == 0 ]]; then doctor_result pass agents 'bao-run is healthy in every managed container' "${output//$'\n'/; }"
    else doctor_result fail agents 'one or more managed containers require attention' "${output//$'\n'/; }"; fi
}
