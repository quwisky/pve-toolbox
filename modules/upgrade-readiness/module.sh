# shellcheck shell=bash
# Read-only, policy-driven preflight for routine PVE upgrades.
# shellcheck disable=SC2034
MODULE_NAME="upgrade-readiness"
MODULE_TITLE="Upgrade readiness"
MODULE_DESC="read-only PVE upgrade blocker and risk preflight"
MODULE_TAGS="upgrade audit monitoring backup apt"
MODULE_HOST_ONLY=1

UR_CONF_KEYS=(UR_POLICY UR_BACKUP_HOURS UR_MIN_FREE_MB)
UR_JSON=""
UR_ERROR=""

_ur_defaults() {
    : "${UR_POLICY:=pve-9}"
    : "${UR_BACKUP_HOURS:=48}"
    : "${UR_MIN_FREE_MB:=2048}"
}

_ur_module_dir() { cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P; }
_ur_policy_path() { printf '%s/policies/%s.conf' "$(_ur_module_dir)" "$UR_POLICY"; }

_ur_load() {
    local policy
    _ur_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    UR_ERROR=""
    [[ $UR_POLICY =~ ^[a-z0-9][a-z0-9.-]*$ ]] \
        || { UR_ERROR="policy name contains unsupported characters"; return 1; }
    [[ $UR_BACKUP_HOURS =~ ^[1-9][0-9]*$ && $UR_MIN_FREE_MB =~ ^[1-9][0-9]*$ ]] \
        || { UR_ERROR="backup age and free-space threshold must be positive integers"; return 1; }
    policy=$(_ur_policy_path)
    [[ -r $policy && ! -L $policy ]] \
        || { UR_ERROR="release policy is missing or unsafe: $UR_POLICY"; return 1; }
    # Policy files ship with the module and contain only declarative values.
    # shellcheck disable=SC1090
    source "$policy"
    [[ ${UR_POLICY_ID:-} == "$UR_POLICY" && ${UR_EXPECTED_PVE_MAJOR:-} =~ ^[0-9]+$ \
        && -n ${UR_SUPPORTED_SUITES:-} && -n ${UR_OFFICIAL_REPO_HOSTS:-} \
        && -n ${UR_CRITICAL_PATHS:-} ]] \
        || { UR_ERROR="release policy is incomplete or mismatched"; return 1; }
}

_ur_id() { tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'; }

_ur_array() {
    local description=$1 endpoint=$2 output
    shift 2
    UR_JSON=""
    if ! output=$(pvesh get "$endpoint" "$@" --output-format json 2>&1); then
        doctor_result fail "api.$(_ur_id "$description")" "could not read $description" "$output"
        return 1
    fi
    jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1 \
        || { doctor_result fail "api.$(_ur_id "$description")" "$description was not a JSON array"; return 1; }
    UR_JSON=$output
}

_ur_object() {
    local description=$1 endpoint=$2 output
    UR_JSON=""
    if ! output=$(pvesh get "$endpoint" --output-format json 2>&1); then
        doctor_result fail "api.$(_ur_id "$description")" "could not read $description" "$output"
        return 1
    fi
    jq -e 'type == "object"' <<<"$output" >/dev/null 2>&1 \
        || { doctor_result fail "api.$(_ur_id "$description")" "$description was not a JSON object"; return 1; }
    UR_JSON=$output
}

_ur_suite_supported() { [[ " $UR_SUPPORTED_SUITES " == *" $1 "* ]]; }
_ur_host_official() { [[ " $UR_OFFICIAL_REPO_HOSTS " == *" $1 "* ]]; }

_ur_repo_rows() {
    local root=${UR_APT_DIR:-/etc/apt} file line uri suite host
    while IFS= read -r -d '' file; do
        while IFS= read -r line; do
            line=${line%%#*}
            [[ $line =~ ^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]+\][[:space:]]+)?([^[:space:]]+)[[:space:]]+([^[:space:]]+) ]] || continue
            uri=${BASH_REMATCH[3]}; suite=${BASH_REMATCH[4]}
            host=${uri#*://}; host=${host%%/*}
            printf '%s\t%s\t%s\n' "$file" "$host" "$suite"
        done < "$file"
    done < <(find "$root" -type f -name '*.list' -print0 2>/dev/null)
    while IFS= read -r -d '' file; do
        uri=""; suite=""
        while IFS= read -r line || [[ -n $line ]]; do
            case $line in
                URIs:*) uri=${line#URIs:}; uri=${uri## } ;;
                Suites:*) suite=${line#Suites:}; suite=${suite## } ;;
                '')
                    if [[ -n $uri && -n $suite ]]; then
                        host=${uri%% *}; host=${host#*://}; host=${host%%/*}
                        printf '%s\t%s\t%s\n' "$file" "$host" "${suite%% *}"
                    fi
                    uri=""; suite="" ;;
            esac
        done < <(awk '1; END { print "" }' "$file")
    done < <(find "$root" -type f -name '*.sources' -print0 2>/dev/null)
}

