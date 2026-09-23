#!/usr/bin/env bash
# A small, nonce-bound receiver for QGA and SSH staging. It never applies an
# installation; guest.sh verifies the complete staged artifact before use.
set -euo pipefail
export LC_ALL=C
umask 077

stage_die() { printf 'staging rejected\n' >&2; exit 1; }
stage_target() {
    [[ $# == 2 && $1 =~ ^/run/pve-toolbox-komodo-[a-f0-9]{32}$ ]] || stage_die
    [[ -d $1 && ! -L $1 && $(stat -c %u -- "$1") == 0 && $(stat -c %a -- "$1") == 700 ]] || stage_die
    case $2 in
        helper) STAGE_FILE=$1/guest.sh ;;
        binary) STAGE_FILE=$1/periphery ;;
        request) STAGE_FILE=$1/request.json ;;
        *) stage_die ;;
    esac
    [[ ! -L $STAGE_FILE && ( ! -e $STAGE_FILE || -f $STAGE_FILE ) ]] || stage_die
    if [[ -e $STAGE_FILE ]]; then
        [[ $(stat -c %u -- "$STAGE_FILE") == 0 && $(stat -c %a -- "$STAGE_FILE") == 600 ]] || stage_die
    fi
}
stage_number() {
    [[ $1 =~ ^(0|[1-9][0-9]*)$ && ${#1} -le 9 ]] || stage_die
    (( $1 <= 500000000 )) || stage_die
}
stage_digest() { [[ $1 =~ ^[a-f0-9]{64}$ ]] || stage_die; }
stage_machine() { # Expected guest machine ID; checked on every chunk connection.
    [[ $1 =~ ^[a-f0-9]{32}$ ]] || stage_die
    local actual
    IFS= read -r actual < /etc/machine-id || stage_die
    [[ $actual == "$1" ]] || stage_die
}

case ${1:-} in
    append)
        [[ $# == 7 ]] || stage_die
        stage_target "$2" "$3"
        stage_number "$4"; stage_number "$5"; stage_digest "$6"; stage_machine "$7"
        (( $5 > 0 && $5 <= 49152 )) || stage_die
        current=0
        if [[ -e $STAGE_FILE ]]; then current=$(stat -c %s -- "$STAGE_FILE"); fi
        [[ $current == "$4" ]] || stage_die
        chunk=$(mktemp "$2/.chunk.XXXXXXXX") || stage_die
        trap 'rm -f -- "$chunk"' EXIT
        cat > "$chunk" || stage_die
        [[ $(stat -c %s -- "$chunk") == "$5" ]] || stage_die
        hash=$(sha256sum -- "$chunk"); [[ ${hash%% *} == "$6" ]] || stage_die
        cat "$chunk" >> "$STAGE_FILE" || stage_die
        chmod 0600 "$STAGE_FILE" && sync -f "$STAGE_FILE" || stage_die
        printf 'ok\n'
        ;;
    verify)
        [[ $# == 6 ]] || stage_die
        stage_target "$2" "$3"
        stage_number "$4"; stage_digest "$5"; stage_machine "$6"
        [[ -f $STAGE_FILE && $(stat -c %s -- "$STAGE_FILE") == "$4" ]] || stage_die
        hash=$(sha256sum -- "$STAGE_FILE"); [[ ${hash%% *} == "$5" ]] || stage_die
        printf 'ok\n'
        ;;
    *) stage_die ;;
esac
