#!/usr/bin/env bash
# Build a package, publish it into an ephemeral signed repository, and verify it.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

for command in dpkg-buildpackage gpg gpgv reprepro; do
    if ! command -v "$command" >/dev/null 2>&1; then
        [[ ${REPOSITORY_TEST_REQUIRED:-0} == 1 ]] && fail "$command is required"
        printf 'skip repository test, no %s\n' "$command"
        exit 0
    fi
done
if ! dpkg-checkbuilddeps >/dev/null 2>&1; then
    [[ ${REPOSITORY_TEST_REQUIRED:-0} == 1 ]] && fail "Debian build dependencies are missing"
    printf 'skip repository test, Debian build dependencies are missing\n'
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"
tar --exclude=.git --exclude=site --exclude='*.deb' -cf - . \
    | tar -xf - -C "$WORK/src"
(cd "$WORK/src" && dpkg-buildpackage --build=binary --no-sign >/dev/null)
deb=$(find "$WORK" -maxdepth 1 -name 'pve-toolbox_*_all.deb' -print -quit)
[[ -n $deb ]] || fail "package build produced no .deb"

export GNUPGHOME="$WORK/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --passphrase "" \
    --quick-gen-key "pve-toolbox test <test@example.invalid>" ed25519 sign 1d \
    >/dev/null 2>&1
fingerprint=$(gpg --batch --with-colons --list-secret-keys \
    | awk -F: '$1 == "fpr" { print $10; exit }')
[[ $fingerprint =~ ^[0-9A-F]{40}$ ]] || fail "test key has no usable fingerprint"

repo="$WORK/repository"
./scripts/publish-apt-repo.sh "$repo" "$deb" "$fingerprint" >/dev/null
expected="trixie|main|amd64: pve-toolbox $(<VERSION)"
[[ $(reprepro --basedir "$repo" list trixie) == "$expected" ]] \
    || fail "repository index did not contain the package"
[[ -s $repo/dists/trixie/main/binary-amd64/Packages.gz ]] \
    || fail "repository omitted the amd64 package index"
gpgv --keyring "$repo/pve-toolbox.gpg" \
    "$repo/dists/trixie/Release.gpg" "$repo/dists/trixie/Release" \
    >/dev/null 2>&1 || fail "repository Release signature did not verify"
pass "signed APT repository"