_ur_check_repositories() {
    local rows row file host suite count=0
    rows=$(_ur_repo_rows)
    while IFS=$'\t' read -r file host suite; do
        [[ -n $host ]] || continue
        count=$((count + 1))
        if _ur_host_official "$host"; then
            if _ur_suite_supported "$suite"; then
                doctor_result pass "repository.$count" "official repository uses a supported suite" "$host $suite"
            else
                doctor_result fail "repository.$count" "official repository uses an unsupported suite" \
                    "$host suite=$suite; migrate it to: $UR_SUPPORTED_SUITES"
            fi
        else
            doctor_result warn "repository.$count" "unknown third-party repository needs operator review" \
                "$host suite=$suite file=$file; confirm vendor support before upgrading"
        fi
    done <<<"$rows"
    [[ $count -gt 0 ]] || doctor_result fail repositories "no enabled APT repositories were found"
}

_ur_check_holds() {
    local holds
    if ! holds=$(dpkg --get-selections 2>/dev/null | awk '$2 == "hold" { print $1 }'); then
        doctor_result fail packages.holds "could not inspect held packages"
    elif [[ -n $holds ]]; then
        doctor_result fail packages.holds "held packages can block the upgrade" "$holds; review with apt-mark showhold"
    else
        doctor_result pass packages.holds "no held packages"
    fi
}

_ur_check_reboot() {
    if [[ -e ${UR_REBOOT_FILE:-/var/run/reboot-required} ]]; then
        doctor_result fail reboot.pending "a reboot is pending" "reboot before starting the upgrade"
    else
        doctor_result pass reboot.pending "no pending reboot marker"
    fi
}

_ur_check_space() {
    local path row available id
    for path in $UR_CRITICAL_PATHS; do
        if ! row=$(df -Pm -- "$path" 2>/dev/null | awk 'NR == 2 { print $4 }'); then row=""; fi
        id=$(_ur_id "$path"); [[ -n $id ]] || id=root
        if [[ ! $row =~ ^[0-9]+$ ]]; then
            doctor_result fail "space.$id" "could not determine free space" "$path"
        else
            available=$row
            if [[ $available -lt $UR_MIN_FREE_MB ]]; then
                doctor_result fail "space.$id" "critical filesystem has insufficient free space" \
                    "$path free=${available}MiB required=${UR_MIN_FREE_MB}MiB"
            else
                doctor_result pass "space.$id" "critical filesystem has upgrade headroom" \
                    "$path free=${available}MiB"
            fi
        fi
    done
}

