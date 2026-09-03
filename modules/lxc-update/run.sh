#!/usr/bin/env bash
# Runs only through the launcher; guest code is shipped with this module.
set -Eeuo pipefail
MODULE_PATH=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
TOOLBOX_ROOT=${TOOLBOX_ROOT:-${MODULE_PATH%/modules/lxc-update}}
# shellcheck source=lib/common.sh
source "$TOOLBOX_ROOT/lib/common.sh"
# shellcheck source=lib/report.sh
source "$TOOLBOX_ROOT/lib/report.sh"

LX_DRY=0 LX_REMOVE=0 LX_NOTIFY=0 LX_CANCEL=0 LX_FAILED=0
LX_EXCLUDE="" DISCORD_WEBHOOK=""
LX_IDS=() LX_TARGETS=()
declare -A LX_NAMES=()
for arg in "$@"; do
    case $arg in
        --dry-run) LX_DRY=1 ;;
        --allow-removals) LX_REMOVE=1 ;;
        --notify) LX_NOTIFY=1 ;;
        *) [[ $arg =~ ^[1-9][0-9]{2,8}$ ]] || { warn "invalid container ID or flag: $arg"; exit 64; }
           [[ " ${LX_IDS[*]} " == *" $arg "* ]] || LX_IDS+=("$arg") ;;
    esac
done
require_root
for cmd in pveversion pvesh pct jq flock setsid; do
    command -v "$cmd" >/dev/null || die "missing host command: $cmd"
done
[[ $(pveversion) == pve-manager/9.* ]] || die "LXC updates require a PVE 9 host"
in_lxc && die "run LXC updates on the PVE host"
if [[ $LX_DRY == 0 ]]; then
    [[ $ASSUME_YES == 0 && ${FORCE:-0} == 0 && -t 0 && -t 1 ]] \
        || die "LXC updates require interactive confirmation; --yes/--force are not supported"
fi
if conf_exists lxc-update; then conf_load lxc-update; fi
exclude_ids=()
# Intentional whitespace splitting: configuration stores a list of numeric IDs.
for id in $LX_EXCLUDE; do
    [[ $id =~ ^[1-9][0-9]{2,8}$ ]] || die "invalid saved exclusion; reconfigure lxc-update"
    exclude_ids+=("$id")
done
LX_EXCLUDE="${exclude_ids[*]}"
if [[ $LX_NOTIFY == 1 && $LX_DRY == 0 ]]; then
    [[ $DISCORD_WEBHOOK =~ ^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9._-]+$ ]] \
        || die "--notify requires a configured Discord webhook; run pve-toolbox install lxc-update"
    command -v curl >/dev/null || die "--notify requires curl"
