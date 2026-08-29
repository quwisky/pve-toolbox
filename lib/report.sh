# shellcheck shell=bash
#
# lib/report.sh - deterministic command results for humans and automation.
#
# This file is sourced after common.sh. It stores only sanitized result text;
# raw module output is cleaned and redacted before it reaches these arrays.
#
[[ -n ${_TOOLBOX_REPORT_LOADED:-} ]] && return 0
_TOOLBOX_REPORT_LOADED=1

REPORT_SCHEMA_VERSION=1
REPORT_COMMAND=""
declare -ag REPORT_STATES=()
declare -ag REPORT_IDS=()
declare -ag REPORT_SUMMARIES=()
declare -ag REPORT_DETAILS=()

report_reset() { # report_reset <command>
    REPORT_COMMAND=$1
    REPORT_STATES=()
    REPORT_IDS=()
    REPORT_SUMMARIES=()
    REPORT_DETAILS=()
}

report_clean_text() {
    local value=$1
    value=${value//$'\t'/ }
    value=${value//$'\r'/ }
    value=${value//$'\n'/'; '}
    # Module output is not trusted to remember every secret-redaction rule.
    # Remove common credential forms and paths whose filenames reveal secret
    # material before anything is retained for human or JSON rendering.
    sed -E \
        -e 's#https?://[^/@[:space:]]+:[^/@[:space:]]+@#https://[redacted]@#g' \
        -e 's#https://(discord(app)?[.]com)/api/webhooks/[0-9]+/[^[:space:];]+#[redacted-webhook]#g' \
        -e 's#/(etc/pve/priv|etc/pve-toolbox)/[^[:space:];]+#[redacted-path]#g' \
        -e 's#((token|secret|password|passphrase|webhook)[A-Za-z0-9_.-]*[=:])[[:space:]]*[^[:space:];]+#\1[redacted]#gI' \
        <<<"$value"
}

report_add() { # report_add <state> <id> <summary> [detail]
    [[ $# -ge 3 && $# -le 4 ]] || return 2
    local state=$1 id=$2 summary=$3 detail=${4:-}
    case $state in
        pass|warn|fail|skipped|unsupported) ;;
        *) return 2 ;;
    esac
    [[ $id =~ ^[a-z0-9][a-z0-9._-]*$ ]] || return 2
    [[ -n $summary ]] || return 2
    summary=$(report_clean_text "$summary")
    detail=$(report_clean_text "$detail")
    REPORT_STATES+=("$state")
    REPORT_IDS+=("$id")
    REPORT_SUMMARIES+=("$summary")
    REPORT_DETAILS+=("$detail")
}

# Print the process status without returning it, so callers can decide whether
# to render before leaving under `set -e`.
report_exit_code() {
    local state have_pass=0 have_warn=0 have_fail=0 have_unsupported=0
    for state in "${REPORT_STATES[@]}"; do
        case $state in
            pass)        have_pass=1 ;;
            warn)        have_warn=1 ;;
            fail)        have_fail=1 ;;
            unsupported) have_unsupported=1 ;;
        esac
    done
    if [[ $have_fail -eq 1 ]]; then
        printf '1'
    elif [[ $have_warn -eq 1 ]]; then
        printf '2'
    elif [[ $have_pass -eq 1 ]]; then
        printf '0'
    elif [[ $have_unsupported -eq 1 ]]; then
        printf '69'
    else
        printf '0'
    fi
}

report_overall() { # report_overall <exit-code>
    case $1 in
        0)  printf 'success' ;;
        1)  printf 'failed' ;;
        2)  printf 'warning' ;;
        69) printf 'unsupported' ;;
        *)  printf 'failed' ;;
    esac
}

report_render_json() { # report_render_json <exit-code>
    local exit_code=$1 overall json i item
    overall=$(report_overall "$exit_code")
    json='[]'
    for ((i = 0; i < ${#REPORT_STATES[@]}; i++)); do
        item=$(jq -cn \
            --arg id "${REPORT_IDS[$i]}" \
            --arg state "${REPORT_STATES[$i]}" \
            --arg summary "${REPORT_SUMMARIES[$i]}" \
            --arg detail "${REPORT_DETAILS[$i]}" \
            '{id:$id,state:$state,summary:$summary,detail:$detail}')
        json=$(jq -cn --argjson results "$json" --argjson item "$item" \
            '$results + [$item]')
    done
    jq -n \
        --argjson schema_version "$REPORT_SCHEMA_VERSION" \
        --arg command "$REPORT_COMMAND" \
        --arg overall "$overall" \
        --argjson exit_code "$exit_code" \
        --argjson results "$json" \
        '{schema_version:$schema_version,command:$command,status:$overall,exit_code:$exit_code,results:$results}'
}