_ur_check_nodes() {
    local nodes=$1 node version versions="" services storage stopped inactive
    local -A seen_versions=()
    while IFS= read -r node; do
        if _ur_object "node $node status" "/nodes/$node/status"; then
            doctor_result pass "node.$(_ur_id "$node").reachability" "node API is reachable"
        else
            doctor_result fail "node.$(_ur_id "$node").reachability" "node is unavailable; do not upgrade the cluster"
            continue
        fi
        if _ur_object "node $node version" "/nodes/$node/version"; then
            version=$(jq -r '.version // .release // "unknown"' <<<"$UR_JSON")
            versions+="$node=$version "
            seen_versions["$version"]=1
            if [[ $version == "$UR_EXPECTED_PVE_MAJOR".* ]]; then
                doctor_result pass "node.$(_ur_id "$node").version" "node runs the policy PVE major" "$version"
            else
                doctor_result fail "node.$(_ur_id "$node").version" "node version is outside the PVE policy" \
                    "found=$version expected=$UR_EXPECTED_PVE_MAJOR.x"
            fi
        fi
        if _ur_array "node $node failed services" "/nodes/$node/services" --state stopped; then
            services=$UR_JSON
            stopped=$(jq -r '[.[] | select(.state == "failed" or .status == "failed") | .name] | join(",")' <<<"$services")
            [[ -z $stopped ]] && doctor_result pass "node.$(_ur_id "$node").services" "no failed services" \
                || doctor_result fail "node.$(_ur_id "$node").services" "node has failed services" "$stopped"
        fi
        if _ur_array "node $node storage" "/nodes/$node/storage"; then
            storage=$UR_JSON
            inactive=$(jq -r '[.[] | select((.enabled // 1) == 1 and (.active // 0) != 1) | .storage] | join(",")' <<<"$storage")
            [[ -z $inactive ]] && doctor_result pass "node.$(_ur_id "$node").storage" "enabled storage is active" \
                || doctor_result fail "node.$(_ur_id "$node").storage" "enabled storage is inactive" "$inactive"
        fi
    done < <(jq -r '.[].node' <<<"$nodes")
    if [[ ${#seen_versions[@]} -gt 1 ]]; then
        doctor_result warn cluster.versions "cluster nodes have version skew" \
            "$versions; align patch versions before upgrading when practical"
    elif [[ -n $versions ]]; then
        doctor_result pass cluster.versions "reachable cluster nodes run the same version" "$versions"
    fi
}

_ur_check_backups() {
    local nodes=$1 guests tasks now cutoff guest vmid last age
    _ur_array "cluster guest inventory" /cluster/resources --type vm || return 0
    guests=$UR_JSON
    if ! pve_collect_node_tasks "$nodes" --typefilter vzdump --limit 500; then
        doctor_result fail api.cluster-backup-task-history \
            "could not read cluster backup task history" "$PVE_TASKS_ERROR"
        return 0
    fi
    tasks=$PVE_TASKS_JSON
    now=${UR_NOW_EPOCH:-$(date +%s)}; cutoff=$((now - UR_BACKUP_HOURS * 3600))
    while IFS= read -r guest; do
        vmid=$(jq -r '.vmid | tostring' <<<"$guest")
        last=$(jq -r --arg id "$vmid" '[.[] | select(.type == "vzdump" and .status == "OK"
          and ((.id // .vmid // "") | tostring) == $id) | (.endtime // .starttime // 0)] | max // 0' <<<"$tasks")
        if [[ $last -lt $cutoff ]]; then
            doctor_result fail "backup.$vmid" "guest lacks a sufficiently recent successful backup" \
                "policy=${UR_BACKUP_HOURS}h; run or verify a backup before upgrading"
        else
            age=$(((now - last) / 3600))
            doctor_result pass "backup.$vmid" "guest has a recent successful backup" "age=${age}h"
        fi
    done < <(jq -c '.[] | select(.type == "qemu" or .type == "lxc") | select((.template // 0) != 1)' <<<"$guests")
}

_ur_audit() {
    local nodes
    for command in pvesh jq dpkg df; do
        command -v "$command" >/dev/null 2>&1 \
            || { doctor_result unsupported prerequisites "$command is required"; return 0; }
    done
    _ur_load || { doctor_result fail configuration "upgrade policy is invalid" "$UR_ERROR"; return 0; }
    doctor_result pass policy "loaded release-specific upgrade policy" "$UR_POLICY"
    _ur_check_repositories
    _ur_check_holds
    _ur_check_reboot
    _ur_check_space
    _ur_array "cluster node inventory" /nodes || return 0
    nodes=$UR_JSON
    _ur_check_nodes "$nodes"
    _ur_check_backups "$nodes"
}

module_install() {
    require_root; require_pve; _ur_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    pkg_ensure jq:jq
    ask UR_POLICY "upgrade policy" "$UR_POLICY"
    ask UR_BACKUP_HOURS "maximum backup age (hours)" "$UR_BACKUP_HOURS"
    ask UR_MIN_FREE_MB "minimum free space (MiB)" "$UR_MIN_FREE_MB"
    _ur_load || die "$UR_ERROR"
    local key; for key in "${UR_CONF_KEYS[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"
    ok "configured read-only $UR_POLICY upgrade preflight"
}

module_update() {
    local check_only=0 key missing=(); [[ ${1:-} == --check ]] && check_only=1
    conf_exists "$MODULE_NAME" || die "not installed"; _ur_defaults
    for key in "${UR_CONF_KEYS[@]}"; do [[ -n $(conf_get "$MODULE_NAME" "$key") ]] || missing+=("$key"); done
    [[ ${#missing[@]} -gt 0 ]] || { ok "upgrade readiness configuration is up to date"; return 0; }
    [[ $check_only -eq 0 ]] || { warn "update available: missing settings ${missing[*]}"; return 0; }
    for key in "${missing[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    ok "added missing upgrade readiness settings"
}

module_status() { conf_exists "$MODULE_NAME" || { printf 'not installed'; return 1; }; printf 'configured, read-only'; }
module_status_long() { module_status || return 1; printf '\n'; _ur_load && printf '  policy %s; backups %sh; free space %sMiB\n' "$UR_POLICY" "$UR_BACKUP_HOURS" "$UR_MIN_FREE_MB"; }
module_doctor() { _ur_audit; }
module_uninstall() { require_root; conf_clear "$MODULE_NAME"; state_clear "$MODULE_NAME"; ok "removed upgrade readiness configuration; no host setting was changed"; }
