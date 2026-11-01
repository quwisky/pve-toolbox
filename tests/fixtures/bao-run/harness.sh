# shellcheck shell=bash
# shellcheck disable=SC2034 # Public fixture variables are used by callers.
# The launcher against PVE doubles and a chroot guest. Guest paths are isolated
# by chroot, never by production path overrides.
BR_T=$(mktemp -d)
trap 'rm -rf -- "$BR_T"' EXIT
BR_BASE=$BR_T/base
BR_TEST_ROOT=$BR_T/guest
BR_HOST=$BR_T/host
BR_PCT_LOG=$BR_HOST/pct.log
BR_ANS=$BR_T/answers
BR_SESSION=$BR_T/session
BR_MACHINE=0123456789abcdef0123456789abcdef
export BR_TEST_ROOT BR_HOST BR_PCT_LOG
export TOOLBOX_CONF_DIR=$BR_T/conf TOOLBOX_STATE_DIR=$BR_T/state TOOLBOX_BIN_DIR=$BR_T/bin TOOLBOX_SYSTEMD_DIR=$BR_T/systemd
export PATH="$BR_T/host-bin:$PATH"

mkdir -p "$BR_T/host-bin"
for cmd in pct pvesh pveversion hostname timeout; do
    cp tests/fixtures/bao-run/host-command.sh "$BR_T/host-bin/$cmd"
done
chmod 0755 "$BR_T/host-bin"/*

mkdir -p "$BR_BASE"/{usr/local/bin,etc,run,tmp,root,var/lib,dev}
br_copy_bin() {
    local bin path
    bin=$(command -v "$1")
    cp --parents "$bin" "$BR_BASE"
    while IFS= read -r path; do cp --parents "$path" "$BR_BASE"; done < <(ldd "$bin" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}')
}
br_base_ready() {
    local cmd
    for cmd in bash jq env cat chmod cmp cp cut find flock head mkdir mktemp mv readlink realpath rm rmdir sed sha256sum sort stat sync tr; do br_copy_bin "$cmd"; done
    # The host-side double must not shadow the real timeout in the guest.
    PATH=${PATH#"$BR_T/host-bin:"} br_copy_bin timeout
    ln -s usr/bin "$BR_BASE/bin"
    : > "$BR_BASE/dev/null" # A regular file also collects whatever the guest hides from stderr.
    cp /etc/ld.so.cache "$BR_BASE/etc/"
    printf 'ID=debian\nVERSION_ID="13"\n' > "$BR_BASE/etc/os-release"
    printf '%s\n' "$BR_MACHINE" > "$BR_BASE/etc/machine-id"
    for cmd in uname hostname curl systemctl runuser docker; do
        install -m 0755 tests/fixtures/bao-run/guest-command.sh "$BR_BASE/usr/bin/$cmd"
    done
}

# A fresh guest and empty host records and logs.
br_fixture() {
    rm -rf -- "$BR_TEST_ROOT" "$BR_HOST" "$TOOLBOX_CONF_DIR" "$TOOLBOX_STATE_DIR"
    cp -a "$BR_BASE" "$BR_TEST_ROOT"
    mkdir -p "$BR_HOST"
    : > "$BR_PCT_LOG"
    : > "$BR_HOST/timeouts"
    : > "$BR_TEST_ROOT/calls"
    : > "$BR_ANS"
    printf 'ok\n' > "$BR_TEST_ROOT/curl-mode"
    printf 'LoadState=loaded\nActiveState=active\nUser=\n' > "$BR_TEST_ROOT/unit"
    printf '[{"vmid":101,"name":"docker01","status":"running"}]' > "$BR_HOST/inventory"
    printf '{"ostype":"debian","hostname":"docker01","rootfs":"local:vm-101-disk-0","net0":"name=eth0,bridge=vmbr0,ip=192.0.2.50/24"}' > "$BR_HOST/config"
    printf '{"status":"running"}' > "$BR_HOST/status"
}
ans() { printf '%s.*: $\t%s\n' "$1" "${2:-}" >> "$BR_ANS"; } # <prompt regex> [reply]
# Runs the launcher through a pty; the remaining answers are spent either way.
br_drive() {
    local rc=0
    expect tests/fixtures/bao-run/drive.exp "$BR_ANS" "$@" > "$BR_SESSION" 2>&1 || rc=$?
    : > "$BR_ANS"
    # A prompt that never came is a test failure, whatever exit the test expected.
    [[ $rc != 90 && $rc != 91 ]] || br_fail "driver stopped with $rc"
    return "$rc"
}
br_run() { br_drive ./pve-toolbox "$@"; }
ans_to_role() { # Every install prompt up to the role loop, for a fresh CT.
    ans 'Container ID' 101
    ans 'Periphery runs as' systemd
    ans 'OpenBao URL' https://bao.example:8200
    ans 'CA file'
}
ans_role() { # <role> [suffix]: an added role with sentinel credentials and the default AppRole name.
    ans 'Add a role' y
    ans 'Role name' "$1"
    ans "AppRole name for $1"
    ans "Role ID for $1" "SENTINEL-ROLE-ID-$1${2:-}"
    ans "Secret ID for $1" "SENTINEL-SECRET-ID-$1${2:-}"
}
# shellcheck disable=SC2120 # Callers in tests/bao-run-module.sh pass the reply.
ans_apply() { ans 'Add a role' n; ans 'Apply this operation' "${1:-y}"; }
br_install() { # A successful fresh install of the default role.
    ans_to_role; ans_role default; ans_apply
    br_run install bao-run || br_fail 'install failed'
    : > "$BR_PCT_LOG"; : > "$BR_TEST_ROOT/calls"
}
br_fail() { printf 'FAIL %s\n' "$*" >&2; cat "$BR_SESSION" >&2 2>/dev/null; exit 1; }
br_has() { grep -aFq -- "$1" "$BR_SESSION" || br_fail "session lacks: $1"; }
br_lacks() { if grep -aFq -- "$1" "$BR_SESSION"; then br_fail "session has: $1"; fi; }
br_sha() { sha256sum "$1" | cut -d ' ' -f1; }
# shellcheck source=/dev/null
br_conf() { (source "$TOOLBOX_CONF_DIR/$1.conf"; printf '%s' "${!2}"); }
br_stages() { compgen -G "$BR_TEST_ROOT/run/pve-toolbox-bao-run-*" || true; }
br_works() { compgen -G '/run/pve-toolbox-bao-run.*' || true; }
br_no_stage() { [[ -z $(br_stages) ]] || br_fail "guest staging left: $(br_stages)"; }
br_no_work() { [[ -z $(br_works) ]] || br_fail "host work directory left: $(br_works)"; }
br_guest_tree() { # Paths, types, modes, owners, contents and times.
    (cd "$BR_TEST_ROOT" && find etc/bao-run usr/local var/lib -printf '%p %y %m %u %l %T@ %C@\n' 2>/dev/null | sort
     find etc/bao-run usr/local var/lib -type f -exec sha256sum {} + 2>/dev/null | sort)
}