fi
LX_NODE=$(hostname -s)
[[ $LX_NODE =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || die "invalid local node name"
LX_INVENTORY=$(pvesh get "/nodes/$LX_NODE/lxc" --output-format json) \
    || die "could not read the local container inventory"
jq -e 'type == "array" and all(.[];
    (.vmid | type == "number" and . >= 100 and . <= 999999999 and floor == .) and
    (.status == "running" or .status == "stopped") and
    ((.name // "unnamed") | type == "string") and
    ((.template // 0) == 0 or .template == 1)) and
    (([.[].vmid] | unique | length) == length)' <<<"$LX_INVENTORY" >/dev/null \
    || die "invalid or ambiguous local container inventory"
for id in "${LX_IDS[@]}"; do
    jq -e --argjson id "$id" 'any(.[]; .vmid == $id)' <<<"$LX_INVENTORY" >/dev/null \
        || die "container $id is not on this host; nothing updated"
done

report_reset lxc-update
LX_WORK=$(mktemp -d)
trap 'rm -rf -- "$LX_WORK"' EXIT
# Each pct process has a separate session, so Ctrl+C reaches the supervisor
# without killing dpkg. wait can itself be interrupted and must be repeated.
trap 'LX_CANCEL=1; printf "\nCancellation requested; waiting for the active operation.\n"' INT TERM HUP

lx_guest() { # <id> <guest phase>; output streamed after credential filtering
    local id=$1 phase=$2 child reader rc=0 reader_rc=0
    : > "$LX_WORK/output"
    mkfifo "$LX_WORK/stream"
    # Keep the reader outside the terminal process group too. Its output is
    # untrusted terminal text, so strip control bytes before displaying it.
    setsid --wait bash -c '
        source "$1/lib/common.sh"
        source "$1/lib/report.sh"
        while IFS= read -r line || [[ -n $line ]]; do
            line=$(printf "%s" "$line" | LC_ALL=C tr -d "\000-\010\013\014\016-\037\177")
            report_clean_text "$line"
        done | tee "$2"
    ' _ "$TOOLBOX_ROOT" "$LX_WORK/output" < "$LX_WORK/stream" &
    reader=$!
    setsid --wait pct exec "$id" -- bash -s -- "$phase" "$LX_REMOVE" \
        < "$MODULE_PATH/guest.sh" > "$LX_WORK/stream" 2>&1 &
    child=$!
    while :; do
        rc=0
        wait "$child" || rc=$?
        kill -0 "$child" 2>/dev/null || break
    done
    while :; do
        reader_rc=0
        wait "$reader" || reader_rc=$?
        kill -0 "$reader" 2>/dev/null || break
    done
    rm -- "$LX_WORK/stream"
    [[ $reader_rc == 0 ]] || return 1
    return "$rc"
}

lx_ready() { # Validate exact local target again before entering it.
    local config status
    config=$(pvesh get "/nodes/$LX_NODE/lxc/$1/config" --output-format json 2>/dev/null) \
        || { LX_REASON="local container configuration unavailable"; return 1; }
    jq -e 'type == "object" and (.template // 0) == 0 and
        ((.lock // "") == "")' <<<"$config" >/dev/null \
        || { LX_REASON="template, locked, or malformed container configuration"; return 1; }
    case $(jq -r '.ostype // "unknown"' <<<"$config") in
        debian|ubuntu) ;;
        *) LX_REASON="unsupported guest OS"; return 69 ;;
    esac
    status=$(pvesh get "/nodes/$LX_NODE/lxc/$1/status/current" --output-format json 2>/dev/null) \
        || { LX_REASON="cannot verify local container status"; return 1; }
    jq -e 'type == "object" and .status == "running"' <<<"$status" >/dev/null \
        || { LX_REASON="container is no longer running locally"; return 1; }
}

step "LXC package updates on $LX_NODE"
printf 'Removals and cleanup: %s | Discord report: %s\n' "$LX_REMOVE" "$LX_NOTIFY"
printf 'Excluded IDs: %s\n' "${LX_EXCLUDE:-none}"
mapfile -t LX_ROWS < <(jq -r 'sort_by(.vmid)[] | [.vmid, (.name // "unnamed"), .status, (.template // 0)] | @tsv' <<<"$LX_INVENTORY")
for row in "${LX_ROWS[@]}"; do
    IFS=$'\t' read -r id name status template <<<"$row"
    [[ ${#LX_IDS[@]} == 0 || " ${LX_IDS[*]} " == *" $id "* ]] || continue
    name=$(report_clean_text "$name" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177')
    LX_NAMES[$id]=$name
    reason=""
    if [[ " $LX_EXCLUDE " == *" $id "* ]]; then reason="saved exclusion"
    elif [[ $template == 1 ]]; then reason="template"
    elif [[ $status != running ]]; then reason="stopped"
    fi
    if [[ -n $reason ]]; then
        report_add skipped "ct.$id" "$name: $reason"
        printf 'CT %s (%s): skipped (%s)\n' "$id" "$name" "$reason"
        continue
    fi
    rc=0
    lx_ready "$id" || rc=$?
    if [[ $rc != 0 ]]; then
        result=fail
        [[ $rc != 69 ]] || result=skipped
        report_add "$result" "ct.$id" "$name: $LX_REASON"
        printf 'CT %s (%s): %s (%s)\n' "$id" "$name" "$result" "$LX_REASON"
        [[ $rc == 69 ]] || LX_FAILED=1
        continue
    fi
    printf 'CT %s (%s): selected\n' "$id" "$name"
    LX_TARGETS+=("$id")
done

[[ ! -L $TOOLBOX_STATE_DIR ]] || die "unsafe state directory"
mkdir -p "$TOOLBOX_STATE_DIR"
for path in "$TOOLBOX_STATE_DIR/lxc-update.lock" "$TOOLBOX_STATE_DIR/lxc-update.state"; do
    [[ ! -L $path && ( ! -e $path || -f $path ) ]] || die "unsafe LXC updater state path"
done
exec {LX_LOCK}>"$TOOLBOX_STATE_DIR/lxc-update.lock"
flock -n "$LX_LOCK" || die "another LXC updater is already running"

lx_save() {
    local json index
    # One bounded record per container avoids passing an entire large batch
    # through a single environment variable in the shared state helpers.
    for ((index=LX_SAVED; index<${#REPORT_IDS[@]}; index++)); do
        json=$(jq -cn --arg state "${REPORT_STATES[$index]}" \
            --arg summary "${REPORT_SUMMARIES[$index]}" --arg detail "${REPORT_DETAILS[$index]}" \
            '{state:$state,summary:$summary,detail:$detail}') || return 1
        lx_record "ct_${REPORT_IDS[$index]#ct.}" "$json" || return 1
    done
    LX_SAVED=${#REPORT_IDS[@]}
    lx_record exit_code "$1" || return 1
    lx_record last_summary "$(date -u +%FT%TZ) $2" || return 1
}
lx_record() {
    state_set lxc-update "$1" "$2" || return 1
    [[ $(state_get lxc-update "$1") == "$2" ]]
}
lx_report_start() {
    LX_SAVED=0
    state_clear lxc-update
    lx_record host "$LX_NODE" || die "could not initialize report; nothing updated"
    lx_record allow_removals "$LX_REMOVE" || die "could not initialize report; nothing updated"
    lx_record notification pending || die "could not initialize report; nothing updated"
    lx_save "$LX_FAILED" 'in progress' || die "could not save initial report; nothing updated"
}

if [[ $LX_DRY == 1 ]]; then
    lx_report_start
    printf '\nPreview only: cached package indexes may be stale; no guest changes or Discord messages.\n'
    for id in "${LX_TARGETS[@]}"; do
        [[ $LX_CANCEL == 0 ]] || break
        printf '\nCT %s: preview\n' "$id"
        rc=0
        lx_guest "$id" preview || rc=$?
        if [[ $rc == 0 ]]; then
            printf 'CT %s: preview completed\n' "$id"
            report_add pass "ct.$id" "${LX_NAMES[$id]}: preview completed" "$(tail -c 16000 "$LX_WORK/output")"
        elif [[ $rc == 69 ]]; then
            printf 'CT %s: skipped (unsupported guest OS)\n' "$id"
            report_add skipped "ct.$id" "${LX_NAMES[$id]}: unsupported guest OS"
        else
            printf 'CT %s: preview failed\n' "$id"
            report_add fail "ct.$id" "${LX_NAMES[$id]}: preview failed" "$(tail -c 16000 "$LX_WORK/output")"
            LX_FAILED=1
        fi
    done
    [[ $LX_CANCEL == 0 ]] || LX_FAILED=130
    step 'Container preview results'
    for ((i=0; i<${#REPORT_IDS[@]}; i++)); do
        printf '%s: %s - %s\n' "${REPORT_IDS[$i]}" "${REPORT_STATES[$i]}" "${REPORT_SUMMARIES[$i]}"
    done
    lx_record notification not-requested || die "could not save preview notification state"
    lx_save "$LX_FAILED" "preview completed (exit $LX_FAILED)" || die "could not save preview report"
    exit "$LX_FAILED"
fi
[[ $LX_CANCEL == 0 ]] || exit 130
printf '\nPackages may restart services. No automatic backup, snapshot, rollback, or reboot.\n'
confirm "Update these containers with this policy?" n || exit 0
lx_report_start

for id in "${LX_TARGETS[@]}"; do
    if [[ $LX_CANCEL == 1 ]]; then
        report_add skipped "ct.$id" 'not attempted: run cancelled'
        continue
    fi
    printf '\nCT %s: updating\n' "$id"
    if ! lx_ready "$id"; then
        report_add fail "ct.$id" "$LX_REASON; update not attempted"
        LX_FAILED=1
        continue
    fi
    # Persist intent before entering the guest: a lost host process is never
    # mistaken for a healthy completed run.
    lx_record last_summary "in progress: CT $id; outcome unknown until completion" \
        || die "cannot record active container; no further updates attempted"
    rc=0
    phases=(refresh simulate upgrade)
    [[ $LX_REMOVE == 0 ]] || phases+=(autoremove autoclean)
    : > "$LX_WORK/container"
    finished=0
    for phase in "${phases[@]}"; do
        [[ $LX_CANCEL == 0 ]] || break
        if ! lx_ready "$id"; then
            printf '%s\n' "$LX_REASON" >> "$LX_WORK/container"
            rc=1
            break
        fi
        lx_guest "$id" "$phase" || rc=$?
        cat "$LX_WORK/output" >> "$LX_WORK/container"
        [[ $rc == 0 ]] || break
        finished=$((finished + 1))
    done
    # Once the upgrade was attempted, make a best-effort read-only inspection
    # even if a later cleanup failed. This preserves known hold/reboot results.
    if [[ $finished -ge 2 ]]; then
        update_rc=$rc
        lx_guest "$id" inspect || true
        cat "$LX_WORK/output" >> "$LX_WORK/container"
        rc=$update_rc
    fi
    if [[ $rc == 0 && $finished != "${#phases[@]}" ]]; then
        result=$(sed -n 's/^Result: / /p' "$LX_WORK/container" | tail -n1)
        report_add warn "ct.$id" "${LX_NAMES[$id]}: cancelled after $finished phase(s); remaining work not attempted;$result" "$(tail -c 16000 "$LX_WORK/container")"
    elif [[ $rc == 0 ]]; then
        result=$(sed -n 's/^Result: / /p' "$LX_WORK/container" | tail -n1)
        report_add pass "ct.$id" "${LX_NAMES[$id]}: package update completed;$result" "$(tail -c 16000 "$LX_WORK/container")"
    elif [[ $rc == 69 ]]; then
        report_add skipped "ct.$id" "${LX_NAMES[$id]}: unsupported guest OS"
    else
        result=$(sed -n 's/^Result: / /p' "$LX_WORK/container" | tail -n1)
        report_add fail "ct.$id" "${LX_NAMES[$id]}: failed (${phase:-guest preflight}); manual attention required;$result" "$(tail -c 16000 "$LX_WORK/container")"
        LX_FAILED=1
    fi
    lx_save "$LX_FAILED" 'in progress' || die "could not save results; no further updates attempted"
done
[[ $LX_CANCEL == 0 ]] || LX_FAILED=130
step 'Container update results'
for ((i=0; i<${#REPORT_IDS[@]}; i++)); do
    printf '%s: %s - %s\n' "${REPORT_IDS[$i]}" "${REPORT_STATES[$i]}" "${REPORT_SUMMARIES[$i]}"
done
lx_save "$LX_FAILED" "completed (exit $LX_FAILED)" || die "could not save final report"
if [[ $LX_NOTIFY == 1 ]]; then
    summary="Host: $LX_NODE | removals/cleanup: $LX_REMOVE | exit: $LX_FAILED"
    for ((i=0; i<${#REPORT_IDS[@]}; i++)); do
        summary+=$'\n'"${REPORT_IDS[$i]}: ${REPORT_STATES[$i]} - ${REPORT_SUMMARIES[$i]}"
    done
    summary+=$'\nFull details, held packages and reboot markers are in the local report.'
    color=$DISCORD_OK
    [[ $LX_FAILED == 0 ]] || color=$DISCORD_ERR
    if [[ ${#summary} -gt 3700 ]]; then
        summary="${summary:0:3550}"$'\nSummary truncated; see the complete local report.'
    fi
    if discord_notify "$DISCORD_WEBHOOK" "$color" 'LXC package update report' "$summary"; then
        lx_record notification delivered || die "Discord delivered but delivery state could not be saved"
    else
        warn 'Discord delivery failed; package results are unchanged'
        lx_record notification failed || die "Discord failed and delivery state could not be saved"
    fi
else
    lx_record notification not-requested || die "could not save notification state"
fi
printf 'Saved report: %s/lxc-update.state\n' "$TOOLBOX_STATE_DIR"
exit "$LX_FAILED"
