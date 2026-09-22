# shellcheck shell=bash
# shellcheck disable=SC2034 # Public fixture variables are used by callers.
# Guest absolute paths are isolated by chroot, never by production path overrides.
KP_WORK=$(mktemp -d)
trap 'rm -rf -- "$KP_WORK"' EXIT
KP_BASE=$KP_WORK/base
mkdir -p "$KP_BASE"/{usr/bin,usr/local/bin,etc/systemd/system,etc/komodo/keys,run/systemd/system,proc,self,tmp,root,var/lib,lib,lib64}
kp_copy_bin() {
    local bin path
    bin=$(command -v "$1")
    cp --parents "$bin" "$KP_BASE"
    while IFS= read -r path; do cp --parents "$path" "$KP_BASE"; done < <(ldd "$bin" 2>/dev/null | awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}')
}
for cmd in rmdir grep sed bash jq stat sha256sum cut dirname basename readlink realpath cat mkdir chmod chown cp mv rm mktemp sync flock timeout sleep sort date find head tr cmp env; do kp_copy_bin "$cmd"; done
ln -s usr/bin "$KP_BASE/bin"
mkdir -p "$KP_BASE/dev"
# Regular files suffice for redirects in command doubles.
: > "$KP_BASE/dev/null"
cp /etc/ld.so.cache "$KP_BASE/etc/"
printf 'ID=debian\nVERSION_ID="13"\n' > "$KP_BASE/etc/os-release"
printf '0123456789abcdef0123456789abcdef\n' > "$KP_BASE/etc/machine-id"
cp tests/fixtures/komodo-periphery/command.sh "$KP_BASE/usr/bin/systemctl"
cp "$KP_BASE/usr/bin/cp" "$KP_BASE/usr/bin/cp-real"
cp "$KP_BASE/usr/bin/chmod" "$KP_BASE/usr/bin/chmod-real"
cp "$KP_BASE/usr/bin/mv" "$KP_BASE/usr/bin/mv-real"
cp "$KP_BASE/usr/bin/readlink" "$KP_BASE/usr/bin/readlink-real"
for cmd in dpkg-query uname readlink sleep mv chmod cp journalctl; do cp tests/fixtures/komodo-periphery/command.sh "$KP_BASE/usr/bin/$cmd"; done
kp_fixture() {
    KP_TEST_ROOT=$KP_WORK/guest
    rm -rf -- "$KP_TEST_ROOT"
    cp -a "$KP_BASE" "$KP_TEST_ROOT"
    cp modules/komodo-periphery/guest.sh "$KP_TEST_ROOT/guest.sh"
    KP_TEST_LOG=$KP_TEST_ROOT/calls
    : > "$KP_TEST_LOG"
    printf 'enabled\n' > "$KP_TEST_ROOT/enabled"
    printf 'active\n' > "$KP_TEST_ROOT/active"
    KP_TEST_BINARY=$KP_TEST_ROOT/usr/local/bin/periphery
    KP_TEST_CONFIG=$KP_TEST_ROOT/etc/komodo/periphery.config.toml
    if [[ $1 != absent ]]; then
        cat > "$KP_TEST_BINARY" <<'BIN'
#!/bin/bash
if [[ $1 == --version ]]; then printf 'periphery 2.3.2\n'; else exit 1; fi
BIN
        chmod 0755 "$KP_TEST_BINARY"
        printf 'onboarding_key = "existing-secret"\n' > "$KP_TEST_CONFIG"
        chmod 0600 "$KP_TEST_CONFIG"
        printf 'private-identity\n' > "$KP_TEST_ROOT/etc/komodo/keys/periphery.key"
        chmod 0700 "$KP_TEST_ROOT/etc/komodo/keys"
        cat > "$KP_TEST_ROOT/etc/systemd/system/periphery.service" <<'UNIT'
[Unit]
Description=existing upstream unit
[Service]
ExecStart=/bin/sh -lc "/usr/local/bin/periphery --config-path /etc/komodo/periphery.config.toml"
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
    fi
    case $1 in
        custom-direct-v2)
            mkdir -p "$KP_TEST_ROOT/opt/custom path"
            mv "$KP_TEST_BINARY" "$KP_TEST_ROOT/opt/custom path/periphery"
            sed -i 's|ExecStart=.*|ExecStart="/opt/custom path/periphery" --config-path /etc/komodo/periphery.config.toml|' "$KP_TEST_ROOT/etc/systemd/system/periphery.service" ;;
        shell-injection)
            sed -i 's|ExecStart=.*|ExecStart=/bin/sh -lc "touch /tmp/injected; /usr/local/bin/periphery"|' "$KP_TEST_ROOT/etc/systemd/system/periphery.service" ;;
        v1) sed -i s/2.3.2/1.19.0/ "$KP_TEST_BINARY" ;;
        package-owned) : > "$KP_TEST_ROOT/package-owned" ;;
    esac
}
kp_guest() { chroot "$KP_TEST_ROOT" /bin/bash /guest.sh "$@"; }
kp_assert_no_guest_mutation() {
    if grep -Eq '^(start|stop|enable|disable|daemon-reload|reset-failed)' "$KP_TEST_LOG"; then
        fail 'read-only inspection mutated service'
    fi
}
kp_request() { # install|update|uninstall, using current inspection
    local action=$1 inspected hash
    inspected=$(kp_guest inspect)
    mkdir -p "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    chmod 0700 "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    cat > "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/periphery" <<'BIN'
#!/bin/bash
if [[ $1 == --version ]]; then printf 'periphery 2.3.3\n'; else exit 1; fi
BIN
    chmod 0755 "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/periphery"
    hash=$(sha256sum "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/periphery" | cut -d ' ' -f1)
    jq -nc --argjson old "$inspected" --arg action "$action" --arg sha "$hash" '{schema:1,
        action:$action,transaction_id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",machine_id:$old.machine_id,
        expected_fingerprint:$old.fingerprint,adopt:true,version:"2.3.3",asset_sha256:$sha,
        staged_binary:"/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/periphery",core_url:"https://core.example.invalid",
        server_name:"fixture",onboarding_key:"fixture-secret"}' > "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
    chmod 0600 "$KP_TEST_ROOT/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json"
    KP_TEST_REQUEST=/run/pve-toolbox-komodo-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/request.json
}
kp_host_fixture() {
    mkdir -p "$KP_WORK/host-bin"
    local cmd
    for cmd in pct pvesh pveversion hostname curl; do
        cp tests/fixtures/komodo-periphery/host-command.sh "$KP_WORK/host-bin/$cmd"
    done
    export KP_TEST_ROOT KP_RELEASE="$KP_WORK/release" KP_HOST_CALLS="$KP_WORK/host-calls"
    cat > "$KP_RELEASE" <<'BIN'
#!/bin/bash
if [[ $1 == --version ]]; then printf 'periphery 2.3.3\n'; else exit 1; fi
BIN
    chmod 0755 "$KP_RELEASE"
    : > "$KP_HOST_CALLS"
    rm -rf "$KP_WORK/conf" "$KP_WORK/state"
    export TOOLBOX_CONF_DIR="$KP_WORK/conf" TOOLBOX_STATE_DIR="$KP_WORK/state"
    export PATH="$KP_WORK/host-bin:$PATH"
}
kp_confirm() { expect tests/fixtures/komodo-periphery/drive.exp "$1" ./pve-toolbox "${@:2}"; }

kp_guest_python() { # Optional configuration-editor dependency in isolated guests.
    local stdlib KP_BASE=$KP_TEST_ROOT
    kp_copy_bin python3
    stdlib=$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')
    mkdir -p "$KP_TEST_ROOT${stdlib%/*}"
    cp -a "$stdlib" "$KP_TEST_ROOT$stdlib"
}
