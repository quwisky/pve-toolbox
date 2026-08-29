# shellcheck shell=bash
#
# Read-only snapshot, volume ownership, content age, and capacity audit.
# shellcheck disable=SC2034
MODULE_NAME="storage-hygiene"
MODULE_TITLE="Storage hygiene"
MODULE_DESC="read-only snapshots, unreferenced volumes, stale content, and capacity audit"
MODULE_TAGS="storage audit monitoring zfs lvm"
MODULE_HOST_ONLY=1

SH_CONF_KEYS=(
    SH_SNAPSHOT_DAYS SH_CONTENT_DAYS SH_CAPACITY_WARN SH_CAPACITY_FAIL
    SH_THIN_WARN SH_THIN_FAIL
)
SH_JSON=""
SH_ERROR=""

_sh_defaults() {
    : "${SH_SNAPSHOT_DAYS:=30}"
    : "${SH_CONTENT_DAYS:=180}"
    : "${SH_CAPACITY_WARN:=85}"
    : "${SH_CAPACITY_FAIL:=95}"
    : "${SH_THIN_WARN:=80}"
    : "${SH_THIN_FAIL:=95}"
}

_sh_validate() {
    SH_ERROR=""
    [[ $SH_SNAPSHOT_DAYS =~ ^[1-9][0-9]*$ ]] \
        || { SH_ERROR="snapshot age must be a positive number of days"; return 1; }
    [[ $SH_CONTENT_DAYS =~ ^[1-9][0-9]*$ ]] \
        || { SH_ERROR="content age must be a positive number of days"; return 1; }
    [[ $SH_CAPACITY_WARN =~ ^[0-9]+$ && $SH_CAPACITY_FAIL =~ ^[0-9]+$ \
        && $SH_CAPACITY_WARN -lt $SH_CAPACITY_FAIL && $SH_CAPACITY_FAIL -le 100 ]] \
        || { SH_ERROR="capacity thresholds must satisfy 0 <= warning < failure <= 100"; return 1; }
    [[ $SH_THIN_WARN =~ ^[0-9]+$ && $SH_THIN_FAIL =~ ^[0-9]+$ \
        && $SH_THIN_WARN -lt $SH_THIN_FAIL && $SH_THIN_FAIL -le 100 ]] \
        || { SH_ERROR="thin-pool thresholds must satisfy 0 <= warning < failure <= 100"; return 1; }
}

_sh_load() {
    _sh_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    _sh_validate
}

