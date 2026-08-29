# shellcheck shell=bash
#
# lib/doctor.sh - read-only host health checks and result aggregation.
#
# The launcher sources this after common.sh. Modules may optionally implement
# module_doctor and call doctor_result; the launcher runs that function in the
# usual isolated subshell and imports only validated result records.
#
[[ -n ${_TOOLBOX_DOCTOR_LOADED:-} ]] && return 0
_TOOLBOX_DOCTOR_LOADED=1

DOCTOR_RECORD_MARKER="PVE_TOOLBOX_DOCTOR"

doctor_reset() {
    report_reset doctor
}

# doctor_result <pass|warn|fail|skipped|unsupported> <id> <summary> [detail]
#
# In the launcher process this appends to the result arrays. In an isolated
# module process DOCTOR_EMIT=1 turns it into a private, validated wire record.
doctor_result() {
    [[ $# -ge 3 && $# -le 4 ]] || return 2
    local state=$1 id=$2 summary=$3 detail=${4:-}
    case $state in
        pass|warn|fail|skipped|unsupported) ;;
        *) return 2 ;;
    esac
    [[ $id =~ ^[a-z0-9][a-z0-9._-]*$ ]] || return 2
    [[ -n $summary ]] || return 2

    if [[ -n ${DOCTOR_PREFIX:-} ]]; then
        id="${DOCTOR_PREFIX}${id}"
    fi

    if [[ ${DOCTOR_EMIT:-0} -eq 1 ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$DOCTOR_RECORD_MARKER" "$state" "$id" "$summary" "$detail"
        return 0
    fi

    report_add "$state" "$id" "$summary" "$detail"
}

doctor_import_module() { # doctor_import_module <module> <exit-status> <output>
    local module=$1 rc=$2 output=$3 line marker state id summary detail extra
    local valid=0 invalid=0
    local DOCTOR_PREFIX="" DOCTOR_EMIT=0

    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        marker=""; state=""; id=""; summary=""; detail=""; extra=""
        IFS=$'\t' read -r marker state id summary detail extra <<<"$line"
        if [[ $marker != "$DOCTOR_RECORD_MARKER" || -n $extra ]] \
            || ! doctor_result "$state" "$id" "$summary" "$detail"; then
            invalid=1
            continue
        fi
        valid=$((valid + 1))
    done <<<"$output"

    if [[ $invalid -eq 1 ]]; then
        doctor_result fail "module.$module.protocol" \
            "module health check emitted invalid output"
    fi
    if [[ $rc -ne 0 ]]; then
        doctor_result fail "module.$module.runner" \
            "module health check exited with status $rc"
    elif [[ $valid -eq 0 ]]; then
        doctor_result fail "module.$module.protocol" \
            "module health check emitted no results"
    fi
}

doctor_run_check() { # doctor_run_check <id> <function>
    local id=$1 fn=$2 before=${#REPORT_STATES[@]}
    if ! "$fn"; then
        doctor_result fail "$id" "health check execution failed"
    fi
    if [[ ${#REPORT_STATES[@]} -eq $before ]]; then
        doctor_result fail "$id" "health check returned no result"
    fi
}

doctor_check_quorum() {
    local pve_etc=${PVE_TOOLBOX_PVE_ETC:-/etc/pve} output
    if [[ ! -f $pve_etc/corosync.conf ]]; then
        doctor_result pass cluster.quorum "standalone node; cluster quorum is not applicable"
        return
    fi
    if ! command -v pvecm >/dev/null 2>&1; then
        doctor_result unsupported cluster.quorum "pvecm is not available"
        return
    fi
    if ! output=$(pvecm status 2>&1); then
        doctor_result fail cluster.quorum "could not read cluster quorum" "$output"
    elif grep -Eq '^Quorate:[[:space:]]+Yes[[:space:]]*$' <<<"$output"; then
        doctor_result pass cluster.quorum "cluster is quorate"
    else
        doctor_result fail cluster.quorum "cluster is not quorate"
    fi
}

doctor_check_systemd() {
    local output count
    if ! command -v systemctl >/dev/null 2>&1; then
        doctor_result unsupported systemd.failed "systemctl is not available"
        return
    fi
    if ! output=$(systemctl --failed --no-legend --plain --no-pager 2>&1); then
        doctor_result fail systemd.failed "could not query failed systemd units" "$output"
        return
    fi
    output=${output//$'\r'/}
    count=$(grep -c '[^[:space:]]' <<<"$output" || true)
    if [[ $count -eq 0 ]]; then
        doctor_result pass systemd.failed "no failed systemd units"
    else
        doctor_result fail systemd.failed "$count systemd unit(s) failed" "$output"
    fi
}

doctor_check_zfs() {
    local output line name health
    local -a unhealthy=()
    if ! command -v zpool >/dev/null 2>&1; then
        doctor_result skipped zfs.pools "ZFS is not installed"
        return
    fi
    if ! output=$(zpool list -H -o name,health 2>&1); then
        doctor_result fail zfs.pools "could not read ZFS pool health" "$output"
        return
    fi
    if [[ -z $output ]]; then
        doctor_result skipped zfs.pools "no ZFS pools are configured"
        return
    fi
    while IFS= read -r line; do
        read -r name health <<<"$line"
        [[ $health == ONLINE ]] || unhealthy+=("$name:$health")
    done <<<"$output"
    if [[ ${#unhealthy[@]} -eq 0 ]]; then
        doctor_result pass zfs.pools "all ZFS pools are online"
    else
        doctor_result fail zfs.pools "${#unhealthy[@]} ZFS pool(s) are unhealthy" \
            "${unhealthy[*]}"
    fi
}

doctor_check_storage() {
    local warn_at=${PVE_TOOLBOX_DOCTOR_STORAGE_WARN:-85}
    local fail_at=${PVE_TOOLBOX_DOCTOR_STORAGE_FAIL:-95}
    local output line name status percent value last detail
    local -a columns=() warnings=() failures=() disabled=()
    local seen=0

    if [[ ! $warn_at =~ ^[0-9]+$ || ! $fail_at =~ ^[0-9]+$ \
        || $warn_at -ge $fail_at || $fail_at -gt 100 ]]; then
        doctor_result fail storage.capacity "invalid storage thresholds" \
            "warning=$warn_at failure=$fail_at"
        return
    fi
    if ! command -v pvesm >/dev/null 2>&1; then
        doctor_result unsupported storage.capacity "pvesm is not available"
        return
    fi
    if ! output=$(pvesm status 2>&1); then
        doctor_result fail storage.capacity "could not read Proxmox storage status" "$output"
        return
    fi

    while IFS= read -r line; do
        [[ -n $line ]] || continue
        read -r -a columns <<<"$line"
        [[ ${columns[0]:-} != Name ]] || continue
        [[ ${#columns[@]} -ge 4 ]] || continue
        seen=$((seen + 1))
        name=${columns[0]}
        status=${columns[2]}
        last=$((${#columns[@]} - 1))
        percent=${columns[$last]%\%}
        if [[ $status == disabled ]]; then
            disabled+=("$name")
        elif [[ $status != active ]]; then
            failures+=("$name:$status")
        elif [[ $percent =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            value=${percent%%.*}
            if [[ $value -ge $fail_at ]]; then
                failures+=("$name:${percent}%")
            elif [[ $value -ge $warn_at ]]; then
                warnings+=("$name:${percent}%")
            fi
        fi
    done <<<"$output"

    if [[ $seen -eq 0 ]]; then
        doctor_result unsupported storage.capacity "no Proxmox storage records were returned"
    elif [[ ${#failures[@]} -gt 0 ]]; then
        detail=${failures[*]}
        [[ ${#warnings[@]} -eq 0 ]] || detail+="; warnings: ${warnings[*]}"
        [[ ${#disabled[@]} -eq 0 ]] || detail+="; disabled: ${disabled[*]}"
        doctor_result fail storage.capacity "storage requires attention" \
            "$detail"
    elif [[ ${#warnings[@]} -gt 0 ]]; then
        detail=${warnings[*]}
        [[ ${#disabled[@]} -eq 0 ]] || detail+="; disabled: ${disabled[*]}"
        doctor_result warn storage.capacity "storage is nearing capacity" "$detail"
    else
        detail=""
        [[ ${#disabled[@]} -eq 0 ]] || detail="disabled: ${disabled[*]}"
        doctor_result pass storage.capacity \
            "all enabled storage is active and below ${warn_at}%" "$detail"
    fi
}

doctor_check_tasks() {
    local since output count detail
    if ! command -v pvesh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        doctor_result unsupported pve.tasks "pvesh and jq are required"
        return
    fi
    since=$(date -d '24 hours ago' +%s)
    if ! output=$(pvesh get /nodes --output-format json 2>&1); then
        doctor_result fail pve.tasks "could not read the Proxmox node list" "$output"
        return
    fi
    if ! pve_collect_node_tasks "$output" --errors 1 --since "$since" --limit 50; then
        doctor_result fail pve.tasks "could not read recent failed Proxmox tasks" \
            "$PVE_TASKS_ERROR"
        return
    fi
    output=$PVE_TASKS_JSON
    count=$(jq -r 'length' <<<"$output")
    if [[ $count -eq 0 ]]; then
        doctor_result pass pve.tasks "no failed Proxmox tasks in the last 24 hours"
        return
    fi
    detail=$(jq -r '
        .[0:3]
        | map((.node // "unknown") + ":" + (.type // "task") + " " + (.status // "failed"))
        | join("; ")
    ' <<<"$output")
    doctor_result warn pve.tasks "$count failed Proxmox task(s) in the last 24 hours" "$detail"
}

doctor_check_reboot() {
    local reboot_file=${PVE_TOOLBOX_REBOOT_FILE:-/var/run/reboot-required}
    if [[ -e $reboot_file ]]; then
        doctor_result warn host.reboot "a reboot is required"
    else
        doctor_result pass host.reboot "no pending reboot marker"
    fi
}

doctor_run_core() {
    doctor_run_check cluster.quorum doctor_check_quorum
    doctor_run_check systemd.failed doctor_check_systemd
    doctor_run_check zfs.pools doctor_check_zfs
    doctor_run_check storage.capacity doctor_check_storage
    doctor_run_check pve.tasks doctor_check_tasks
    doctor_run_check host.reboot doctor_check_reboot
}

# Colors are initialized by lib/common.sh before this library is sourced.
# shellcheck disable=SC2154
doctor_render() {
    local i label colour
    local pass_count=0 warn_count=0 fail_count=0 skipped_count=0 unsupported_count=0
    for ((i = 0; i < ${#REPORT_STATES[@]}; i++)); do
        case ${REPORT_STATES[$i]} in
            pass)        label=PASS; colour=$c_green; pass_count=$((pass_count + 1)) ;;
            warn)        label=WARN; colour=$c_yellow; warn_count=$((warn_count + 1)) ;;
            fail)        label=FAIL; colour=$c_red; fail_count=$((fail_count + 1)) ;;
            skipped)     label=SKIP; colour=$c_dim; skipped_count=$((skipped_count + 1)) ;;
            unsupported) label=N/A;  colour=$c_dim; unsupported_count=$((unsupported_count + 1)) ;;
        esac
        printf '%s%-4s%s %-28s %s\n' "$colour$c_bold" "$label" "$c_reset" \
            "${REPORT_IDS[$i]}" "${REPORT_SUMMARIES[$i]}"
        if [[ -n ${REPORT_DETAILS[$i]} ]]; then
            printf '     %s\n' "${REPORT_DETAILS[$i]}"
        fi
    done
    printf '\nSummary: %d passed, %d warning, %d failed, %d skipped, %d unsupported\n' \
        "$pass_count" "$warn_count" "$fail_count" "$skipped_count" "$unsupported_count"

    return "$(report_exit_code)"
}
