#!/usr/bin/env bash
# Build a package, publish it into an ephemeral signed repository, and verify it.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

commands=(dpkg-deb gpg gpgv reprepro)
[[ -n ${PACKAGE_DEB:-} ]] || commands+=(dpkg-buildpackage)
[[ -z ${PACKAGE_DEB_SHA256:-} ]] || commands+=(sha256sum)
for command in "${commands[@]}"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        [[ ${REPOSITORY_TEST_REQUIRED:-0} == 1 ]] && fail "$command is required"
        printf 'skip repository test, no %s\n' "$command"
        exit 0
    fi
done
if [[ -z ${PACKAGE_DEB:-} ]] && ! dpkg-checkbuilddeps >/dev/null 2>&1; then
    [[ ${REPOSITORY_TEST_REQUIRED:-0} == 1 ]] && fail "Debian build dependencies are missing"
    printf 'skip repository test, Debian build dependencies are missing\n'
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
    [[ -n $deb ]] || fail "package build produced no .deb"
fi

if [[ -n ${PACKAGE_DEB_SHA256:-} ]]; then
    [[ $PACKAGE_DEB_SHA256 =~ ^[0-9a-f]{64}$ ]] \
        || fail "PACKAGE_DEB_SHA256 is not a lowercase SHA-256 digest"
    actual_sha=$(sha256sum "$deb" | awk '{print $1}')
    [[ $actual_sha == "$PACKAGE_DEB_SHA256" ]] \
        || fail "prebuilt package digest changed before repository validation"
fi
[[ $(dpkg-deb --field "$deb" Package) == pve-toolbox ]] \
    || fail "repository test received the wrong package"
[[ $(dpkg-deb --field "$deb" Version) == "$(<VERSION)" ]] \
    || fail "repository package version does not match VERSION"

export GNUPGHOME="$WORK/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --passphrase "" \
    --quick-gen-key "pve-toolbox test <test@example.invalid>" ed25519 sign 1d \
    >/dev/null 2>&1
fingerprint=$(gpg --batch --with-colons --list-secret-keys \
    | awk -F: '$1 == "fpr" { print $10; exit }')
[[ $fingerprint =~ ^[0-9A-F]{40}$ ]] || fail "test key has no usable fingerprint"
public_key="$WORK/test-signing-key.asc"
gpg --batch --armor --export "$fingerprint" > "$public_key"

trusted_fingerprint=$(sed -n \
    's/^expected_fingerprint="${PVE_TOOLBOX_APT_FINGERPRINT:-\([0-9A-Fa-f]*\)}"$/\1/p' \
    scripts/install-apt.sh)
committed_fingerprint=$(gpg --batch --with-colons --show-keys keys/pve-toolbox.asc \
    | awk -F: '$1 == "fpr" { print $10; exit }')
[[ -n $trusted_fingerprint && ${trusted_fingerprint^^} == "${committed_fingerprint^^}" ]] \
    || fail "APT installer fingerprint does not match the committed public key"

mismatch_repo="$WORK/mismatch-repository"
if ./scripts/publish-apt-repo.sh \
    "$mismatch_repo" "$deb" "$fingerprint" keys/pve-toolbox.asc \
    >/dev/null 2>&1; then
    fail "publisher accepted a mismatched public key"
fi

repo="$WORK/repository"
./scripts/publish-apt-repo.sh \
    "$repo" "$deb" "$fingerprint" "$public_key" >/dev/null
# A workflow retry after the APT branch was pushed must be a no-op, not a
# blocker that prevents the GitHub Release or Pages steps from running.
./scripts/publish-apt-repo.sh \
    "$repo" "$deb" "$fingerprint" "$public_key" >/dev/null \
    || fail "repository publisher rejected an identical retry"
