# shellcheck shell=bash
#
# Read-only coverage, freshness, retention, and storage audit for vzdump jobs.
#
# All Proxmox access goes through read-only `pvesh get` calls. This module does
# not expose a runner and never starts, prunes, restores, or deletes a backup.
# The launcher reads this metadata indirectly, in meta().
# shellcheck disable=SC2034
MODULE_NAME="backup-audit"
MODULE_TITLE="Backup audit"
MODULE_DESC="read-only guest backup coverage, freshness, retention, and storage audit"
MODULE_TAGS="backup audit monitoring"
MODULE_HOST_ONLY=1

BA_CONF_KEYS=(BA_FRESHNESS_HOURS BA_STORAGE_WARN BA_STORAGE_FAIL BA_MIN_KEEP_LAST)
BA_CONFIG_ERROR=""
BA_ARRAY=""

_ba_defaults() {
    : "${BA_FRESHNESS_HOURS:=48}"
    : "${BA_STORAGE_WARN:=85}"
    : "${BA_STORAGE_FAIL:=95}"
    : "${BA_MIN_KEEP_LAST:=2}"
}

_ba_validate_settings() {
    BA_CONFIG_ERROR=""
    [[ $BA_FRESHNESS_HOURS =~ ^[1-9][0-9]*$ ]] \
        || { BA_CONFIG_ERROR="freshness hours must be a positive integer"; return 1; }
    [[ $BA_STORAGE_WARN =~ ^[0-9]+$ && $BA_STORAGE_FAIL =~ ^[0-9]+$ \
        && $BA_STORAGE_WARN -lt $BA_STORAGE_FAIL && $BA_STORAGE_FAIL -le 100 ]] \
        || { BA_CONFIG_ERROR="storage thresholds must satisfy 0 <= warning < failure <= 100"; return 1; }
    [[ $BA_MIN_KEEP_LAST =~ ^[1-9][0-9]*$ ]] \
        || { BA_CONFIG_ERROR="minimum keep-last must be a positive integer"; return 1; }
}

_ba_load_settings() {
    _ba_defaults
    if conf_exists "$MODULE_NAME"; then
        conf_load "$MODULE_NAME"
    fi
    _ba_validate_settings
}

