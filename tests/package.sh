#!/usr/bin/env bash
# Build and inspect the Debian package without installing it on the test host.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

commands=(dpkg-deb)
[[ -n ${PACKAGE_DEB:-} ]] || commands+=(dpkg-buildpackage)
[[ -z ${PACKAGE_DEB_SHA256:-} ]] || commands+=(sha256sum)
for command in "${commands[@]}"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        [[ ${PACKAGING_TEST_REQUIRED:-0} == 1 ]] && fail "$command is required"
        printf 'skip package test, no %s\n' "$command"
        exit 0
    fi
done
if [[ -z ${PACKAGE_DEB:-} ]] && ! dpkg-checkbuilddeps >/dev/null 2>&1; then
    [[ ${PACKAGING_TEST_REQUIRED:-0} == 1 ]] && fail "Debian build dependencies are missing"
    printf 'skip package test, Debian build dependencies are missing\n'
    exit 0
fi

WORK=$(mktemp -d)
PACKAGE_TOUCHED=0
cleanup() {
    status=$?
    trap - EXIT
    if [[ $PACKAGE_TOUCHED -eq 1 ]]; then
        if ! dpkg --purge pve-toolbox >/dev/null; then
            printf 'FAIL could not purge pve-toolbox during cleanup\n' >&2
            status=1
        fi
    fi
    if ! rm -rf -- "$WORK"; then
        printf 'FAIL could not remove package-test workspace: %s\n' "$WORK" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/src"
if [[ -n ${PACKAGE_DEB:-} ]]; then
    if [[ $PACKAGE_DEB == /* ]]; then
        deb=$PACKAGE_DEB
    else
        deb="$ROOT/$PACKAGE_DEB"
    fi
    [[ -f $deb && ! -L $deb ]] || fail "prebuilt package is missing or unsafe: $deb"
else
    tar --exclude=.git --exclude=site --exclude='*.deb' -cf - . \
        | tar -xf - -C "$WORK/src"
    (cd "$WORK/src" && dpkg-buildpackage --build=binary --no-sign >/dev/null)
    deb=$(find "$WORK" -maxdepth 1 -name 'pve-toolbox_*_all.deb' -print -quit)
    [[ -n $deb ]] || fail "dpkg-buildpackage produced no architecture-all package"
fi

if [[ -n ${PACKAGE_DEB_SHA256:-} ]]; then
    [[ $PACKAGE_DEB_SHA256 =~ ^[0-9a-f]{64}$ ]] \
        || fail "PACKAGE_DEB_SHA256 is not a lowercase SHA-256 digest"
    actual_sha=$(sha256sum "$deb" | awk '{print $1}')
    [[ $actual_sha == "$PACKAGE_DEB_SHA256" ]] \
        || fail "prebuilt package digest changed before package validation"
fi

mkdir "$WORK/control" "$WORK/root"
dpkg-deb --control "$deb" "$WORK/control"
dpkg-deb --extract "$deb" "$WORK/root"

expected_manifest="$WORK/expected-runtime-manifest"
actual_manifest="$WORK/actual-runtime-manifest"
{
    printf '%s\n' VERSION
    for source in "$ROOT"/lib/*.sh; do
        printf 'lib/%s\n' "${source##*/}"
    done
    while IFS= read -r -d '' source; do
        printf '%s\n' "${source#"$ROOT/"}"
    done < <(find "$ROOT/modules" -mindepth 2 -type f \
        ! -path "$ROOT/modules/_*/*" -print0)
} | LC_ALL=C sort > "$expected_manifest"
find "$WORK/root/usr/lib/pve-toolbox" -type f -printf '%P\n' \
    | LC_ALL=C sort > "$actual_manifest"
cmp -s "$expected_manifest" "$actual_manifest" \
    || fail "package runtime manifest differs from source"

for source in "$ROOT"/lib/*.sh; do
    target="$WORK/root/usr/lib/pve-toolbox/lib/${source##*/}"
    cmp -s "$source" "$target" || fail "packaged lib/${source##*/} differs from source"
    expected_mode=644
    [[ -x $source ]] && expected_mode=755
    [[ $(stat -c '%a' "$target") == "$expected_mode" ]] \
        || fail "packaged lib/${source##*/} has the wrong mode"
