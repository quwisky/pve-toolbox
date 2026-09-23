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
            elif [[ $QGA_FAULT == pending ]]; then
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
head -c 120000 /dev/zero | tr '\000' x > "$WORK/binary"
MACHINE=$(cat /etc/machine-id)
kp_qga_stage pve1 201 binary "$WORK/binary" "$STAGE" "$MACHINE" || fail 'binary transfer failed'
cmp "$WORK/binary" "$STAGE/periphery" || fail 'transferred binary differs'
printf '%s' 'fixture-secret' > "$WORK/request"
kp_qga_stage pve1 201 request "$WORK/request" "$STAGE" "$MACHINE" || fail 'request transfer failed'
cmp "$WORK/request" "$STAGE/request.json" || fail 'transferred request differs'
QGA_FAULT=truncated
if kp_qga_exec pve1 201 '["/usr/bin/stat","-c","%s","/run"]' '' >/dev/null; then
    fail 'truncated guest output accepted'
fi
QGA_FAULT=lost
if kp_qga_exec pve1 201 '["/usr/bin/stat","-c","%s","/run"]' '' >/dev/null; then
    fail 'lost guest agent accepted'
fi
QGA_FAULT=pending
sleep() { SECONDS=$((SECONDS + 121)); }
if kp_qga_exec pve1 201 '["/usr/bin/stat","-c","%s","/run"]' '' >/dev/null; then
    fail 'unbounded guest process accepted'
fi
printf 'ok QGA transport stages exact files and rejects truncation, loss and timeout\n'
