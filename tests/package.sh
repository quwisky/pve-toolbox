#!/usr/bin/env bash
# Build and inspect the Debian package without installing it on the test host.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

for command in dpkg-buildpackage dpkg-deb; do
    if ! command -v "$command" >/dev/null 2>&1; then
        [[ ${PACKAGING_TEST_REQUIRED:-0} == 1 ]] && fail "$command is required"
        printf 'skip package test, no %s\n' "$command"
        exit 0
    fi
done
if ! dpkg-checkbuilddeps >/dev/null 2>&1; then
    [[ ${PACKAGING_TEST_REQUIRED:-0} == 1 ]] && fail "Debian build dependencies are missing"
    printf 'skip package test, Debian build dependencies are missing\n'
    exit 0
fi

WORK=$(mktemp -d)
PACKAGE_TOUCHED=0
cleanup() {
    if [[ $PACKAGE_TOUCHED -eq 1 ]]; then
        dpkg --purge pve-toolbox >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/src"
tar --exclude=.git --exclude=site --exclude='*.deb' -cf - . \
    | tar -xf - -C "$WORK/src"

(cd "$WORK/src" && dpkg-buildpackage --build=binary --no-sign >/dev/null)
deb=$(find "$WORK" -maxdepth 1 -name 'pve-toolbox_*_all.deb' -print -quit)
[[ -n $deb ]] || fail "dpkg-buildpackage produced no architecture-all package"

contents=$(dpkg-deb --contents "$deb")
for path in \
    ./usr/bin/pve-toolbox \
    ./usr/lib/pve-toolbox/lib/common.sh \
    ./usr/lib/pve-toolbox/lib/doctor.sh \
    ./usr/lib/pve-toolbox/lib/report.sh \
    ./usr/lib/pve-toolbox/modules/backup-audit/module.sh \
    ./usr/lib/pve-toolbox/modules/config-backup/module.sh \
    ./usr/lib/pve-toolbox/modules/native-notifications/module.sh \
    ./usr/lib/pve-toolbox/modules/native-notifications/pve-toolbox-native-notify \
    ./usr/lib/pve-toolbox/modules/storage-hygiene/module.sh \
    ./usr/lib/pve-toolbox/modules/certificate-watch/module.sh \
    ./usr/lib/pve-toolbox/modules/upgrade-readiness/module.sh \
    ./usr/lib/pve-toolbox/modules/upgrade-readiness/policies/pve-9.conf \
    ./usr/share/man/man1/pve-toolbox.1.gz \
    ./usr/share/bash-completion/completions/pve-toolbox \
    ./usr/share/zsh/vendor-completions/_pve-toolbox
do
    [[ $contents == *"$path"* ]] || fail "package omitted $path"
done
[[ $contents != *'/modules/_template/'* ]] || fail "package shipped the module template"
pass "package layout"

control=$(dpkg-deb --field "$deb")
[[ $control == *'Architecture: all'* ]] || fail "package architecture is not all"
[[ $control == *'Depends: curl, jq'* ]] || fail "hard dependencies are incomplete"
[[ $control == *'Recommends: whiptail, zfsutils-linux'* ]] \
    || fail "recommended dependencies are incomplete"
[[ $control == *'Suggests: smartmontools, sanoid'* ]] \
    || fail "suggested dependencies are incomplete"
pass "package metadata"

mkdir "$WORK/control" "$WORK/root"
dpkg-deb --control "$deb" "$WORK/control"
[[ ! -e $WORK/control/conffiles ]] || fail "runtime config was declared as conffiles"
grep -q '/usr/local/bin/pve-toolbox' "$WORK/control/postinst" \
    || fail "postinst does not warn about a shadowing checkout"
grep -q 'targets Debian 13 (trixie) / PVE 9' "$WORK/control/postinst" \
    || fail "postinst does not warn on unsupported hosts"
grep -q '\[ "$1" = purge \]' "$WORK/control/postrm" \
    || fail "postrm does not distinguish purge from remove"
dpkg-deb --extract "$deb" "$WORK/root"
[[ $(stat -c '%a' "$WORK/root/etc/pve-toolbox") == 750 ]] \
    || fail "/etc/pve-toolbox is not mode 0750"
[[ $(stat -c '%a' "$WORK/root/var/lib/pve-toolbox") == 755 ]] \
    || fail "/var/lib/pve-toolbox is not mode 0755"
version=$(PVE_TOOLBOX_ROOT="$WORK/root/usr/lib/pve-toolbox" \
    "$WORK/root/usr/bin/pve-toolbox" --version)
expected_version=$(<VERSION)
[[ $version == "pve-toolbox $expected_version" ]] || fail "installed version is wrong: $version"
pass "package runtime paths and lifecycle"

if [[ ${PACKAGING_INSTALL_TEST_REQUIRED:-0} == 1 ]]; then
    [[ $EUID -eq 0 ]] || fail "the package install lifecycle test requires root"
    if dpkg-query -W -f='${db:Status-Status}' pve-toolbox 2>/dev/null \
        | grep -q '^installed$'; then
        fail "refusing to replace an existing pve-toolbox package"
    fi
    for dependency in curl jq; do
        dpkg-query -W -f='${db:Status-Status}' "$dependency" 2>/dev/null \
            | grep -q '^installed$' || fail "$dependency must be installed for the lifecycle test"
    done

    PACKAGE_TOUCHED=1
    dpkg -i "$deb" >/dev/null
    [[ $(/usr/bin/pve-toolbox --version) == "pve-toolbox $expected_version" ]] \
        || fail "the installed package did not run"
    printf 'keep\n' > /etc/pve-toolbox/package-test.conf
    printf 'keep\n' > /var/lib/pve-toolbox/package-test.state
    dpkg --remove pve-toolbox >/dev/null
    [[ -f /etc/pve-toolbox/package-test.conf ]] \
        || fail "package removal deleted runtime config"
    [[ -f /var/lib/pve-toolbox/package-test.state ]] \
        || fail "package removal deleted runtime state"
    dpkg -i "$deb" >/dev/null
    dpkg --purge pve-toolbox >/dev/null
    [[ ! -e /etc/pve-toolbox ]] || fail "package purge retained runtime config"
    [[ ! -e /var/lib/pve-toolbox ]] || fail "package purge retained runtime state"
    PACKAGE_TOUCHED=0
    pass "dpkg install, remove and purge lifecycle"
fi
