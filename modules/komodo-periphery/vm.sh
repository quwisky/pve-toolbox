# shellcheck shell=bash
# VM records and orchestration. Sourcing this file has no side effects.

kp_vm_registry() ( # <list|add|remove> [vmid]; serialize the shared index only.
    local action=$1 target=${2:-} id ids found=0 lock file
    local path="$TOOLBOX_STATE_DIR/komodo-periphery-qemu.lock"
    local -a updated=()
    case $action in
        list) ;;
        add|remove)
            kp_target_key qemu "$target" >/dev/null || return 1
            for file in "$(conf_file "komodo-periphery-qemu-$target")" "$TOOLBOX_STATE_DIR/komodo-periphery-qemu-$target.state"; do
                kp_host_safe "$file" && [[ ! -e $file || -f $file ]] || return 1
            done ;;
        *) return 1 ;;
    esac
    file=$(conf_file komodo-periphery-qemu)
    kp_host_safe "$path" && [[ ! -e $path || -f $path ]] &&
        kp_host_safe "$file" && [[ ! -e $file || -f $file ]] || return 1
    mkdir -p -- "$TOOLBOX_STATE_DIR" || return 1
    exec {lock}>"$path" || return 1
    flock -w 10 "$lock" || { warn 'managed-VM registry is busy'; return 1; }
    ids=$(conf_get komodo-periphery-qemu KP_VM_IDS)
    for id in $ids; do # Validated whitespace-separated decimal VMIDs.
        kp_target_key qemu "$id" >/dev/null || { warn 'invalid saved VM ID'; return 1; }
        kp_host_safe "$(conf_file "komodo-periphery-qemu-$id")" &&
            kp_host_safe "$TOOLBOX_STATE_DIR/komodo-periphery-qemu-$id.state" || {
                warn 'unsafe managed-VM record'; return 1;
            }
        if [[ $id == "$target" ]]; then
            found=1
            [[ $action != remove ]] || continue
        fi
        updated+=("$id")
    done
    if [[ $action == list ]]; then
        printf '%s' "${updated[*]}"
    elif [[ $action == add && $found == 1 ]]; then
        return 0
    else
        if [[ $action == add ]]; then updated+=("$target"); fi
        if ((${#updated[@]})); then
            conf_set komodo-periphery-qemu KP_VM_IDS "${updated[*]}"
        else
            conf_clear komodo-periphery-qemu
        fi
    fi
)

kp_vm_ids() {
    KP_VM_IDS=()
    local ids
    ids=$(kp_vm_registry list) || return 1
    # The registry emits validated whitespace-separated decimal VMIDs.
    read -r -a KP_VM_IDS <<<"$ids"
}

kp_vm_save() { # <vmid> <version> <identity> <fingerprint> <install|update|uninstall>
    local id=$1 version=$2 identity=$3 fingerprint=$4 action=$5
    kp_target_key qemu "$id" >/dev/null || return 1
    [[ $action == install || $action == update || $action == uninstall || $action == configure ]] || return 1
    # Even an uninstalled VM remains visible until staging cleanup succeeds.
    kp_vm_register "$id" || return 1
    conf_set "komodo-periphery-qemu-$id" KP_VERSION "$version" &&
        conf_set "komodo-periphery-qemu-$id" KP_IDENTITY "$identity" &&
        state_set "komodo-periphery-qemu-$id" version "$version" &&
        state_set "komodo-periphery-qemu-$id" machine_id "${KP_VM_MACHINE:-}" &&
        state_set "komodo-periphery-qemu-$id" fingerprint "$fingerprint" &&
        state_set "komodo-periphery-qemu-$id" result "$action completed; Core connectivity unverified"
}

kp_vm_register() { # Include a first-install target before staging can fail.
    kp_vm_registry add "$1"
}

kp_vm_uuid() { # <QEMU config JSON>; absent SMBIOS is permitted for QGA only.
    local smbios uuid
    smbios=$(jq -r '.smbios1 // ""' <<<"$1") || return 1
    [[ -z $smbios || $smbios == uuid=* || $smbios == *,uuid=* ]] || return 1
    uuid=$(sed -nE 's/(^|.*,)(uuid=)([A-Fa-f0-9-]{36})(,.*|$)/\3/p' <<<"$smbios")
    [[ -z $smbios || $uuid =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]] || return 1
    printf '%s' "${uuid,,}"
}

kp_vm_inspect() { # <vmid>; uses selected KP_VM_* connection globals
    local id=$1 config uuid command result machine
    KP_INSPECTION_JSON='' KP_TARGET_IDENTITY=''
    pve_qemu_ready "$KP_NODE" "$id" || { warn "$PVE_QEMU_ERROR"; return 1; }
    config=$PVE_QEMU_CONFIG_JSON
    uuid=$(kp_vm_uuid "$config") || { warn 'invalid PVE SMBIOS UUID'; return 1; }
    if [[ $KP_VM_TRANSPORT == qga ]]; then
        jq -e '(.agent == 1 or (.agent | type=="string" and test("(^1(,|$)|(^|,)enabled=1(,|$))")))' \
            <<<"$config" >/dev/null 2>&1 || { warn 'QEMU Guest Agent is not enabled for this VM'; return 1; }
        [[ $(stat -c %s -- "$(kp_guest_source)") -le 49152 ]] || { warn 'guest inspection helper exceeds QGA input limit'; return 1; }
        command='["/bin/bash","-s","--","inspect"]'
        result=$(kp_qga_exec "$KP_NODE" "$id" "$command" "$(kp_guest_source)") || { warn 'QGA guest inspection failed'; return 1; }
    elif [[ $KP_VM_TRANSPORT == ssh ]]; then
        [[ -n $uuid ]] || { warn 'SSH requires a PVE smbios1 UUID'; return 1; }
        kp_ssh_inspect "$id" "$KP_VM_ADDRESS" "$KP_VM_PORT" "$KP_VM_KEY" "$KP_VM_HOSTS" "$uuid" || { warn 'pinned SSH guest inspection failed'; return 1; }
        [[ -z ${KP_VM_HOST_FINGERPRINT:-} || $KP_SSH_HOST_FINGERPRINT == "$KP_VM_HOST_FINGERPRINT" ]] || { warn 'SSH host key changed'; return 1; }
        result=$KP_SSH_INSPECTION_JSON
    else return 1; fi
    [[ ${#result} -le 65536 ]] && jq -e 'type=="object" and .schema==1 and
        (.layout=="absent" or .layout=="supported" or .layout=="unsupported") and
        (.machine_id|type=="string" and test("^[a-f0-9]{32}$")) and
        (.fingerprint|type=="string") and (.version|type=="string") and (.reason|type=="string")' \
        <<<"$result" >/dev/null 2>&1 || { warn 'invalid VM guest inspection'; return 1; }
    machine=$(jq -r .machine_id <<<"$result")
    KP_TARGET_IDENTITY=$(printf '%s\n' "$KP_NODE" qemu "$id" "$uuid" "$machine" | sha256sum | cut -d ' ' -f1)
    KP_INSPECTION_JSON=$result KP_VM_UUID=$uuid
}

kp_vm_match() { # <vmid> <expected identity> <expected machine ID>
    kp_vm_inspect "$1" || return 1
    [[ $KP_TARGET_IDENTITY == "$2" && $(jq -r .machine_id <<<"$KP_INSPECTION_JSON") == "$3" ]] || {
        warn 'VM identity changed; no further guest action applied'; return 1;
    }
}

kp_vm_lock() { # <vmid>
    local path="$TOOLBOX_STATE_DIR/komodo-periphery-qemu-$1.lock"
    kp_target_key qemu "$1" >/dev/null && kp_host_safe "$path" && [[ ! -e $path || -f $path ]] || return 1
    mkdir -p -- "$TOOLBOX_STATE_DIR" || return 1
    exec {KP_VM_LOCK}>"$path"
    flock -n "$KP_VM_LOCK" || { warn 'another operation on this VM is active'; return 1; }
}

kp_vm_command() { # <vmid> <JSON command array> [stdin-file]
    local id=$1 command=$2 input=${3:-} remote
    if [[ $KP_VM_TRANSPORT == qga ]]; then
        kp_qga_exec "$KP_NODE" "$id" "$command" "$input"
    else
        remote=$(jq -er 'if type=="array" and length>0 and all(.[];type=="string" and test("^[A-Za-z0-9_./-]+$")) then join(" ") else error("unsafe") end' <<<"$command") || return 1
        kp_ssh_verified_run "$KP_VM_UUID" "$remote" "$input"
    fi
}

kp_vm_stage() { # <vmid> <kind> <host-file> <guest-stage-directory>
    local id=$1 kind=$2 file=$3 dir=$4
    kp_vm_match "$id" "$KP_VM_IDENTITY" "$KP_VM_MACHINE" || return 1
    [[ $(jq -r .fingerprint <<<"$KP_INSPECTION_JSON") == "$KP_VM_FINGERPRINT" ]] || { warn 'VM agent changed after preview'; return 1; }
    if [[ $KP_VM_TRANSPORT == qga ]]; then kp_qga_stage "$KP_NODE" "$id" "$kind" "$file" "$dir" "$KP_VM_MACHINE"
    else kp_ssh_stage "$kind" "$file" "$dir" "$KP_VM_UUID" "$KP_VM_MACHINE"; fi
}

kp_vm_cleanup() { # <vmid> <stage-directory>; leave pending on any uncertainty
    local id=$1 dir=$2 command
    kp_qga_stage_path "$dir" || return 1
    kp_vm_match "$id" "$KP_VM_IDENTITY" "$KP_VM_MACHINE" || return 1
    [[ $(jq -r .transaction <<<"$KP_INSPECTION_JSON") != pending ]] || return 1
    command=$(jq -nc --arg dir "$dir" --arg machine "$KP_VM_MACHINE" '["/bin/bash","-s","--",$dir,$machine]')
    kp_vm_command "$id" "$command" "$TOOLBOX_ROOT/modules/komodo-periphery/stage-cleanup.sh" >/dev/null || return 1
    # A rolled-back uninstall must stay registered. Only remove the entry for
    # the committed uninstall whose staging we have just verified as cleaned.
    if jq -e --arg txn "${dir##*-}" '.transaction=="committed" and .transaction_id==$txn and .last_action=="uninstall"' \
        <<<"$KP_INSPECTION_JSON" >/dev/null; then
        kp_vm_registry remove "$id" || return 1
    fi
    conf_set "komodo-periphery-qemu-$id" KP_PENDING ''
}

kp_vm_recover() { # <vmid> <transaction-id>
    local id=$1 txn=$2 command
    [[ $txn =~ ^[a-f0-9]{32}$ ]] || return 1
    kp_vm_match "$id" "$KP_VM_IDENTITY" "$KP_VM_MACHINE" || return 1
    command=$(jq -nc --arg txn "$txn" '["/bin/bash","-s","--","recover",$txn]')
    kp_vm_command "$id" "$command" "$(kp_guest_source)" >/dev/null
}

kp_vm_apply() { # <vmid> <request> <binary-or-empty>
    local id=$1 request=$2 binary=$3 dir="/run/pve-toolbox-komodo-$KP_TRANSACTION" command result rc=0
    kp_vm_match "$id" "$KP_VM_IDENTITY" "$KP_VM_MACHINE" || return 1
    [[ $(jq -r .fingerprint <<<"$KP_INSPECTION_JSON") == "$KP_VM_FINGERPRINT" ]] || return 1
    kp_vm_register "$id" &&
        conf_set "komodo-periphery-qemu-$id" KP_PENDING "$KP_TRANSACTION" &&
        conf_set "komodo-periphery-qemu-$id" KP_IDENTITY "$KP_VM_IDENTITY" || return 1
    state_set "komodo-periphery-qemu-$id" machine_id "$KP_VM_MACHINE" &&
        state_set "komodo-periphery-qemu-$id" result 'operation incomplete; inspect pending transaction' || return 1
    if [[ $KP_VM_TRANSPORT == qga ]]; then kp_qga_bootstrap "$KP_NODE" "$id" "$dir" || return 1
    else kp_ssh_bootstrap "$dir" "$KP_VM_UUID" || return 1; fi
    kp_vm_stage "$id" helper "$(kp_guest_source)" "$dir" || return 1
    if [[ -n $binary ]]; then kp_vm_stage "$id" binary "$binary" "$dir" || return 1; fi
    kp_vm_stage "$id" request "$request" "$dir" || return 1
    kp_vm_match "$id" "$KP_VM_IDENTITY" "$KP_VM_MACHINE" || return 1
    command=$(jq -nc --arg dir "$dir" '["/bin/bash",($dir+"/guest.sh"),"apply",($dir+"/request.json")]')
    result=$(kp_vm_command "$id" "$command" 2>/dev/null | head -c 65537) || rc=$?
    [[ ${#result} -le 65536 ]] && jq -e --arg txn "$KP_TRANSACTION" 'type=="object" and .schema==1 and .transaction_id==$txn and
        (.result=="success" or .result=="failed") and (.reason|type=="string") and (.rollback|type=="string")' \
        <<<"$result" >/dev/null 2>&1 || { warn 'VM outcome unavailable; pending transaction requires recovery'; return 1; }
    KP_OUTCOME_JSON=$result
    if [[ $rc != 0 || $(jq -r .result <<<"$result") != success ]]; then
        warn "VM guest operation failed: $(kp_display "$(jq -r .reason <<<"$result")") (rollback: $(kp_display "$(jq -r .rollback <<<"$result")"))"
        kp_host_diagnostics "$result" "$request"
        return 1
    fi
}

kp_vm_load_connection() { # <vmid>; saved, validated paths remain operator configuration
    local key="komodo-periphery-qemu-$1"
    KP_VM_TRANSPORT=$(conf_get "$key" KP_TRANSPORT)
    KP_VM_ADDRESS=$(conf_get "$key" KP_ADDRESS)
    KP_VM_PORT=$(conf_get "$key" KP_PORT)
    KP_VM_KEY=$(conf_get "$key" KP_KEY_FILE)
    KP_VM_HOSTS=$(conf_get "$key" KP_KNOWN_HOSTS)
    KP_VM_HOST_FINGERPRINT=$(conf_get "$key" KP_HOST_FINGERPRINT)
    [[ $KP_VM_TRANSPORT == qga || $KP_VM_TRANSPORT == ssh ]] || return 1
    if [[ $KP_VM_TRANSPORT == ssh ]]; then
        kp_ssh_prepare "$1" "$KP_VM_ADDRESS" "$KP_VM_PORT" "$KP_VM_KEY" "$KP_VM_HOSTS" || return 1
    fi
}

kp_vm_change() ( # <install|update|uninstall>; called after explicit VM selection
    local action=$1 id='' transport='' address='' port='' key_file='' hosts='' saved_transport='' saved_port='' saved_identity=''
    local inspected='' layout='' version='' release='' digest='' binary='' core='' name='' key='' key_action=keep
    local choice='' adopt=false retained=false configure_retained=false pending='' record='' file='' fingerprint=''
    [[ $action == install || $action == update || $action == uninstall ]] || return 1
    kp_host_require || return 1
    pve_qemu_inventory "$KP_NODE" || { warn "$PVE_QEMU_ERROR"; return 1; }
    info 'Existing local VMs:'
    jq -r '.[] | [.vmid, (.name // "unnamed"), .status] | @tsv' <<<"$PVE_QEMU_JSON" | while IFS= read -r row; do kp_display "$row"; printf '\n'; done
    ask_valid id 'VM ID' '' kp_valid_vmid
    record="komodo-periphery-qemu-$id"
    for file in "$(conf_file "$record")" "$(conf_file komodo-periphery-qemu)" "$TOOLBOX_STATE_DIR/$record.state"; do
        kp_host_safe "$file" && [[ ! -e $file || -f $file ]] || { warn 'unsafe VM record path'; return 1; }
    done
    saved_transport=$(conf_get "$record" KP_TRANSPORT)
    ask_choice transport 'VM transport' "${saved_transport:-qga}" qga ssh
    case $transport in qga|ssh) ;; *) return 1 ;; esac
    KP_VM_TRANSPORT=$transport KP_VM_HOST_FINGERPRINT='' KP_VM_ADDRESS='' KP_VM_PORT='' KP_VM_KEY='' KP_VM_HOSTS=''
    if [[ $transport == ssh ]]; then
        ask_valid address 'Pinned SSH address or DNS name' "$(conf_get "$record" KP_ADDRESS)" kp_valid_ssh_address
        saved_port=$(conf_get "$record" KP_PORT)
        ask_int port 'SSH port' "${saved_port:-22}" 1 65535
        ask_valid key_file 'Absolute root-owned SSH private-key path' "$(conf_get "$record" KP_KEY_FILE)" kp_valid_ssh_file
        ask_valid hosts 'Absolute root-owned dedicated known-hosts path' "$(conf_get "$record" KP_KNOWN_HOSTS)" kp_valid_ssh_file
        KP_VM_ADDRESS=$address KP_VM_PORT=$port KP_VM_KEY=$key_file KP_VM_HOSTS=$hosts
        if [[ $saved_transport == ssh ]]; then KP_VM_HOST_FINGERPRINT=$(conf_get "$record" KP_HOST_FINGERPRINT); fi
        kp_ssh_prepare "$id" "$address" "$port" "$key_file" "$hosts" || { warn 'SSH identity files or pinned host key invalid'; return 1; }
        port=$KP_SSH_PORT KP_VM_PORT=$KP_SSH_PORT
    fi
    kp_vm_inspect "$id" || return 1
    KP_VM_IDENTITY=$KP_TARGET_IDENTITY
    KP_VM_MACHINE=$(jq -r .machine_id <<<"$KP_INSPECTION_JSON")
    KP_VM_FINGERPRINT=$(jq -r .fingerprint <<<"$KP_INSPECTION_JSON")
    fingerprint=''
    [[ $transport != ssh ]] || fingerprint=$KP_SSH_HOST_FINGERPRINT
    saved_identity=$(conf_get "$record" KP_IDENTITY)
    [[ -z $saved_identity || $saved_identity == "$KP_VM_IDENTITY" ]] || { warn 'recorded VM identity differs; review replacement or migration'; return 1; }
    inspected=$KP_INSPECTION_JSON
    layout=$(jq -r .layout <<<"$inspected")
    pending=$(conf_get "$record" KP_PENDING)
    if [[ -n $saved_transport && $saved_transport != "$transport" ]]; then
        info "Re-pair VM $id from $saved_transport to $transport using the verified guest machine ID."
        confirm 'Use this different transport for the selected VM' n || return 1
    fi
    if [[ $(jq -r .transaction <<<"$inspected") == pending ]]; then
        local guest_txn
        guest_txn=$(jq -r .transaction_id <<<"$inspected")
        [[ $guest_txn =~ ^[a-f0-9]{32}$ ]] || { warn 'unreadable VM pending transaction'; return 1; }
        [[ -z $pending || $pending == "$guest_txn" ]] || { warn 'host and guest transaction IDs differ'; return 1; }
        info "VM $id has an incomplete guest transaction; recovery restores its previous service state."
        confirm 'Recover the interrupted VM operation' n || return 1
        kp_vm_lock "$id" && kp_vm_recover "$id" "$guest_txn" || { warn 'VM recovery failed; previous backups retained'; return 1; }
        kp_vm_cleanup "$id" "/run/pve-toolbox-komodo-$guest_txn" || { warn 'VM staging cleanup incomplete'; return 1; }
        ok 'VM guest transaction recovered; run the requested operation again'
        return 0
    fi
    if [[ -n $pending ]]; then
        [[ $pending =~ ^[a-f0-9]{32}$ ]] || { warn 'invalid saved VM transaction ID'; return 1; }
        if [[ $(jq -r .transaction_id <<<"$inspected") == "$pending" && $(jq -r .transaction <<<"$inspected") == committed ]]; then
            info "VM $id completed a guest transaction whose host record was not saved."
            confirm 'Reconcile the completed VM transaction' n || return 1
            kp_vm_lock "$id" && kp_vm_match "$id" "$KP_VM_IDENTITY" "$KP_VM_MACHINE" || return 1
            kp_vm_save "$id" "$(jq -r .version <<<"$inspected")" "$KP_VM_IDENTITY" "$(jq -r .fingerprint <<<"$inspected")" "$(jq -r .last_action <<<"$inspected")" || return 1
        else
            info "VM $id has protected staging from an earlier attempt."
            confirm 'Clean up the previous VM staging' n || return 1
            kp_vm_lock "$id" || return 1
        fi
        kp_vm_cleanup "$id" "/run/pve-toolbox-komodo-$pending" || { warn 'VM staging cleanup incomplete'; return 1; }
        ok 'VM transaction record reconciled; run the requested operation again'
        return 0
    fi
    [[ $layout != unsupported ]] || { warn "unsupported VM installation: $(kp_display "$(jq -r .reason <<<"$inspected")")"; return 1; }
    if [[ $layout == supported ]]; then
        version=$(jq -r .version <<<"$inspected")
        info "VM $id: $(kp_display "$(jq -r '"Periphery " + .version + ", " + .binary + ", service user " + .service_user' <<<"$inspected")")"
        info "Unit: $(kp_display "$(jq -r .unit <<<"$inspected")")"
        info "Configuration: $(kp_display "$(jq -r '.config_paths | join(", ")' <<<"$inspected")")"
        if [[ $action == install ]]; then
            ask_choice choice 'Existing agent action' update update configure
            case $choice in update|configure) action=$choice ;; *) return 1 ;; esac
        fi
        if [[ $action == configure ]]; then
            [[ $(jq '.config_paths|length' <<<"$inspected") == 1 && $(jq -r '.config_paths[0]' <<<"$inspected") == *.toml ]] || { warn 'configuration editing requires one TOML file'; return 1; }
        fi
        if [[ $(jq -r .owned <<<"$inspected") != true ]]; then
            [[ $action != uninstall ]] || { warn 'only toolbox-owned agents can be uninstalled'; return 1; }
            confirm 'Adopt this existing VM installation for management' n || return 1
            adopt=true
        fi
    else
        [[ $action == install ]] || { warn 'Periphery is not installed; use install first'; return 1; }
        version=''
        if [[ $(jq -r .retained <<<"$inspected") == true && $(jq '.config_paths|length' <<<"$inspected") == 1 ]]; then
            retained=true
            ask_choice choice 'Retained configuration action' configure configure reuse
            case $choice in configure) configure_retained=true ;; reuse) ;; *) return 1 ;; esac
        fi
    fi
    KP_TRANSACTION=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [[ $KP_TRANSACTION =~ ^[a-f0-9]{32}$ ]] || return 1
    KP_VM_WORK=$(mktemp -d) || return 1
    chmod 0700 "$KP_VM_WORK"
    trap '[[ -z ${KP_VM_WORK:-} ]] || rm -rf -- "$KP_VM_WORK"' EXIT
    if [[ $action == install || $action == update ]]; then
        release=$(conf_get "$record" KP_VERSION)
        ask_valid release 'Exact stable Periphery v2 version compatible with your Core (e.g. 2.3.3)' "${release:-$version}" kp_valid_release
        [[ -z $version || $release == "$version" ]] || is_newer "$release" "$version" || { warn 'downgrades are unsupported'; return 1; }
        gh_release moghtech/komodo "v$release"
        [[ $GH_TAG == "v$release" ]] && gh_exact_asset periphery-x86_64 || { warn 'release has no verified amd64 asset'; return 1; }
        [[ $GH_ASSET_URL == "https://github.com/moghtech/komodo/releases/download/v$release/periphery-x86_64" ]] || return 1
        binary=$KP_VM_WORK/periphery
        curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 -o "$binary" "$GH_ASSET_URL" &&
            verify_sha256 "$binary" "$GH_ASSET_SHA256" || { warn 'release checksum verification failed'; return 1; }
        digest=$GH_ASSET_SHA256
    else release=$version; digest=$(printf '%064d' 0); fi
    : > "$KP_VM_WORK/key"; chmod 0600 "$KP_VM_WORK/key"
    if [[ $action == configure || $configure_retained == true ]]; then
        ask_valid core 'Core URL (HTTP or HTTPS; blank keeps current)' '' kp_valid_core_url_or_blank
        ask name 'Server name in Core (blank keeps current)' ''
        ask_choice key_action 'Onboarding key action' keep keep replace remove
        if [[ $key_action == replace ]]; then
            ask_secret key 'Core v2 onboarding key' valid_required
            printf '%s' "$key" > "$KP_VM_WORK/key"; unset key
        fi
    elif [[ $layout == absent && $retained == false ]]; then
        ask_valid core 'Core URL (HTTP or HTTPS)' '' kp_valid_core_url
        ask_valid name 'Server name in Core' "vm-$id" valid_required
        ask_secret key 'Core v2 onboarding key' valid_required
        printf '%s' "$key" > "$KP_VM_WORK/key"; unset key
    fi
    info "Node $KP_NODE / VM $id ($transport): $action Periphery ${version:-absent} -> $release"
    info "Guest machine ID: $KP_VM_MACHINE; PVE SMBIOS UUID: ${KP_VM_UUID:-not set}"
    if [[ $transport == ssh ]]; then info "SSH: $address:$port; pinned host key $fingerprint"; fi
    info "Service account: $(kp_display "$(jq -r .service_user <<<"$inspected")"); unit: /etc/systemd/system/periphery.service; binary: /usr/local/bin/periphery"
    info 'Guest root can run Core-directed commands. The agent may restart; failed starts trigger rollback.'
    if [[ $action == uninstall ]]; then info 'Owned binary and service are removed; configuration, keys and workloads are retained.'; fi
    info 'Core connectivity remains unverified until checked in Core.'
    confirm 'Apply this operation to the selected VM' n || { info 'cancelled; VM unchanged'; return 0; }
    kp_vm_lock "$id" && kp_vm_match "$id" "$KP_VM_IDENTITY" "$KP_VM_MACHINE" || return 1
    [[ $(jq -r .fingerprint <<<"$KP_INSPECTION_JSON") == "$KP_VM_FINGERPRINT" ]] || return 1
    conf_set "$record" KP_TRANSPORT "$transport" && conf_set "$record" KP_ADDRESS "${KP_VM_ADDRESS:-}" &&
        conf_set "$record" KP_PORT "${KP_VM_PORT:-}" && conf_set "$record" KP_KEY_FILE "${KP_VM_KEY:-}" &&
        conf_set "$record" KP_KNOWN_HOSTS "${KP_VM_HOSTS:-}" && conf_set "$record" KP_HOST_FINGERPRINT "$fingerprint" || return 1
    jq -nc --arg action "$action" --arg txn "$KP_TRANSACTION" --arg machine "$KP_VM_MACHINE" \
        --arg fingerprint "$KP_VM_FINGERPRINT" --argjson adopt "$adopt" --arg version "$release" --arg digest "$digest" \
        --arg config_fingerprint "$(jq -r '.config_fingerprint // ""' <<<"$inspected")" --arg key_action "$key_action" --argjson configure_retained "$configure_retained" \
        --arg candidate "/run/pve-toolbox-komodo-$KP_TRANSACTION/periphery" --arg core "$core" --arg name "$name" --rawfile key "$KP_VM_WORK/key" \
        '{schema:1,action:$action,transaction_id:$txn,machine_id:$machine,expected_fingerprint:$fingerprint,adopt:$adopt,
          version:$version,asset_sha256:$digest,staged_binary:$candidate,core_url:$core,server_name:$name,onboarding_key:$key,
          config_fingerprint:$config_fingerprint,onboarding_key_action:$key_action,configure_retained:$configure_retained}' > "$KP_VM_WORK/request.json" || return 1
    chmod 0600 "$KP_VM_WORK/request.json"
    kp_vm_apply "$id" "$KP_VM_WORK/request.json" "$binary" || return 1
    kp_vm_save "$id" "$release" "$KP_VM_IDENTITY" "$(jq -r .fingerprint <<<"$KP_OUTCOME_JSON")" "$action" || { warn 'VM guest committed but host record failed; rerun to reconcile'; return 1; }
    kp_vm_cleanup "$id" "/run/pve-toolbox-komodo-$KP_TRANSACTION" || { warn 'VM guest committed but staging cleanup is incomplete'; return 1; }
    ok "VM $id: $action completed; Core connectivity unverified. Confirm the server is online in Core."
)