_sh_id() {
    tr '[:upper:]' '[:lower:]' <<<"$1" \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

_sh_array() { # _sh_array <description> <endpoint> [options...]
    local description=$1 endpoint=$2 output
    shift 2
    SH_JSON=""
    if ! output=$(pvesh get "$endpoint" "$@" --output-format json 2>&1); then
        doctor_result fail "api.$(_sh_id "$description")" "could not read $description" "$output"
        return 1
    fi
    if ! jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
        doctor_result fail "api.$(_sh_id "$description")" "$description response was not a JSON array"
        return 1
    fi
    SH_JSON=$output
}

_sh_object() { # _sh_object <description> <endpoint>
    local description=$1 endpoint=$2 output
    SH_JSON=""
    if ! output=$(pvesh get "$endpoint" --output-format json 2>&1); then
        doctor_result warn "api.$(_sh_id "$description")" "could not inspect $description" "$output"
        return 1
    fi
    if ! jq -e 'type == "object"' <<<"$output" >/dev/null 2>&1; then
        doctor_result warn "api.$(_sh_id "$description")" "$description response was not a JSON object"
        return 1
    fi
    SH_JSON=$output
}

_sh_percent_result() { # _sh_percent_result <id> <label> <percent> <evidence>
    local id=$1 label=$2 percent=$3 evidence=$4
    if [[ $percent -ge $SH_CAPACITY_FAIL ]]; then
        doctor_result fail "$id" "$label is ${percent}% used" "$evidence"
    elif [[ $percent -ge $SH_CAPACITY_WARN ]]; then
        doctor_result warn "$id" "$label is ${percent}% used" "$evidence"
    else
        doctor_result pass "$id" "$label is ${percent}% used" "$evidence"
    fi
}

_sh_guest_inventory() { # sets SH_GUESTS SH_REFS SH_UNUSED SH_NODES
    local guest vmid node type endpoint config snapshots snap name stamp age key value
    local now snapshot_cutoff
    SH_GUESTS=$1
    SH_REFS='[]'
    SH_UNUSED='[]'
    SH_NODES=$2
    now=${SH_NOW_EPOCH:-$(date +%s)}
    snapshot_cutoff=$((now - SH_SNAPSHOT_DAYS * 86400))

    while IFS= read -r guest; do
        vmid=$(jq -r '.vmid | tostring' <<<"$guest")
        node=$(jq -r '.node // "unknown"' <<<"$guest")
        type=$(jq -r '.type' <<<"$guest")
        SH_NODES=$(jq -cn --argjson nodes "$SH_NODES" --arg node "$node" '$nodes + [$node] | unique')
        case $type in qemu|lxc) ;; *) continue ;; esac
        endpoint="/nodes/$node/$type/$vmid"
        if _sh_object "guest $vmid config" "$endpoint/config"; then
            config=$SH_JSON
            while IFS=$'\t' read -r key value; do
                [[ -n $value ]] || continue
                if [[ $key == unused* ]]; then
                    SH_UNUSED=$(jq -cn --argjson refs "$SH_UNUSED" --arg value "$value" '$refs + [$value] | unique')
                else
                    SH_REFS=$(jq -cn --argjson refs "$SH_REFS" --arg value "$value" '$refs + [$value] | unique')
                fi
            done < <(jq -r '
                to_entries[]
                | select(.key | test("^(ide|sata|scsi|virtio|efidisk|tpmstate|unused|mp|rootfs)[0-9]*$"))
                | [.key, ((.value | tostring) | split(",")[0])] | @tsv
            ' <<<"$config")
        fi
        if ! _sh_array "guest $vmid snapshots" "$endpoint/snapshot"; then
            continue
        fi
        snapshots=$SH_JSON
        while IFS= read -r snap; do
            name=$(jq -r '.name // "unnamed"' <<<"$snap")
            [[ $name != current ]] || continue
            stamp=$(jq -r '(.snaptime // 0) | tonumber? // 0 | floor' <<<"$snap")
            if [[ $stamp -le 0 ]]; then
                doctor_result warn "guest.$vmid.snapshot.$(_sh_id "$name")" \
                    "snapshot age is unknown" "node=$node snapshot=$name missing snaptime"
            elif [[ $stamp -lt $snapshot_cutoff ]]; then
                age=$(((now - stamp) / 86400))
                doctor_result warn "guest.$vmid.snapshot.$(_sh_id "$name")" \
                    "snapshot is ${age} days old" "node=$node snapshot=$name created=$stamp"
            fi
        done < <(jq -c '.[]' <<<"$snapshots")
    done < <(jq -c '.[] | select((.type == "qemu" or .type == "lxc") and ((.template // 0) | tostring) != "1")' <<<"$1")
}