mkdir -p "$WORK/conflicting-package"
dpkg-deb --raw-extract "$deb" "$WORK/conflicting-package"
mkdir -p "$WORK/conflicting-package/usr/share/pve-toolbox"
printf 'different build\n' > "$WORK/conflicting-package/usr/share/pve-toolbox/retry-conflict"
conflicting_deb="$WORK/conflicting.deb"
dpkg-deb --build "$WORK/conflicting-package" "$conflicting_deb" >/dev/null
if ./scripts/publish-apt-repo.sh \
    "$repo" "$conflicting_deb" "$fingerprint" "$public_key" >/dev/null 2>&1; then
    fail "repository publisher replaced an existing version with different bytes"
fi
expected="trixie|main|amd64: pve-toolbox $(<VERSION)"
[[ $(reprepro --basedir "$repo" list trixie) == "$expected" ]] \
    || fail "repository index did not contain the package"
[[ -s $repo/dists/trixie/main/binary-amd64/Packages.gz ]] \
    || fail "repository omitted the amd64 package index"
cmp -s "$public_key" "$repo/pve-toolbox.asc" \
    || fail "repository omitted the armored public key"
gpgv --keyring "$repo/pve-toolbox.gpg" \
    "$repo/dists/trixie/Release.gpg" "$repo/dists/trixie/Release" \
    >/dev/null 2>&1 || fail "repository Release signature did not verify"
gpgv --keyring "$repo/pve-toolbox.gpg" "$repo/dists/trixie/InRelease" \
    >/dev/null 2>&1 || fail "repository InRelease signature did not verify"
pass "signed APT repository metadata"

if [[ $EUID -ne 0 ]]; then
    [[ ${REPOSITORY_TEST_REQUIRED:-0} == 1 ]] \
        && fail "the required APT consumer test must run as root"
    printf 'skip APT consumer test, root is required\n'
    exit 0
fi
for command in apt-get apt-cache dpkg dpkg-query; do
    command -v "$command" >/dev/null 2>&1 \
        || fail "$command is required for the APT consumer test"
done
if dpkg-query -W -f='${db:Status-Status}' pve-toolbox 2>/dev/null \
    | grep -q '^installed$'; then
    fail "refusing to replace an existing pve-toolbox package"
fi

apt_root="$WORK/apt-consumer"
source_file="$apt_root/pve-toolbox.sources"
mkdir -p "$apt_root/lists/partial" "$apt_root/cache/partial" "$apt_root/download"
printf '%s\n' \
    'Types: deb' \
    "URIs: file:$repo" \
    'Suites: trixie' \
    'Components: main' \
    'Architectures: amd64' \
    "Signed-By: $repo/pve-toolbox.gpg" \
    > "$source_file"
apt_options=(
    -o "Dir::Etc::sourcelist=$source_file"
    -o Dir::Etc::sourceparts=-
    -o "Dir::State::lists=$apt_root/lists"
    -o "Dir::Cache::archives=$apt_root/cache"
    -o APT::Get::List-Cleanup=0
    -o APT::Sandbox::User=root
)
apt-get "${apt_options[@]}" update >/dev/null
candidate=$(apt-cache "${apt_options[@]}" policy pve-toolbox \
    | awk '$1 == "Candidate:" {print $2}')
[[ $candidate == "$(<VERSION)" ]] || fail "APT selected unexpected candidate $candidate"
(cd "$apt_root/download" && apt-get "${apt_options[@]}" download pve-toolbox >/dev/null)
downloaded=$(find "$apt_root/download" -maxdepth 1 -type f -name 'pve-toolbox_*.deb' \
    -print -quit)
[[ -n $downloaded ]] || fail "APT did not download pve-toolbox"
cmp -s "$deb" "$downloaded" || fail "APT downloaded bytes differ from the tested package"

PACKAGE_TOUCHED=1
apt-get "${apt_options[@]}" --no-install-recommends -y install pve-toolbox >/dev/null
[[ $(/usr/bin/pve-toolbox --version) == "pve-toolbox $(<VERSION)" ]] \
    || fail "APT installed an unexpected pve-toolbox version"
dpkg --purge pve-toolbox >/dev/null
PACKAGE_TOUCHED=0
pass "APT update, policy, download, and install use the tested package"