kp_vm_status() {
    kp_vm_ids || return 1
    ((${#KP_VM_IDS[@]})) || { printf 'no managed VMs\n'; return 0; }
    kp_host_require || return 1
    local id record pending failed=0
    for id in "${KP_VM_IDS[@]}"; do
        record="komodo-periphery-qemu-$id"
        pending=$(conf_get "$record" KP_PENDING)
        if [[ -n $pending ]]; then printf 'VM %s: pending transaction %s\n' "$id" "$pending"; failed=1; fi
        if ! kp_vm_load_connection "$id" || ! kp_vm_match "$id" "$(conf_get "$record" KP_IDENTITY)" "$(state_get "$record" machine_id)"; then
            printf 'VM %s: unreachable or identity changed\n' "$id"; failed=1; continue
        fi
        printf 'VM %s (%s): %s\n' "$id" "$KP_VM_TRANSPORT" "$(jq -r '[.layout,.version,.enabled,.active,.transaction]|join(" / ")' <<<"$KP_INSPECTION_JSON" | tr -d '\000-\037\177')"
        printf 'Core connectivity: unverified\n'
        if [[ -n $pending || $(jq -r .layout <<<"$KP_INSPECTION_JSON") != supported ||
            $(jq -r .active <<<"$KP_INSPECTION_JSON") != active ||
            $(jq -r .transaction <<<"$KP_INSPECTION_JSON") == pending ||
            $(state_get "$record" fingerprint) != "$(jq -r .fingerprint <<<"$KP_INSPECTION_JSON")" ]]; then
            printf 'VM %s: incomplete transaction, inactive service or ownership drift\n' "$id"
            failed=1
        fi
    done
    return "$failed"
}

kp_vm_check() {
    kp_vm_ids || return 1
    ((${#KP_VM_IDS[@]})) || { printf 'no managed VMs\n'; return 0; }
    kp_host_require || return 1
    local id record desired current failed=0
    for id in "${KP_VM_IDS[@]}"; do
        record="komodo-periphery-qemu-$id"
        if [[ -n $(conf_get "$record" KP_PENDING) ]] || ! kp_vm_load_connection "$id" ||
            ! kp_vm_match "$id" "$(conf_get "$record" KP_IDENTITY)" "$(state_get "$record" machine_id)"; then
            printf 'VM %s: incomplete or unavailable\n' "$id"; failed=1; continue
        fi
        desired=$(conf_get "$record" KP_VERSION)
        current=$(jq -r .version <<<"$KP_INSPECTION_JSON")
        if [[ -z $current || ! $desired =~ ^2\.[0-9]+\.[0-9]+$ ]]; then printf 'VM %s: version unavailable\n' "$id"; failed=1
        elif is_newer "$desired" "$current"; then printf 'update available: VM %s %s -> %s (saved target)\n' "$id" "$current" "$desired"
        else printf 'VM %s: installed %s, selected %s; choose a release with update komodo-periphery\n' "$id" "$current" "$desired"; fi
    done
    return "$failed"
}
