#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 ]]; then
    [[ ${QGA_TEST_REQUIRED:-0} != 1 ]] || fail 'QGA transport test requires root'
    printf 'skip QGA transport test (root required)\n'
    exit 0
fi
[[ -f modules/komodo-periphery/transport-qga.sh ]] || fail 'QGA transport missing'
TOOLBOX_ROOT=$PWD
source lib/common.sh
source modules/komodo-periphery/transport-qga.sh
[[ $(stat -c %s -- modules/komodo-periphery/guest.sh) -le 49152 ]] || fail 'inspection script exceeds QGA input bound'
WORK=$(mktemp -d)
STAGE=/run/pve-toolbox-komodo-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
[[ ! -e $STAGE ]] || fail 'stage fixture collision'
trap 'rm -rf -- "$WORK" "$STAGE"' EXIT
QGA_FAULT=""
# Deliberately assert the bridge receives no arguments: payloads use stdin.
# shellcheck disable=SC2120
kp_qga_bridge() {
    [[ $# == 0 ]] || fail 'bridge received payload in argv'
    local request action file count command=() input="$WORK/input" output="$WORK/output" rc=0
    request=$(cat)
    action=$(jq -r .action <<<"$request")
    case $action in
        exec)
            jq -r '.input_data_b64 // ""' <<<"$request" | base64 -d > "$input"
            mapfile -t command < <(jq -r '.command[]' <<<"$request")
            "${command[@]}" < "$input" > "$output" 2> "$WORK/error" || rc=$?
            jq -nc --arg out "$(cat "$output")" --arg err "$(cat "$WORK/error")" --argjson rc "$rc" \
                '{exited:1,exitcode:$rc,"out-data":$out,"err-data":$err}' > "$WORK/status.json"
            printf '{"pid":17}\n' ;;
        exec-status)
            if [[ $QGA_FAULT == truncated ]]; then
                jq '. + {"out-truncated":1}' "$WORK/status.json"
            elif [[ $QGA_FAULT == lost ]]; then
                return 1
            elif [[ $QGA_FAULT == pending ]] || { [[ $QGA_FAULT == slow ]] && ((SECONDS < QGA_DONE_AT)); }; then
                printf '{"exited":0}\n'
            else cat "$WORK/status.json"; fi ;;
        file-write)
            file=$(jq -r .file <<<"$request")
            jq -r .content_b64 <<<"$request" | base64 -d > "$file"
            count=$(stat -c %s -- "$file")
            jq -nc --argjson count "$count" '{written:$count}' ;;
        *) fail 'unexpected QGA operation' ;;
    esac
}
kp_qga_bootstrap pve1 201 "$STAGE" || fail 'receiver bootstrap failed'
[[ -f $STAGE/receiver.sh ]] || fail 'receiver was not staged'
# 17 chunks: one periodic progress line after chunk 16, one at completion.
head -c 800000 /dev/zero | tr '\000' x > "$WORK/binary"
MACHINE=$(cat /etc/machine-id)
kp_qga_stage pve1 201 binary "$WORK/binary" "$STAGE" "$MACHINE" > "$WORK/stdout" 2> "$WORK/progress" || fail 'binary transfer failed'
cmp "$WORK/binary" "$STAGE/periphery" || fail 'transferred binary differs'
[[ ! -s $WORK/stdout ]] || fail 'QGA staging progress written to stdout'
grep -q 'binary.*782 KiB' "$WORK/progress" || fail "QGA staging did not announce the file: $(cat "$WORK/progress")"
grep -q '768/782 KiB (98%)' "$WORK/progress" || fail "QGA staging has no periodic progress: $(cat "$WORK/progress")"
grep -q '782/782 KiB (100%)' "$WORK/progress" || fail "QGA staging has no completion progress: $(cat "$WORK/progress")"
printf '%s' 'fixture-secret' > "$WORK/request"
kp_qga_stage pve1 201 request "$WORK/request" "$STAGE" "$MACHINE" 2>/dev/null || fail 'request transfer failed'
cmp "$WORK/request" "$STAGE/request.json" || fail 'transferred request differs'
QGA_FAULT=truncated
if kp_qga_exec pve1 201 '["/usr/bin/stat","-c","%s","/run"]' '' >/dev/null; then
    fail 'truncated guest output accepted'
fi
QGA_FAULT=lost
if kp_qga_exec pve1 201 '["/usr/bin/stat","-c","%s","/run"]' '' >/dev/null; then
    fail 'lost guest agent accepted'
fi
# A slow but healthy guest operation, including a rollback, must finish inside
# the host limit (see the guest time budget in guest.sh).
QGA_FAULT=slow QGA_DONE_AT=$((SECONDS + 200))
sleep() { SECONDS=$((SECONDS + 10)); }
[[ $(kp_qga_exec pve1 201 '["/usr/bin/printf","finished"]' '') == finished ]] || fail 'slow guest operation outcome dropped'
QGA_FAULT=pending
sleep() { SECONDS=$((SECONDS + 121)); }
if kp_qga_exec pve1 201 '["/usr/bin/stat","-c","%s","/run"]' '' >/dev/null; then
    fail 'unbounded guest process accepted'
fi
printf 'ok QGA transport stages exact files and rejects truncation, loss and timeout\n'