done
while IFS= read -r -d '' source; do
    relative=${source#"$ROOT/"}
    target="$WORK/root/usr/lib/pve-toolbox/$relative"
    cmp -s "$source" "$target" || fail "packaged $relative differs from source"
    expected_mode=644
    [[ -x $source ]] && expected_mode=755
    [[ $(stat -c '%a' "$target") == "$expected_mode" ]] \
        || fail "packaged $relative has the wrong mode"
done < <(find "$ROOT/modules" -mindepth 2 -type f ! -path "$ROOT/modules/_*/*" -print0)
for target in \
    "$WORK/root/usr/bin/pve-toolbox" \
    "$WORK/root/usr/share/man/man1/pve-toolbox.1.gz" \
    "$WORK/root/usr/share/bash-completion/completions/pve-toolbox" \
    "$WORK/root/usr/share/zsh/vendor-completions/_pve-toolbox"
do
    [[ -f $target ]] || fail "package omitted ${target#"$WORK/root"}"
done
cmp -s "$ROOT/pve-toolbox" "$WORK/root/usr/bin/pve-toolbox" \
    || fail "packaged launcher differs from source"
cmp -s "$ROOT/completions/pve-toolbox.bash" \
    "$WORK/root/usr/share/bash-completion/completions/pve-toolbox" \
    || fail "packaged Bash completion differs from source"
cmp -s "$ROOT/completions/_pve-toolbox" \
    "$WORK/root/usr/share/zsh/vendor-completions/_pve-toolbox" \
    || fail "packaged Zsh completion differs from source"
[[ $(<"$WORK/root/usr/lib/pve-toolbox/VERSION") == "$(<VERSION)" ]] \
    || fail "packaged VERSION differs from source"
[[ ! -e $WORK/root/usr/lib/pve-toolbox/modules/_template ]] \
    || fail "package shipped the module template"
pass "package layout matches every runtime source"

control=$(dpkg-deb --field "$deb")
expected_version=$(<VERSION)
[[ $(dpkg-deb --field "$deb" Package) == pve-toolbox ]] \
    || fail "package has the wrong name"
[[ $(dpkg-deb --field "$deb" Version) == "$expected_version" ]] \
    || fail "package version does not match VERSION"
[[ $control == *'Architecture: all'* ]] || fail "package architecture is not all"
[[ $control == *'Depends: curl, jq'* ]] || fail "hard dependencies are incomplete"
[[ $control == *'Recommends: whiptail, zfsutils-linux'* ]] \
    || fail "recommended dependencies are incomplete"
[[ $control == *'Suggests: smartmontools, sanoid'* ]] \
    || fail "suggested dependencies are incomplete"
pass "package metadata"

[[ ! -e $WORK/control/conffiles ]] || fail "runtime config was declared as conffiles"
grep -q '/usr/local/bin/pve-toolbox' "$WORK/control/postinst" \
    || fail "postinst does not warn about a shadowing checkout"
grep -q 'targets Debian 13 (trixie) / PVE 9' "$WORK/control/postinst" \
    || fail "postinst does not warn on unsupported hosts"
grep -q '\[ "$1" = purge \]' "$WORK/control/postrm" \
    || fail "postrm does not distinguish purge from remove"
[[ $(stat -c '%a' "$WORK/root/etc/pve-toolbox") == 750 ]] \
    || fail "/etc/pve-toolbox is not mode 0750"
[[ $(stat -c '%a' "$WORK/root/var/lib/pve-toolbox") == 755 ]] \
    || fail "/var/lib/pve-toolbox is not mode 0755"
version=$(PVE_TOOLBOX_ROOT="$WORK/root/usr/lib/pve-toolbox" \
    "$WORK/root/usr/bin/pve-toolbox" --version)
[[ $version == "pve-toolbox $expected_version" ]] || fail "installed version is wrong: $version"
pass "package runtime paths and lifecycle"

if [[ ${PACKAGING_INSTALL_TEST_REQUIRED:-0} == 1 ]]; then
    [[ $EUID -eq 0 ]] || fail "the package install lifecycle test requires root"
    if dpkg-query -W -f='${db:Status-Status}' pve-toolbox 2>/dev/null \
        | grep -q '^installed$'; then
        fail "refusing to replace an existing pve-toolbox package"
    fi
    for path in /usr/bin/pve-toolbox /etc/pve-toolbox /var/lib/pve-toolbox; do
        [[ ! -e $path && ! -L $path ]] \
            || fail "refusing to replace an existing package path: $path"
    done
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
