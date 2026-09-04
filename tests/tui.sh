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

# Same contract as smoke.sh: nothing here may touch the host it runs on. This
# matters more than it used to - the install case drives a real module_install
# as root, and without these it would write to /etc/pve-toolbox,
# /usr/local/bin and /etc/systemd/system for real. Today it only gets as far
# as the zpool check, but that is a property of the image, not of the test.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
for d in BIN LIB CONF STATE SYSTEMD; do
    printf -v "TOOLBOX_${d}_DIR" '%s' "$(mktemp -d "$WORK/XXXXXX")"
    export "TOOLBOX_${d}_DIR"
done

# The install case needs require_root to pass before a module gets as far as
# prompting. CI runs as root in the container; someone running `make test-tui`
# on their laptop usually does not, so it is skipped there rather than made to
# fail - but where the suite is declared required, a silent skip of the one
# case covering an operator-visible bug is not acceptable either.
if [[ $EUID -eq 0 ]]; then
    export TUI_TEST_ROOT=1
elif [[ ${TUI_TEST_REQUIRED:-0} -eq 1 ]]; then
    printf 'FAIL tui test required but not running as root\n' >&2
    exit 1
else
    export TUI_TEST_ROOT=0
fi

# tui.exp reaches zfs-scrub by counting rows in the module checklist. Resolve
# that row from the same discovery path as the UI, so adding an alphabetically
# earlier module cannot make the driven test select a different module.
if ./pve-toolbox _complete modules | grep -Fxq native-notifications; then
    printf 'FAIL obsolete notification provisioning remains in the UI\n' >&2
    exit 1
fi
TUI_ZFS_ROW=$(./pve-toolbox _complete modules | grep -nx 'zfs-scrub' | cut -d: -f1)
if [[ -z $TUI_ZFS_ROW ]]; then
    printf 'FAIL zfs-scrub is missing from the discovered module list\n' >&2
    exit 1
fi
export TUI_ZFS_ROW

# Not exec'd: that would replace this shell and the cleanup trap would never
# run.
expect tests/tui.exp
