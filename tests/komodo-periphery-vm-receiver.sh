#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
if [[ $EUID != 0 ]]; then
    [[ ${QGA_TEST_REQUIRED:-0} != 1 ]] || fail 'receiver test requires root'
    printf 'skip QGA receiver test (root required)\n'
    exit 0
fi
RECEIVER=modules/komodo-periphery/stage-receiver.sh
[[ -f $RECEIVER ]] || fail 'QGA stage receiver missing'
STAGE=/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
[[ ! -e $STAGE ]] || fail 'fixture stage path already exists'
mkdir -m 0700 -- "$STAGE"
trap 'rm -f -- "$STAGE"/receiver.sh "$STAGE"/periphery "$STAGE"/request.json "$STAGE"/guest.sh; rmdir -- "$STAGE"' EXIT
cp "$RECEIVER" "$STAGE/receiver.sh"
chmod 0600 "$STAGE/receiver.sh"
PAYLOAD=$(mktemp)
trap 'rm -f -- "$PAYLOAD"; rm -f -- "$STAGE"/receiver.sh "$STAGE"/periphery "$STAGE"/request.json "$STAGE"/guest.sh; rmdir -- "$STAGE"' EXIT
head -c 49152 /dev/zero | tr '\000' x > "$PAYLOAD"
HASH=$(sha256sum "$PAYLOAD" | cut -d ' ' -f1)
MACHINE=$(cat /etc/machine-id)
bash "$STAGE/receiver.sh" append "$STAGE" binary 0 49152 "$HASH" "$MACHINE" < "$PAYLOAD" || fail 'first chunk rejected'
if bash "$STAGE/receiver.sh" append "$STAGE" binary 49152 49152 "$HASH" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa < "$PAYLOAD"; then fail 'wrong guest machine accepted'; fi
if bash "$STAGE/receiver.sh" append "$STAGE" binary 0 49152 "$HASH" "$MACHINE" < "$PAYLOAD"; then fail 'duplicate chunk accepted'; fi
bash "$STAGE/receiver.sh" append "$STAGE" binary 49152 49152 "$HASH" "$MACHINE" < "$PAYLOAD" || fail 'second chunk rejected'
WHOLE=$(sha256sum "$STAGE/periphery" | cut -d ' ' -f1)
bash "$STAGE/receiver.sh" verify "$STAGE" binary 98304 "$WHOLE" "$MACHINE" || fail 'whole file rejected'
if bash "$STAGE/receiver.sh" verify "$STAGE" binary 98303 "$WHOLE" "$MACHINE"; then fail 'short size accepted'; fi
if bash "$STAGE/receiver.sh" append "$STAGE" request 0 49152 "$(printf '%064d' 0)" "$MACHINE" < "$PAYLOAD"; then fail 'wrong chunk hash accepted'; fi
[[ ! -e $STAGE/request.json ]] || fail 'wrong hash created request'
if bash modules/komodo-periphery/stage-cleanup.sh /run/pve-toolbox-komodo-cccccccccccccccccccccccccccccccc aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; then fail 'wrong guest accepted for staging cleanup'; fi
bash modules/komodo-periphery/stage-cleanup.sh /run/pve-toolbox-komodo-cccccccccccccccccccccccccccccccc "$MACHINE" || fail 'matching guest cleanup rejected'
printf 'ok QGA receiver enforces chunk offset, size and digest\n'
