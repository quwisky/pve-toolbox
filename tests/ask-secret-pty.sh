#!/usr/bin/env bash
#
# Drives ask_secret through a real pty, checked pty. tests/lib.sh pipes
# answers through a plain pipe (see prompt_run), and `read` neither echoes
# nor requires a tty to stay silent when its stdin is a pipe - so a piped
# refuse_out assertion cannot tell `read -s` apart from a plain `read`. Only a
# pty can: `read` without `-s` echoes there, `read -s` does not. This is the
# regression check that matters for a secret prompt.
#
# Needs expect, on the same "skip unless required" contract as tests/tui.sh.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

if ! command -v expect >/dev/null 2>&1; then
    if [[ ${ASK_SECRET_PTY_TEST_REQUIRED:-0} -eq 1 ]]; then
        printf 'FAIL ask_secret pty test required but expect is not installed\n' >&2
        exit 1
    fi
    printf 'skip ask_secret pty test, no expect\n'
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ASK_SECRET_PTY_VALUE='s3cret-pty-value'
export ASK_SECRET_PTY_VALUE

# A standalone script, not an inline `expect -c`/`spawn bash -c`: the secret
# would otherwise have to survive Tcl string interpolation next to bash's own
# quoting, which is exactly the kind of double-escaping that hides a real
# regression behind a broken test. sourcing $ROOT/lib/common.sh directly, by
# absolute path, keeps this independent of expect's own working directory.
cat > "$WORK/driver.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT/lib/common.sh"
t() {
    local TOKEN=""
    ask_secret TOKEN "token"
    if [[ \$TOKEN == "\$ASK_SECRET_PTY_VALUE" ]]; then
        printf 'ASK_SECRET_PTY_MARKER=match\n'
    else
        printf 'ASK_SECRET_PTY_MARKER=mismatch\n'
    fi
}
t
EOF
chmod +x "$WORK/driver.sh"
export ASK_SECRET_PTY_DRIVER="$WORK/driver.sh"

expect tests/ask-secret-pty.exp
