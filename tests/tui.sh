#!/usr/bin/env bash
#
# Drives `pve-toolbox ui` through a pty and checks what it draws.
#
# Needs expect and whiptail. Missing either, this skips: `make test` has to
# keep working on a machine with neither. CI sets TUI_TEST_REQUIRED=1 so a
# missing dependency there is a failure rather than a quiet pass.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

for cmd in expect whiptail; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        if [[ ${TUI_TEST_REQUIRED:-0} -eq 1 ]]; then
            printf 'FAIL tui test required but %s is not installed\n' "$cmd" >&2
            exit 1
        fi
        printf 'skip tui test, no %s\n' "$cmd"
        exit 0
    fi
done

# A container - CI included - normally sets TERM=dumb, which whiptail refuses
# to draw on, so an unset TERM is not the only case to cover here.
case ${TERM:-} in
    ""|dumb|unknown) export TERM=xterm ;;
esac

exec expect tests/tui.exp