_sh_storage_definitions() { # _sh_storage_definitions <json>
    local duplicates group signature ids
    duplicates=$(jq -c '
        map(select(((.disable // 0) | tostring) != "1")
            | . + {signature: ([.type // "", .path // "", .pool // "", .vgname // "",
                                .thinpool // "", .server // "", .share // "", .portal // ""]
                               | map(tostring) | join("|"))})
        | sort_by(.signature) | group_by(.signature) | map(select(length > 1))
    ' <<<"$1")
    while IFS= read -r group; do
        signature=$(jq -r '.[0].signature' <<<"$group")
        ids=$(jq -r 'map(.storage) | join(",")' <<<"$group")
        doctor_result warn "definition.duplicate.$(_sh_id "$ids")" \
            "storage definitions have the same backend signature" "ids=$ids signature=$signature"
    done < <(jq -c '.[]' <<<"$duplicates")
    while IFS= read -r group; do
        ids=$(jq -r '.storage' <<<"$group")
        if [[ $(jq -r '(.disable // 0) | tostring' <<<"$group") == 1 ]]; then
            doctor_result warn "definition.$(_sh_id "$ids").disabled" \
                "storage definition is disabled" "storage=$ids type=$(jq -r '.type // "unknown"' <<<"$group")"
        fi
    done < <(jq -c '.[]' <<<"$1")
}

_sh_storage_status() { # _sh_storage_status <nodes-json>
    local node row id enabled active total used percent
    while IFS= read -r node; do
        if ! _sh_array "storage status on $node" "/nodes/$node/storage"; then continue; fi
        while IFS= read -r row; do
            id=$(jq -r '.storage // "unknown"' <<<"$row")
            enabled=$(jq -r '(.enabled // 1) | tostring' <<<"$row")
            active=$(jq -r '(.active // 0) | tostring' <<<"$row")
            if [[ $enabled == 0 || $active != 1 ]]; then
                doctor_result fail "storage.$(_sh_id "$node.$id").availability" \
                    "storage is unavailable" "node=$node storage=$id enabled=$enabled active=$active"
                continue
            fi
            total=$(jq -r '(.total // 0) | tonumber? // 0 | floor' <<<"$row")
            used=$(jq -r '(.used // 0) | tonumber? // 0 | floor' <<<"$row")
            if [[ $total -gt 0 ]]; then
                percent=$((used * 100 / total))
                _sh_percent_result "storage.$(_sh_id "$node.$id").capacity" \
                    "storage $node:$id" "$percent" "used=$used total=$total"
            else
                doctor_result warn "storage.$(_sh_id "$node.$id").capacity" \
                    "storage capacity is unknown" "node=$node storage=$id total=$total"
            fi
        done < <(jq -c '.[]' <<<"$SH_JSON")
    done < <(jq -r '.[]' <<<"$1")
}

_sh_content() { # _sh_content <definitions-json> <nodes-json>
    local definition storage allowed node content row volid kind ctime age now vmid evidence
    now=${SH_NOW_EPOCH:-$(date +%s)}
    while IFS= read -r definition; do
        storage=$(jq -r '.storage' <<<"$definition")
        allowed=$(jq -r '.nodes // ""' <<<"$definition")
        [[ $(jq -r '(.disable // 0) | tostring' <<<"$definition") != 1 ]] || continue
        while IFS= read -r node; do
            if [[ -n $allowed && ",$allowed," != *",$node,"* ]]; then continue; fi
            if ! _sh_array "content $node $storage" "/nodes/$node/storage/$storage/content"; then
                doctor_result warn "content.$(_sh_id "$node.$storage").unknown" \
                    "storage content ownership is unknown" "node=$node storage=$storage listing failed"
                continue
            fi
            content=$SH_JSON
            while IFS= read -r row; do
                volid=$(jq -r '.volid // "unknown"' <<<"$row")
                kind=$(jq -r '.content // "unknown"' <<<"$row")
                case $kind in
                    images|rootdir)
                        jq -e --arg volid "$volid" 'index($volid) != null' <<<"$SH_REFS" >/dev/null && continue
                        if jq -e --arg volid "$volid" 'index($volid) != null' <<<"$SH_UNUSED" >/dev/null; then
                            doctor_result warn "volume.$(_sh_id "$volid").unused-config" \
                                "volume is listed as unused in a guest config" \
                                "node=$node storage=$storage volid=$volid verify guest unused-disk entries"
                            continue
                        fi
                        vmid=$(jq -r '(.vmid // 0) | tostring' <<<"$row")
                        if [[ $vmid == 0 && $volid =~ (vm|subvol)-([0-9]+)- ]]; then vmid=${BASH_REMATCH[2]}; fi
                        evidence="node=$node storage=$storage volid=$volid not referenced by inventoried guest configs"
                        if [[ $vmid != 0 ]] && ! jq -e --arg vmid "$vmid" \
                            'any(.[]; (.vmid | tostring) == $vmid)' <<<"$SH_GUESTS" >/dev/null; then
                            doctor_result warn "volume.$(_sh_id "$volid").orphan-candidate" \
                                "volume owner VMID does not exist" "$evidence owner-vmid=$vmid"
                        else
                            doctor_result warn "volume.$(_sh_id "$volid").ownership-unknown" \
                                "volume is not referenced by an active config; ownership is unknown" \
                                "$evidence snapshots, replication, or external tooling may own it"
                        fi
                        ;;
                    iso|vztmpl)
                        ctime=$(jq -r '(.ctime // 0) | tonumber? // 0 | floor' <<<"$row")
                        [[ $ctime -gt 0 ]] || continue
                        age=$(((now - ctime) / 86400))
                        if [[ $age -ge $SH_CONTENT_DAYS ]]; then
                            doctor_result warn "content.$(_sh_id "$volid").stale" \
                                "$kind content is ${age} days old" \
                                "node=$node storage=$storage volid=$volid ctime=$ctime"
                        fi
                        ;;
                esac
            done < <(jq -c '.[]' <<<"$content")
        done < <(jq -r '.[]' <<<"$2")
    done < <(jq -c '.[]' <<<"$1")
}

_sh_inode_usage() { # _sh_inode_usage <definitions-json>
    local definition storage path line total used percent
    command -v df >/dev/null 2>&1 || return 0
    while IFS= read -r definition; do
        storage=$(jq -r '.storage' <<<"$definition")
        path=$(jq -r '.path // empty' <<<"$definition")
        [[ -n $path && -d $path ]] || continue
        line=$(df -Pi -- "$path" 2>/dev/null | tail -n1) || continue
        read -r _ total used _ _ _ <<<"$line"
        [[ $total =~ ^[0-9]+$ && $total -gt 0 ]] || continue
        percent=$((used * 100 / total))
        _sh_percent_result "inode.$(_sh_id "$storage")" "inode use for $storage" \
            "$percent" "path=$path used=$used total=$total"
    done < <(jq -c '.[] | select(.type == "dir")' <<<"$1")
}

_sh_zfs() {
    local output row name type used available leaf vmid evidence
    command -v zfs >/dev/null 2>&1 || { doctor_result skipped zfs "ZFS inventory is not available"; return 0; }
    if ! output=$(zfs list -Hp -o name,type,used,available 2>&1); then
        doctor_result warn zfs "could not read ZFS dataset inventory" "$output"
        return 0
    fi
    while IFS=$'\t' read -r name type used available; do
        leaf=${name##*/}
        [[ $leaf =~ ^(vm|subvol)-([0-9]+)- ]] || continue
        vmid=${BASH_REMATCH[2]}
        evidence="dataset=$name type=$type used=$used available=$available no matching PVE volume reference"
        if jq -e --arg leaf "$leaf" 'any(.[]; endswith(":" + $leaf))' <<<"$SH_REFS" >/dev/null; then
            continue
        elif jq -e --arg vmid "$vmid" 'any(.[]; (.vmid | tostring) == $vmid)' <<<"$SH_GUESTS" >/dev/null; then
            doctor_result warn "zfs.$(_sh_id "$name").ownership-unknown" \
                "ZFS object is unreferenced; ownership is unknown" "$evidence owner VMID exists"
        else
            doctor_result warn "zfs.$(_sh_id "$name").orphan-candidate" \
                "ZFS object owner VMID does not exist" "$evidence owner-vmid=$vmid"
        fi
    done <<<"$output"
}

_sh_lvm() {
    local output row vg pool data meta max value evidence
    command -v lvs >/dev/null 2>&1 || { doctor_result skipped lvm-thin "LVM inventory is not available"; return 0; }
    if ! output=$(lvs --reportformat json --units b --nosuffix \
        -o vg_name,lv_name,lv_attr,data_percent,metadata_percent 2>&1); then
        doctor_result warn lvm-thin "could not read LVM thin-pool inventory" "$output"
        return 0
    fi
    if ! jq -e '.report | type == "array"' <<<"$output" >/dev/null 2>&1; then
        doctor_result warn lvm-thin "LVM inventory was not valid JSON"
        return 0
    fi
    while IFS= read -r row; do
        vg=$(jq -r '.vg_name | gsub("^[[:space:]]+|[[:space:]]+$"; "")' <<<"$row")
        pool=$(jq -r '.lv_name | gsub("^[[:space:]]+|[[:space:]]+$"; "")' <<<"$row")
        data=$(jq -r '(.data_percent // "0") | tonumber? // 0 | floor' <<<"$row")
        meta=$(jq -r '(.metadata_percent // "0") | tonumber? // 0 | floor' <<<"$row")
        max=$data; [[ $meta -le $max ]] || max=$meta
        value=pass
        [[ $max -lt $SH_THIN_WARN ]] || value=warn
        [[ $max -lt $SH_THIN_FAIL ]] || value=fail
        evidence="vg=$vg pool=$pool data=${data}% metadata=${meta}%"
        doctor_result "$value" "lvm-thin.$(_sh_id "$vg.$pool")" \
            "thin pool data=${data}% metadata=${meta}%" "$evidence"
    done < <(jq -c '.report[].lv[] | select((.lv_attr // "") | startswith("t"))' <<<"$output")
}

_sh_audit() {
    local guests definitions node_records nodes
    if ! command -v pvesh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        doctor_result unsupported prerequisites "pvesh and jq are required"
        return 0
    fi
    if ! _sh_load; then
        doctor_result fail configuration "storage hygiene thresholds are invalid" "$SH_ERROR"
        return 0
    fi
    _sh_array "cluster guest inventory" /cluster/resources --type vm || return 0
    guests=$SH_JSON
    _sh_array "cluster node inventory" /nodes || return 0
    node_records=$SH_JSON
    nodes=$(jq -c '[.[].node // empty] | unique' <<<"$node_records")
    _sh_array "storage definitions" /storage || return 0
    definitions=$SH_JSON
    _sh_guest_inventory "$guests" "$nodes"
    doctor_result pass inventory \
        "inventoried $(jq 'length' <<<"$guests") guest records and $(jq 'length' <<<"$definitions") storage definitions"
    _sh_storage_definitions "$definitions"
    _sh_storage_status "$SH_NODES"
    _sh_content "$definitions" "$SH_NODES"
    _sh_inode_usage "$definitions"
    _sh_zfs
    _sh_lvm
}

module_install() {
    require_root
    require_pve
    _sh_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    pkg_ensure jq:jq
    ask SH_SNAPSHOT_DAYS "snapshot warning age (days)" "$SH_SNAPSHOT_DAYS"
    ask SH_CONTENT_DAYS "ISO/template warning age (days)" "$SH_CONTENT_DAYS"
    ask SH_CAPACITY_WARN "capacity warning threshold" "$SH_CAPACITY_WARN"
    ask SH_CAPACITY_FAIL "capacity failure threshold" "$SH_CAPACITY_FAIL"
    ask SH_THIN_WARN "thin-pool warning threshold" "$SH_THIN_WARN"
    ask SH_THIN_FAIL "thin-pool failure threshold" "$SH_THIN_FAIL"
    _sh_validate || die "$SH_ERROR"
    local key
    for key in "${SH_CONF_KEYS[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"
    ok "configured read-only storage hygiene audit"
}

module_update() {
    local check_only=0 key missing=()
    [[ ${1:-} == --check ]] && check_only=1
    conf_exists "$MODULE_NAME" || die "not installed"
    _sh_defaults
    for key in "${SH_CONF_KEYS[@]}"; do
        [[ -n $(conf_get "$MODULE_NAME" "$key") ]] || missing+=("$key")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then ok "storage hygiene configuration is up to date"; return 0; fi
    if [[ $check_only -eq 1 ]]; then warn "update available: missing settings ${missing[*]}"; return 0; fi
    for key in "${missing[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    ok "added missing storage hygiene settings"
}

module_status() {
    conf_exists "$MODULE_NAME" || { printf 'not installed'; return 1; }
    printf 'configured, read-only'
}

module_status_long() {
    module_status || return 1
    printf '\n'
    if _sh_load; then
        printf '  snapshots  warn after %sd\n' "$SH_SNAPSHOT_DAYS"
        printf '  content    warn after %sd\n' "$SH_CONTENT_DAYS"
        printf '  capacity   warn %s%%, fail %s%%\n' "$SH_CAPACITY_WARN" "$SH_CAPACITY_FAIL"
        printf '  thin pool  warn %s%%, fail %s%%\n' "$SH_THIN_WARN" "$SH_THIN_FAIL"
        printf '  cleanup    never automatic\n'
    else
        printf '  configuration invalid\n'
        return 1
    fi
}

module_doctor() { _sh_audit; }

module_uninstall() {
    require_root
    conf_clear "$MODULE_NAME"
    state_clear "$MODULE_NAME"
    ok "removed storage hygiene audit configuration; no storage was changed"
}
