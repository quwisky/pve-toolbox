# shellcheck shell=bash
# Host orchestration. Source time must remain side-effect free.
kp_target_key() { # <lxc|qemu> <numeric-id>; never use an unvalidated ID in a path.
    [[ $# -eq 2 && ( $1 == lxc || $1 == qemu ) && $2 =~ ^[1-9][0-9]{2,8}$ ]] || return 1
    printf '%s-%s' "$1" "$2"
}
# Prompt validators for ask_valid (lib/common.sh); vm.sh reuses them. The ask
# helpers read the ASK_REASON and ASK_NORMALIZED they set.
# shellcheck disable=SC2034
kp_valid_core_url() {
    [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^[:space:]\?\#]*)?$ && $1 != *@* ]] \
        || { ASK_REASON='provide an HTTP or HTTPS URL without credentials, query or fragment'; return 1; }
}
kp_valid_core_url_or_blank() { [[ -z $1 ]] || kp_valid_core_url "$1"; }
# shellcheck disable=SC2034
kp_valid_release() { # stores the version without a leading v
    [[ ${1#v} =~ ^2\.[0-9]+\.[0-9]+$ ]] || { ASK_REASON='choose an exact stable v2 release, e.g. 2.3.3'; return 1; }
    ASK_NORMALIZED=${1#v}
}
# shellcheck disable=SC2034
kp_valid_ctid() { # a container listed in PVE_LXC_JSON by pve_lxc_inventory
    [[ $1 =~ ^[1-9][0-9]{2,8}$ ]] && jq -e --argjson id "$1" 'any(.[];.vmid==$id)' <<<"$PVE_LXC_JSON" >/dev/null \
        || { ASK_REASON='select one listed local container'; return 1; }
}
# shellcheck disable=SC2034
kp_valid_vmid() { # a VM listed in PVE_QEMU_JSON by pve_qemu_inventory
    kp_target_key qemu "$1" >/dev/null && jq -e --argjson id "$1" 'any(.[];.vmid==$id)' <<<"$PVE_QEMU_JSON" >/dev/null \
        || { ASK_REASON='select one listed local VM'; return 1; }
}
# The guest refuses bytes below 32 and 127 in the server name and onboarding
# key, but only after the Apply confirm. The reason never repeats the value.
# shellcheck disable=SC2034
kp_valid_printable() { # blank passes; see kp_valid_required_printable
    local LC_ALL=C
    [[ $1 != *[[:cntrl:]]* ]] || { ASK_REASON='use printable characters only (no tabs or other control characters)'; return 1; }
}
kp_valid_required_printable() { valid_required "$1" && kp_valid_printable "$1"; }
kp_ssh_address_ok() { # the one address rule for the SSH prompt and kp_ssh_prepare
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}
# shellcheck disable=SC2034
kp_valid_ssh_address() {
    kp_ssh_address_ok "$1" \
        || { ASK_REASON='enter a host name or IPv4 address (letters, digits, dots and hyphens)'; return 1; }
}
kp_ssh_file_ok() { # the one key/known-hosts file rule for the prompts and kp_ssh_prepare
    kp_host_safe "$1" && [[ -f $1 && -r $1 && ! -L $1 ]]
}
# shellcheck disable=SC2034
kp_valid_ssh_file() {
    kp_ssh_file_ok "$1" || {
        ASK_REASON='enter an absolute path to an existing root-owned regular file that only root can change, with no symlink in the path'
        return 1
    }
}
kp_host_require() {
    require_root
    local cmd
    for cmd in pveversion pvesh pct jq curl flock sha256sum; do
        command -v "$cmd" >/dev/null || { warn "missing host command: $cmd"; return 1; }
    done
    [[ $(pveversion) == pve-manager/9.* ]] && ! in_lxc || { warn 'run on a PVE 9 host'; return 1; }
    KP_NODE=$(hostname -s)
    [[ $KP_NODE =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
}
kp_host_safe() { # Validate paths before shared persistence helpers mutate them.
    local path=$1 mode
    [[ $path == /* ]] || return 1
    while [[ -n $path && $path != / ]]; do
        [[ ! -L $path ]] || return 1
        if [[ -e $path ]]; then
            [[ $(stat -c %u -- "$path") == 0 ]] || return 1
            mode=$(stat -c %a -- "$path") || return 1
            # Root-owned sticky temporary ancestors are allowed; leaf files
            # and ordinary parents must not be writable by group/others.
            if [[ -d $path ]] && (( (8#$mode & 01000) != 0 )); then :
            else (( (8#$mode & 0022) == 0 )) || return 1; fi
        fi
        path=${path%/*}
    done
}
kp_host_ids() {
    KP_IDS=()
    local id ids
    kp_host_safe "$(conf_file komodo-periphery)" || return 1
    ids=$(conf_get komodo-periphery KP_IDS)
    for id in $ids; do # Saved format is a whitespace-separated numeric ID list.
        [[ $id =~ ^[1-9][0-9]{2,8}$ ]] || { warn 'invalid saved container ID'; return 1; }
        kp_host_safe "$(conf_file "komodo-periphery-$id")" &&
            kp_host_safe "$TOOLBOX_STATE_DIR/komodo-periphery-$id.state" || {
                warn 'unsafe managed-container record'; return 1;
            }
        KP_IDS+=("$id")
    done
}
kp_display() { # Untrusted guest strings must not control the host terminal.
    report_clean_text "$1" | LC_ALL=C tr -d '\000-\037\177'
}
kp_host_diagnostics() { # <outcome JSON> <protected request>; human output only
    local result=$1 request=$2 message key
    jq -e '.diagnostics | type=="object" and (.service|type=="string") and
        (.journal|type=="array" and all(.[];type=="string"))' <<<"$result" >/dev/null 2>&1 || return 0
    key=$(jq -r '.onboarding_key // ""' "$request")
    warn 'Periphery startup failure (captured before rollback):'
    while IFS= read -r message; do
        message=$(jq -r . <<<"$message")
        [[ -z $key ]] || message=${message//"$key"/'[redacted]'}
        message=$(kp_display "$message")
        # Omit the whole journal entry, including continuation lines, when it
        # mentions credentials. Use the shared filter for other credential forms.
        if [[ ${message,,} =~ ((onboarding|private|api|access)[_\ -]?key|passkey|password|passphrase|secret|token|authorization|bearer) ]]; then
            message='[credential-bearing journal entry withheld]'
        fi
        warn "  $message"
    done < <(jq -c '.diagnostics | (.health // empty | select(type=="string" and length>0)), .service, .journal[]' <<<"$result")
}
kp_guest_source() { printf '%s/modules/komodo-periphery/guest.sh' "$TOOLBOX_ROOT"; }
kp_host_inspect() { # <ctid> -> KP_INSPECTION_JSON, KP_TARGET_IDENTITY
    local config result machine rootfs
    KP_INSPECTION_JSON="" KP_TARGET_IDENTITY=""
    pve_lxc_ready "$KP_NODE" "$1" || { warn "$PVE_LXC_ERROR"; return 1; }
    config=$PVE_LXC_CONFIG_JSON
    result=$(pct exec "$1" -- bash -s -- inspect < "$(kp_guest_source)" 2>/dev/null) || { warn 'guest inspection failed'; return 1; }
    [[ ${#result} -le 65536 ]] || { warn 'oversized guest inspection'; return 1; }
    jq -e 'type=="object" and .schema==1 and
        (.layout=="absent" or .layout=="supported" or .layout=="unsupported") and
        (.machine_id|type=="string" and test("^[a-f0-9]{32}$")) and
        (.fingerprint|type=="string") and (.version|type=="string") and
        (.reason|type=="string")' <<<"$result" >/dev/null 2>&1 || { warn 'invalid guest inspection response'; return 1; }
    machine=$(jq -r .machine_id <<<"$result")
    rootfs=$(jq -er '.rootfs | select(type=="string" and length>0) | split(",")[0]' <<<"$config") || { warn 'guest rootfs identity unavailable'; return 1; }
    KP_TARGET_IDENTITY=$(printf '%s\n' "$KP_NODE" "$1" "$rootfs" "$machine" | sha256sum | cut -d ' ' -f1)
    KP_INSPECTION_JSON=$result
}
kp_host_match() {
    local id=$1 expected=$2
    kp_host_inspect "$id" || return 1
    [[ $KP_TARGET_IDENTITY == "$expected" ]] || { warn 'container identity changed; nothing further applied'; return 1; }
}
kp_host_cleanup() {
    local rc=$?
    trap - EXIT INT TERM HUP
    if [[ -n ${KP_STAGE:-} && -n ${KP_CTID:-} && -n ${KP_IDENTITY:-} ]]; then
        if kp_host_match "$KP_CTID" "$KP_IDENTITY" >/dev/null 2>&1; then
            if pct exec "$KP_CTID" -- bash -c '
                [[ $1 =~ ^/run/pve-toolbox-komodo-[a-f0-9]{32}$ && ! -L $1 ]] || exit 1
                [[ -e $1 ]] || exit 0
                [[ -d $1 && $(stat -c %u "$1") == 0 && $(stat -c %a "$1") == 700 ]] || exit 1
                rm -f -- "$1/guest.sh" "$1/periphery" "$1/request.json"
                rmdir -- "$1"
            ' _ "$KP_STAGE" >/dev/null 2>&1; then
                if [[ ${KP_SAVED:-0} == 1 ]]; then
                    conf_set "komodo-periphery-$KP_CTID" KP_PENDING "" || { warn 'could not clear host pending record'; rc=1; }
                fi
            else
                warn 'guest staging cleanup incomplete; inspect the saved pending record'
                rc=1
            fi
        else
            warn 'guest became unavailable; protected staging path retained in pending configuration'
        fi
    fi
    [[ -z ${KP_WORK:-} ]] || rm -rf -- "$KP_WORK"
    exit "$rc"
}
kp_host_lock() {
    local id=$1 path
    for path in "$TOOLBOX_STATE_DIR/lxc-update.lock" "$TOOLBOX_STATE_DIR/komodo-periphery-$id.lock"; do
        kp_host_safe "$path" && [[ ! -e $path || -f $path ]] || return 1
    done
    mkdir -p "$TOOLBOX_STATE_DIR" || return 1
    exec {KP_LXC_LOCK}>"$TOOLBOX_STATE_DIR/lxc-update.lock"
    flock -n "$KP_LXC_LOCK" || { warn 'LXC package maintenance is active; retry later'; return 1; }
    exec {KP_CHANGE_LOCK}>"$TOOLBOX_STATE_DIR/komodo-periphery-$id.lock"
    flock -n "$KP_CHANGE_LOCK" || { warn 'another Periphery operation is active'; return 1; }
}
kp_host_apply() { # <ctid> <protected request> <verified binary, empty for uninstall>
    local id=$1 request=$2 binary=$3 result rc=0
    KP_STAGE=/run/pve-toolbox-komodo-$KP_TRANSACTION
    kp_host_match "$id" "$KP_IDENTITY" || return 1
    [[ $(jq -r .fingerprint <<<"$KP_INSPECTION_JSON") == "$KP_PREVIEW_FINGERPRINT" ]] || { warn 'installation changed after preview'; return 1; }
    conf_set "komodo-periphery-$id" KP_PENDING "$KP_TRANSACTION" && conf_set "komodo-periphery-$id" KP_IDENTITY "$KP_IDENTITY" || return 1
    pct exec "$id" -- mkdir -m 0700 -- "$KP_STAGE" >/dev/null 2>&1 || { warn 'could not create protected guest staging'; return 1; }
    kp_host_match "$id" "$KP_IDENTITY" || return 1
    pct push "$id" "$(kp_guest_source)" "$KP_STAGE/guest.sh" --perms 0600 >/dev/null 2>&1 || return 1
    if [[ -n $binary ]]; then
        kp_host_match "$id" "$KP_IDENTITY" || return 1
        pct push "$id" "$binary" "$KP_STAGE/periphery" --perms 0600 >/dev/null 2>&1 || return 1
    fi
    kp_host_match "$id" "$KP_IDENTITY" || return 1
    pct push "$id" "$request" "$KP_STAGE/request.json" --perms 0600 >/dev/null 2>&1 || return 1
    kp_host_match "$id" "$KP_IDENTITY" || return 1
    result=$(pct exec "$id" -- bash "$KP_STAGE/guest.sh" apply "$KP_STAGE/request.json" 2>/dev/null) || rc=$?
    [[ ${#result} -le 65536 ]] && jq -e --arg id "$KP_TRANSACTION" 'type=="object" and .schema==1 and .transaction_id==$id and
        (.result=="success" or .result=="failed") and (.reason|type=="string") and (.rollback|type=="string")' <<<"$result" >/dev/null 2>&1 || {
        warn 'guest outcome unavailable; inspect/recover the pending transaction before retrying'; return 1;
    }
    KP_OUTCOME_JSON=$result
    if [[ $rc != 0 || $(jq -r .result <<<"$result") != success ]]; then
        warn "guest operation failed: $(kp_display "$(jq -r .reason <<<"$result")") (rollback: $(kp_display "$(jq -r .rollback <<<"$result")"))"
        kp_host_diagnostics "$result" "$request"
        return 1
    fi
}
kp_host_save() {
    local id=$1 version=$2 identity=$3 fingerprint=$4 action=$5 ids=() found=0 old
    kp_host_ids || return 1
    for old in "${KP_IDS[@]}"; do
        if [[ $old == "$id" ]]; then found=1; [[ $action != uninstall ]] || continue; fi
        ids+=("$old")
    done
    if [[ $found == 0 && $action != uninstall ]]; then ids+=("$id"); fi
    conf_set "komodo-periphery-$id" KP_VERSION "$version" && conf_set "komodo-periphery-$id" KP_IDENTITY "$identity" &&
        state_set "komodo-periphery-$id" version "$version" && state_set "komodo-periphery-$id" fingerprint "$fingerprint" &&
        state_set "komodo-periphery-$id" result "$action completed; Core connectivity unverified" || return 1
    if ((${#ids[@]})); then conf_set komodo-periphery KP_IDS "${ids[*]}" || return 1
    else conf_clear komodo-periphery || return 1; fi
    KP_SAVED=1
}
kp_host_change() ( # Subshell owns locks, protected temporary files and traps.
    local action=$1 id="" release="" core="" name="" key="" saved_identity inspected layout version adopt=false file digest binary=""
    local key_action=keep choice="" guest_kind="" configure_retained=false retained_config=false
    [[ ${ASSUME_YES:-0} == 0 && ${FORCE:-0} == 0 && -t 0 && -t 1 ]] || { warn 'Periphery changes require a terminal and explicit confirmation; --yes/--force are unsupported'; return 1; }
    kp_host_require || return 1
    ask_choice guest_kind 'Guest type' lxc lxc vm
    case $guest_kind in
        vm) kp_vm_change "$action"; return $? ;;
        lxc) ;;
        *) warn 'unsupported guest type'; return 1 ;;
    esac
    pve_lxc_inventory "$KP_NODE" || { warn "$PVE_LXC_ERROR"; return 1; }
    info 'Existing local containers:'
    jq -r '.[] | [.vmid, (.name // "unnamed"), .status] | @tsv' <<<"$PVE_LXC_JSON" | while IFS= read -r row; do kp_display "$row"; printf '\n'; done
    ask_valid id 'Container ID' '' kp_valid_ctid
    KP_CTID=$id
    for file in "$(conf_file "komodo-periphery-$id")" "$TOOLBOX_STATE_DIR/komodo-periphery-$id.state" "$(conf_file komodo-periphery)"; do
        kp_host_safe "$file" && [[ ! -e $file || -f $file ]] || { warn 'unsafe host record path'; return 1; }
    done
    kp_host_inspect "$id" || return 1
    KP_IDENTITY=$KP_TARGET_IDENTITY
    saved_identity=$(conf_get "komodo-periphery-$id" KP_IDENTITY)
    [[ -z $saved_identity || $saved_identity == "$KP_IDENTITY" ]] || { warn 'recorded CT identity differs; inspect replacement or migration before managing it'; return 1; }
    inspected=$KP_INSPECTION_JSON
    layout=$(jq -r .layout <<<"$inspected")
    KP_PREVIEW_FINGERPRINT=$(jq -r .fingerprint <<<"$inspected")
    KP_WORK=$(mktemp -d); chmod 0700 "$KP_WORK"
    KP_STAGE=""
    trap kp_host_cleanup EXIT
    trap 'warn "interrupted; the guest journal will be checked before the next change"; exit 130' INT TERM HUP
    if [[ $(jq -r .transaction <<<"$inspected") == pending ]]; then
        local pending
        pending=$(jq -r .transaction_id <<<"$inspected")
        [[ $pending =~ ^[a-f0-9]{32}$ ]] || { warn 'unreadable pending transaction; manual inspection required'; return 1; }
        info "CT $id has an incomplete Periphery transaction; recovery restores its previous files and service state."
        confirm 'Recover the interrupted operation' n || return 1
        kp_host_lock "$id" && kp_host_match "$id" "$KP_IDENTITY" || return 1
        pct exec "$id" -- bash -s -- recover "$pending" < "$(kp_guest_source)" >/dev/null 2>&1 || { warn 'recovery failed; previous backups retained'; return 1; }
        KP_STAGE=/run/pve-toolbox-komodo-$pending
        KP_SAVED=1
        ok 'recovered; run the selected operation again'
        return 0
    fi
    local pending
    pending=$(conf_get "komodo-periphery-$id" KP_PENDING)
    if [[ -n $pending && $(jq -r .transaction_id <<<"$inspected") == "$pending" && $(jq -r .transaction <<<"$inspected") == committed ]]; then
        info "CT $id completed a guest transaction whose host record was not saved."
        confirm 'Reconcile the completed transaction first' n || return 1
        kp_host_lock "$id" && kp_host_match "$id" "$KP_IDENTITY" || return 1
        kp_host_save "$id" "$(jq -r .version <<<"$inspected")" "$KP_IDENTITY" "$KP_PREVIEW_FINGERPRINT" "$(jq -r .last_action <<<"$inspected")" || return 1
        KP_STAGE=/run/pve-toolbox-komodo-$pending
        ok 'host records recovered; run the selected operation again'
        return 0
    fi
    if [[ -n $pending ]]; then
        [[ $pending =~ ^[a-f0-9]{32}$ ]] || { warn 'invalid saved transaction identifier'; return 1; }
        info "CT $id has staging from an earlier incomplete or rolled-back attempt."
        confirm 'Clean up that protected staging before a new operation' n || return 1
        kp_host_lock "$id" && kp_host_match "$id" "$KP_IDENTITY" || return 1
        KP_STAGE=/run/pve-toolbox-komodo-$pending
        KP_SAVED=1
        ok 'staging cleanup scheduled; run the selected operation again'
        return 0
    fi
    [[ $layout != unsupported ]] || { warn "unsupported installation: $(kp_display "$(jq -r .reason <<<"$inspected")")"; return 1; }
    if [[ $layout == supported ]]; then
        version=$(jq -r .version <<<"$inspected")
        info "CT $id: $(kp_display "$(jq -r '"Periphery " + .version + ", " + .binary + ", service user " + .service_user' <<<"$inspected")")"
        info "Unit: $(kp_display "$(jq -r .unit <<<"$inspected")")"
        info "Configuration: $(kp_display "$(jq -r '.config_paths | join(", ")' <<<"$inspected")")"
        info 'Connection mode: existing configuration (not inferred or changed).'
        info 'Binary updates preserve existing configuration, identity keys and service customizations.'
        if [[ $action == install ]]; then
            ask_choice choice 'Existing agent action' update update configure
            case $choice in update|configure) action=$choice ;; *) return 1 ;; esac
        fi
        if [[ $action == configure ]]; then
            [[ $(jq '.config_paths|length' <<<"$inspected") == 1 && $(jq -r '.config_paths[0]' <<<"$inspected") == *.toml ]] || { warn 'configuration editing requires one explicit TOML file'; return 1; }
            info 'Configuration editing preserves other settings and identity; Python 3.11+ is required in the guest.'
        fi
        if [[ $(jq -r .owned <<<"$inspected") != true ]]; then
            [[ $action != uninstall ]] || { warn 'only toolbox-owned agents can be uninstalled'; return 1; }
            confirm 'Adopt this existing systemd installation for management' n || return 1
            adopt=true
        fi
    else
        [[ $action == install ]] || { warn 'Periphery is not installed; use install first'; return 1; }
        version=""
        if [[ $(jq -r .retained <<<"$inspected") == true && $(jq '.config_paths|length' <<<"$inspected") == 1 ]]; then
            retained_config=true
            info 'Configuration and agent identity from the previous installation were retained.'
            ask_choice choice 'Retained configuration action' configure configure reuse
            case $choice in
                configure)
                    configure_retained=true
                    info 'Editing retained settings requires Python 3.11+ in the guest; identity and unrelated settings are preserved.' ;;
                reuse) info 'Reinstall will reuse the retained configuration unchanged.' ;;
                *) return 1 ;;
            esac
        fi
    fi
    KP_TRANSACTION=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    [[ $KP_TRANSACTION =~ ^[a-f0-9]{32}$ ]] || return 1
    if [[ $action == install || $action == update ]]; then
        release=$(conf_get "komodo-periphery-$id" KP_VERSION)
        ask_valid release 'Exact stable Periphery v2 version compatible with your Core (e.g. 2.3.3)' "${release:-$version}" kp_valid_release
        [[ -z $version || $release == "$version" ]] || is_newer "$release" "$version" || { warn 'downgrades are unsupported'; return 1; }
        gh_release moghtech/komodo "v$release"
        [[ $GH_TAG == "v$release" ]] && gh_exact_asset periphery-x86_64 || { warn 'release has no unambiguous verified amd64 asset'; return 1; }
        [[ $GH_ASSET_URL == "https://github.com/moghtech/komodo/releases/download/v$release/periphery-x86_64" ]] || { warn 'unexpected release asset URL'; return 1; }
        binary=$KP_WORK/periphery
        curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 -o "$binary" "$GH_ASSET_URL" && verify_sha256 "$binary" "$GH_ASSET_SHA256" || { warn 'release download or checksum verification failed'; return 1; }
        digest=$GH_ASSET_SHA256
    else
        release=$version; digest=$(printf '%064d' 0)
    fi
    : > "$KP_WORK/key"; chmod 0600 "$KP_WORK/key"
    if [[ $action == configure || $configure_retained == true ]]; then
        ask_valid core 'Core URL (HTTP or HTTPS; blank keeps current)' '' kp_valid_core_url_or_blank
        ask_valid name 'Server name in Core (blank keeps current)' '' kp_valid_printable
        ask_choice key_action 'Onboarding key action' keep keep replace remove
        if [[ $key_action == replace ]]; then
            ask_secret key 'Core v2 onboarding key' kp_valid_required_printable
            printf '%s' "$key" > "$KP_WORK/key"; unset key
        fi
    elif [[ $layout == absent && $retained_config == false ]]; then
        ask_valid core 'Core URL (HTTP or HTTPS)' '' kp_valid_core_url
        ask_valid name 'Server name in Core' "ct-$id" kp_valid_required_printable
        ask_secret key 'Core v2 onboarding key' kp_valid_required_printable
        printf '%s' "$key" > "$KP_WORK/key"; unset key
    fi
    info "Node $KP_NODE / CT $id: $action Periphery ${version:-absent} -> $release"
    if [[ $action == configure ]]; then
        info "Core URL: $(kp_display "${core:-keep current}"); server name: $(kp_display "${name:-keep current}"); onboarding key: $key_action"
        info 'Executable and agent identity unchanged. An active service restarts; stopped services remain stopped.'
    elif [[ $retained_config == true ]]; then
        if [[ $configure_retained == true ]]; then
            info "Core URL: $(kp_display "${core:-keep current}"); server name: $(kp_display "${name:-keep current}"); onboarding key: $key_action"
            info 'Reinstall with edited configuration; previous configuration is restored if installation fails.'
        else info 'Reinstall with the retained configuration unchanged.'; fi
        info 'Agent identity is preserved. The reinstalled service will be enabled and started.'
    elif [[ $layout == absent ]]; then info 'New agent: guest root, outbound to Core, inbound disabled; Core can run commands as guest root.'
    else info "Service policy: $(kp_display "$(jq -r '.enabled + "/" + .active' <<<"$inspected")"); existing connection settings preserved."; fi
    if [[ $action == uninstall ]]; then info 'Remove owned binary and service only; retain config, keys, overrides and workloads.'
    elif [[ $action == configure ]]; then info 'Previous configuration will be restored if the restart fails; Core connectivity must be checked separately.'
    else info 'An active agent will briefly stop during replacement; confirm this version is compatible with Core.'; fi
    confirm 'Apply this operation to the selected container' n || { info 'cancelled; guest unchanged'; return 0; }
    kp_host_lock "$id" && kp_host_match "$id" "$KP_IDENTITY" || return 1
    jq -nc --arg action "$action" --arg id "$KP_TRANSACTION" --arg machine "$(jq -r .machine_id <<<"$inspected")" \
        --arg fingerprint "$KP_PREVIEW_FINGERPRINT" --argjson adopt "$adopt" --arg version "$release" --arg digest "$digest" \
        --arg config_fingerprint "$(jq -r '.config_fingerprint // ""' <<<"$inspected")" --arg key_action "$key_action" --argjson configure_retained "$configure_retained" \
        --arg candidate "/run/pve-toolbox-komodo-$KP_TRANSACTION/periphery" --arg core "$core" --arg name "$name" --rawfile key "$KP_WORK/key" \
        '{schema:1,action:$action,transaction_id:$id,machine_id:$machine,expected_fingerprint:$fingerprint,adopt:$adopt,
          version:$version,asset_sha256:$digest,staged_binary:$candidate,core_url:$core,server_name:$name,onboarding_key:$key,
          config_fingerprint:$config_fingerprint,onboarding_key_action:$key_action,configure_retained:$configure_retained}' > "$KP_WORK/request.json" || return 1
    chmod 0600 "$KP_WORK/request.json"
    kp_host_apply "$id" "$KP_WORK/request.json" "$binary" || return 1
    kp_host_save "$id" "$release" "$KP_IDENTITY" "$(jq -r .fingerprint <<<"$KP_OUTCOME_JSON")" "$action" || { warn 'guest operation succeeded but host records failed; rerun to reconcile'; return 1; }
    ok "CT $id: $action completed; Core connectivity unverified. Confirm the server is online in Core."
)
kp_host_status() {
    kp_host_ids || return 1
    ((${#KP_IDS[@]})) || { printf 'no managed containers\n'; return 0; }
    kp_host_require || return 1
    local id failed=0 expected
    for id in "${KP_IDS[@]}"; do
        expected=$(conf_get "komodo-periphery-$id" KP_IDENTITY)
        if ! kp_host_match "$id" "$expected"; then printf 'CT %s: unreachable or identity changed\n' "$id"; failed=1; continue; fi
        printf 'CT %s: %s\n' "$id" "$(jq -r '[.layout,.version,.enabled,.active,.transaction]|join(" / ")' <<<"$KP_INSPECTION_JSON" | tr -d '\000-\037\177')"
        printf 'Core connectivity: unverified\n'
        if [[ $(jq -r .layout <<<"$KP_INSPECTION_JSON") != supported || $(jq -r .active <<<"$KP_INSPECTION_JSON") != active || $(jq -r .transaction <<<"$KP_INSPECTION_JSON") == pending ]]; then failed=1; fi
        if [[ $(state_get "komodo-periphery-$id" fingerprint) != "$(jq -r .fingerprint <<<"$KP_INSPECTION_JSON")" ]]; then printf 'Ownership drift: inspect before updating\n'; failed=1; fi
    done
    return "$failed"
}
kp_host_check() {
    kp_host_ids || return 1
    ((${#KP_IDS[@]})) || { printf 'no managed containers\n'; return 0; }
    kp_host_require || return 1
    local id desired current failed=0
    for id in "${KP_IDS[@]}"; do
        if ! kp_host_match "$id" "$(conf_get "komodo-periphery-$id" KP_IDENTITY)"; then failed=1; continue; fi
        desired=$(conf_get "komodo-periphery-$id" KP_VERSION)
        current=$(jq -r .version <<<"$KP_INSPECTION_JSON")
        if [[ -z $current || ! $desired =~ ^2\.[0-9]+\.[0-9]+$ ]]; then printf 'CT %s: version unavailable or not configured\n' "$id"; failed=1
        elif is_newer "$desired" "$current"; then printf 'update available: CT %s %s -> %s (saved target)\n' "$id" "$current" "$desired"
        else printf 'CT %s: installed %s, selected %s; choose a release with update komodo-periphery\n' "$id" "$current" "$desired"; fi
    done
    return "$failed"
}
kp_host_doctor() {
    local output rc=0
    output=$(kp_host_status 2>&1) || rc=$?
    if [[ $rc == 0 ]]; then doctor_result warn agents 'local service checks complete; Core connectivity unverified' "$output"
    else doctor_result fail agents 'one or more managed agents require attention' "$output"; fi
}