_ba_safe_id() {
    tr '[:upper:]' '[:lower:]' <<<"$1" \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

_ba_get() { # _ba_get <endpoint> [pvesh options...]
    local endpoint=$1
    shift
    pvesh get "$endpoint" "$@" --output-format json
}

_ba_array() { # _ba_array <description> <endpoint> [pvesh options...]
    local description=$1 endpoint=$2 output
    shift 2
    BA_ARRAY=""
    if ! output=$(_ba_get "$endpoint" "$@" 2>&1); then
        doctor_result fail "api.$(_ba_safe_id "$description")" \
            "could not read $description" "$output"
        return 1
    fi
    if ! jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
        doctor_result fail "api.$(_ba_safe_id "$description")" \
            "$description response was not a JSON array"
        return 1
    fi
    BA_ARRAY=$output
}

_ba_relation_json() { # _ba_relation_json <guests-json> <jobs-json>
    jq -cn --argjson guests "$1" --argjson jobs "$2" '
        def ids:
            (. // "") | tostring | split(",")
            | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
            | map(select(length > 0));
        def on: ((.enabled // 1) | tostring) != "0";
        def matches($id): ((.all // 0) | tostring) == "1" or ((.vmid | ids) | index($id));
        [ $guests[]
          | select((.type == "qemu" or .type == "lxc") and ((.template // 0) | tostring) != "1")
          | (.vmid | tostring) as $id
          | [ $jobs[] | select(on and ((.exclude | ids) | index($id))) ] as $excluded
          | [ $jobs[] | select(on and matches($id) and (((.exclude | ids) | index($id)) | not)) ] as $covered
          | [ $jobs[] | select((on | not) and matches($id)) ] as $disabled
          | . + {
              relation: (if ($covered | length) > 0 then "covered"
                         elif ($excluded | length) > 0 then "excluded"
                         elif ($disabled | length) > 0 then "disabled"
                         else "uncovered" end),
              job_ids: (($covered + $excluded + $disabled)
                        | map((.id // .schedule // "unnamed") | tostring) | unique),
              storage_ids: ($covered | map((.storage // "") | tostring)
                            | map(select(length > 0)) | unique)
            }
        ] | sort_by(.node // "", .vmid)
    '
}

_ba_task_stats() { # _ba_task_stats <tasks-json> <vmid> <cutoff>
    jq -cn --argjson tasks "$1" --arg id "$2" --argjson cutoff "$3" '
        [ $tasks[]
          | select(.type == "vzdump" and ((.id // .vmid // "") | tostring) == $id)
        ] as $all
        | {
            last_success: ([ $all[] | select(.status == "OK")
                             | (.endtime // .starttime // 0) ] | max // 0),
            recent_failures: ([ $all[]
                                | select(.status != "OK"
                                         and (.status // "") != ""
                                         and ((.endtime // .starttime // 0) >= $cutoff))
                               ] | length)
          }
    '
}

_ba_check_guest_config() { # _ba_check_guest_config <node> <type> <vmid>
    local node=$1 type=$2 vmid=$3 endpoint output excluded kind
    case $type in
        qemu) kind=qemu ;;
        lxc)  kind=lxc ;;
        *) return 0 ;;
    esac
    endpoint="/nodes/$node/$kind/$vmid/config"
    if ! output=$(_ba_get "$endpoint" 2>&1); then
        doctor_result fail "guest.$vmid.config" \
            "could not inspect guest backup exclusions" "$output"
        return 0
    fi
    if ! jq -e 'type == "object"' <<<"$output" >/dev/null 2>&1; then
        doctor_result fail "guest.$vmid.config" \
            "guest config response was not a JSON object"
        return 0
    fi
    excluded=$(jq -r '
        to_entries
        | map(select(
                ((.key | test("^(ide|sata|scsi|virtio|efidisk|tpmstate)[0-9]+$"))
                 and ((.value | tostring) | test("(^|,)backup=0($|,)")))
                or
                ((.key | test("^mp[0-9]+$"))
                 and (((.value | tostring) | test("(^|,)backup=1($|,)")) | not))
              )
              | .key)
        | join(",")
    ' <<<"$output")
    if [[ -n $excluded ]]; then
        doctor_result warn "guest.$vmid.volumes" \
            "guest has volumes excluded from backup" "$excluded"
    else
        doctor_result pass "guest.$vmid.volumes" \
            "no guest volumes explicitly disable backup"
    fi
}

_ba_retention_good() { # _ba_retention_good <prune-backups value>
    local value=$1 keep_last
    [[ -n $value && $value != null ]] || return 1
    # PVE may expose this property as its usual comma-separated property
    # string or as an object through a future API representation.
    if [[ $value == \{* ]]; then
        jq -e --argjson minimum "$BA_MIN_KEEP_LAST" '
            (([to_entries[] | select(.key | startswith("keep-"))
               | (.value | tonumber? // 0)] | max // 0) >= $minimum)
        ' <<<"$value" >/dev/null 2>&1
        return
    fi
    if [[ $value =~ (^|,)keep-(all|daily|hourly|monthly|weekly|yearly)=([1-9][0-9]*)($|,) ]]; then
        return 0
    fi
    keep_last=$(sed -nE 's/(^|.*,)[[:space:]]*keep-last=([0-9]+)(,.*|$)/\2/p' <<<"$value")
    [[ ${keep_last:-0} -ge $BA_MIN_KEEP_LAST ]]
}

_ba_check_retention() { # _ba_check_retention <jobs-json>
    local row index=0 id value safe
    while IFS= read -r row; do
        index=$((index + 1))
        id=$(jq -r '(.id // .schedule // "unnamed") | tostring' <<<"$row")
        value=$(jq -c '.["prune-backups"] // empty' <<<"$row")
        [[ $value != \"*\" ]] || value=$(jq -r '.["prune-backups"]' <<<"$row")
        safe=$(_ba_safe_id "$id")
        [[ -n $safe ]] || safe=$index
        if _ba_retention_good "$value"; then
            doctor_result pass "job.$safe.retention" \
                "backup job has a retention policy" "$id"
        elif [[ -z $value ]]; then
            doctor_result warn "job.$safe.retention" \
                "backup job has no retention policy" "$id"
        else
            doctor_result warn "job.$safe.retention" \
                "backup job retention is below the configured minimum" "$id: $value"
        fi
    done < <(jq -c '.[] | select(((.enabled // 1) | tostring) != "0")' <<<"$1")
}

_ba_check_storage() { # _ba_check_storage <guest-relations-json>
    local relations=$1 node output row name safe active enabled total used percent
    local -a nodes=() needed=()
    mapfile -t nodes < <(jq -r '[.[].node // empty] | unique[]' <<<"$relations")
    for node in "${nodes[@]}"; do
        mapfile -t needed < <(jq -r --arg node "$node" '
            [ .[] | select(.node == $node and .relation == "covered")
              | .storage_ids[] ] | unique[]
        ' <<<"$relations")
        [[ ${#needed[@]} -gt 0 ]] || continue
        if ! _ba_array "backup storage on $node" "/nodes/$node/storage" --content backup; then
            continue
        fi
        output=$BA_ARRAY
        for name in "${needed[@]}"; do
            safe=$(_ba_safe_id "$node.$name")
            row=$(jq -c --arg name "$name" \
                '[.[] | select((.storage | tostring) == $name)][0] // empty' <<<"$output")
            if [[ -z $row ]]; then
                doctor_result fail "storage.$safe" \
                    "configured backup storage is unavailable on its guest node" "$node:$name"
                continue
            fi
            enabled=$(jq -r '(.enabled // 1) | tostring' <<<"$row")
            active=$(jq -r '(.active // 0) | tostring' <<<"$row")
            total=$(jq -r '(.total // 0) | tonumber? // 0 | floor' <<<"$row")
            used=$(jq -r '(.used // 0) | tonumber? // 0 | floor' <<<"$row")
            if [[ $enabled == 0 || $active != 1 ]]; then
                doctor_result fail "storage.$safe" \
                    "backup storage is unavailable" "$node:$name"
            elif [[ $total -le 0 ]]; then
                doctor_result warn "storage.$safe" \
                    "backup storage capacity is unknown" "$node:$name"
            else
                percent=$((used * 100 / total))
                if [[ $percent -ge $BA_STORAGE_FAIL ]]; then
                    doctor_result fail "storage.$safe" \
                        "backup storage is ${percent}% full" "$node:$name"
                elif [[ $percent -ge $BA_STORAGE_WARN ]]; then
                    doctor_result warn "storage.$safe" \
                        "backup storage is ${percent}% full" "$node:$name"
                else
                    doctor_result pass "storage.$safe" \
                        "backup storage is ${percent}% full" "$node:$name"
                fi
            fi
        done
    done
}

_ba_audit() {
    local guests jobs tasks relations node_inventory guest vmid node type relation detail stats
    local now cutoff last age failures
    local -a nodes=()

    if ! command -v pvesh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        doctor_result unsupported prerequisites "pvesh and jq are required"
        return 0
    fi
    if ! _ba_load_settings; then
        doctor_result fail configuration "backup audit thresholds are invalid" "$BA_CONFIG_ERROR"
        return 0
    fi

    _ba_array "cluster guest inventory" /cluster/resources --type vm || return 0
    guests=$BA_ARRAY
    _ba_array "cluster backup jobs" /cluster/backup || return 0
    jobs=$BA_ARRAY
    relations=$(_ba_relation_json "$guests" "$jobs") || {
        doctor_result fail data.model "could not map guests to backup jobs"
        return 0
    }

    if [[ $(jq 'length' <<<"$relations") -eq 0 ]]; then
        tasks='[]'
    else
        node_inventory=$(jq -c 'map({node: (.node // null)}) | unique_by(.node)' \
            <<<"$relations")
        if ! pve_collect_node_tasks "$node_inventory" --typefilter vzdump --limit 500; then
            doctor_result fail api.cluster-backup-task-history \
                "could not read cluster backup task history" "$PVE_TASKS_ERROR"
            return 0
        fi
        tasks=$PVE_TASKS_JSON
    fi

    mapfile -t nodes < <(jq -r '[.[].node // empty] | unique[]' <<<"$relations")
    if [[ $(jq 'length' <<<"$relations") -eq 0 ]]; then
        doctor_result skipped inventory "no virtual machines or containers were found"
    else
        doctor_result pass inventory \
            "inventoried $(jq 'length' <<<"$relations") guest(s) on ${#nodes[@]} node(s)"
    fi

    now=${BA_NOW_EPOCH:-$(date +%s)}
    cutoff=$((now - BA_FRESHNESS_HOURS * 3600))
    while IFS= read -r guest; do
        vmid=$(jq -r '.vmid | tostring' <<<"$guest")
        node=$(jq -r '.node // "unknown"' <<<"$guest")
        type=$(jq -r '.type' <<<"$guest")
        relation=$(jq -r '.relation' <<<"$guest")
        detail=$(jq -r '.job_ids | join(",")' <<<"$guest")
        case $relation in
            covered)
                doctor_result pass "guest.$vmid.coverage" \
                    "guest is covered by an enabled backup job" "$detail"
                stats=$(_ba_task_stats "$tasks" "$vmid" "$cutoff")
                last=$(jq -r '.last_success' <<<"$stats")
                failures=$(jq -r '.recent_failures' <<<"$stats")
                if [[ $last -le 0 ]]; then
                    doctor_result fail "guest.$vmid.freshness" \
                        "guest has no successful backup in available task history"
                else
                    age=$(((now - last) / 3600))
                    if [[ $last -lt $cutoff ]]; then
                        doctor_result warn "guest.$vmid.freshness" \
                            "last successful backup is ${age}h old" \
                            "limit=${BA_FRESHNESS_HOURS}h"
                    else
                        doctor_result pass "guest.$vmid.freshness" \
                            "last successful backup is ${age}h old"
                    fi
                fi
                if [[ $failures -ge 2 ]]; then
                    doctor_result fail "guest.$vmid.failures" \
                        "$failures backup failures occurred inside the freshness window"
                elif [[ $failures -eq 1 ]]; then
                    doctor_result warn "guest.$vmid.failures" \
                        "one backup failure occurred inside the freshness window"
                else
                    doctor_result pass "guest.$vmid.failures" \
                        "no backup failures occurred inside the freshness window"
                fi
                _ba_check_guest_config "$node" "$type" "$vmid"
                ;;
            excluded)
                doctor_result warn "guest.$vmid.coverage" \
                    "guest is intentionally excluded from an enabled backup job" "$detail"
                ;;
            disabled)
                doctor_result warn "guest.$vmid.coverage" \
                    "guest is covered only by a disabled backup job" "$detail"
                ;;
            uncovered)
                doctor_result fail "guest.$vmid.coverage" \
                    "guest is not covered by any backup job" "$node:$type"
                ;;
        esac
    done < <(jq -c '.[]' <<<"$relations")

    _ba_check_retention "$jobs"
    _ba_check_storage "$relations"
}

module_install() {
    require_root
    require_pve
    _ba_defaults
    if conf_exists "$MODULE_NAME"; then
        conf_load "$MODULE_NAME"
    fi
    pkg_ensure jq:jq

    ask BA_FRESHNESS_HOURS "maximum backup age (hours)" "$BA_FRESHNESS_HOURS"
    ask BA_STORAGE_WARN "storage warning threshold (percent)" "$BA_STORAGE_WARN"
    ask BA_STORAGE_FAIL "storage failure threshold (percent)" "$BA_STORAGE_FAIL"
    ask BA_MIN_KEEP_LAST "minimum keep-last retention" "$BA_MIN_KEEP_LAST"
    _ba_validate_settings || die "invalid backup audit settings: $BA_CONFIG_ERROR"

    conf_set "$MODULE_NAME" BA_FRESHNESS_HOURS "$BA_FRESHNESS_HOURS"
    conf_set "$MODULE_NAME" BA_STORAGE_WARN "$BA_STORAGE_WARN"
    conf_set "$MODULE_NAME" BA_STORAGE_FAIL "$BA_STORAGE_FAIL"
    conf_set "$MODULE_NAME" BA_MIN_KEEP_LAST "$BA_MIN_KEEP_LAST"
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"
    ok "configured read-only backup audit"
    dim "  run: pve-toolbox doctor"
}

module_update() {
    local check_only=0 key value missing=()
    [[ ${1:-} == --check ]] && check_only=1
    conf_exists "$MODULE_NAME" || die "not installed"
    _ba_defaults
    for key in "${BA_CONF_KEYS[@]}"; do
        value=$(conf_get "$MODULE_NAME" "$key")
        [[ -n $value ]] || missing+=("$key")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "backup audit configuration is up to date"
        return 0
    fi
    if [[ $check_only -eq 1 ]]; then
        warn "update available: missing settings ${missing[*]}"
        return 0
    fi
    for key in "${missing[@]}"; do
        conf_set "$MODULE_NAME" "$key" "${!key}"
        ok "added $key"
    done
}

module_status() {
    conf_exists "$MODULE_NAME" || { printf 'not installed'; return 1; }
    printf 'configured, read-only'
}

module_status_long() {
    module_status || return 1
    printf '\n'
    if _ba_load_settings >/dev/null; then
        printf '  freshness  %sh\n' "$BA_FRESHNESS_HOURS"
        printf '  storage    warn %s%%, fail %s%%\n' "$BA_STORAGE_WARN" "$BA_STORAGE_FAIL"
        printf '  retention keep-last >= %s (or a positive calendar rule)\n' "$BA_MIN_KEEP_LAST"
        printf '  audit      pve-toolbox doctor [--json|--quiet]\n'
    else
        printf '  configuration is invalid\n'
        return 1
    fi
}

module_doctor() {
    _ba_audit
}

module_uninstall() {
    require_root
    conf_clear "$MODULE_NAME"
    state_clear "$MODULE_NAME"
    ok "removed backup audit configuration"
}
