#!/usr/bin/env bash
# Add a package to the signed trixie repository rooted at the given directory.
set -euo pipefail

[[ $# -eq 4 ]] || {
    echo "usage: $0 <repository-dir> <deb> <signing-key-fingerprint> <public-key>" >&2
    exit 2
}

repo_dir=$1
deb=$2
fingerprint=$3
public_key=$4
[[ -f $deb ]] || { echo "error: package not found: $deb" >&2; exit 1; }
[[ -f $public_key ]] || { echo "error: public key not found: $public_key" >&2; exit 1; }
[[ $fingerprint =~ ^[0-9A-Fa-f]{40}$ ]] \
    || { echo "error: expected a 40-character signing-key fingerprint" >&2; exit 1; }

public_fingerprint=$(gpg --batch --with-colons --show-keys "$public_key" \
    | awk -F: '$1 == "fpr" { print $10; exit }')
[[ ${public_fingerprint^^} == "${fingerprint^^}" ]] || {
    echo "error: signing key does not match the committed public key" >&2
    exit 1
}

mkdir -p "$repo_dir/conf"
cat > "$repo_dir/conf/distributions" <<EOF
Origin: pve-toolbox
Label: pve-toolbox
Codename: trixie
Suite: trixie
Architectures: amd64
Components: main
Description: pve-toolbox packages for PVE 9 / Debian 13
SignWith: $fingerprint
EOF

# Publishing is retryable after a later workflow step fails. An identical
# package already in the pool is success; the same package/version with
# different bytes is a conflict and must never be silently replaced.
package=$(dpkg-deb --field "$deb" Package)
version=$(dpkg-deb --field "$deb" Version)
architecture=$(dpkg-deb --field "$deb" Architecture)
existing=""
while IFS= read -r -d '' candidate; do
    [[ $(dpkg-deb --field "$candidate" Package) == "$package" ]] || continue
    [[ $(dpkg-deb --field "$candidate" Version) == "$version" ]] || continue
    [[ $(dpkg-deb --field "$candidate" Architecture) == "$architecture" ]] || continue
    existing=$candidate
    break
done < <(find "$repo_dir/pool" -type f -name '*.deb' -print0 2>/dev/null)

if [[ -n $existing ]]; then
    cmp -s "$deb" "$existing" || {
        echo "error: $package $version is already published with different bytes" >&2
        exit 1
    }
    echo "$package $version is already present; keeping the identical package"
else
    reprepro --basedir "$repo_dir" includedeb trixie "$deb"
fi
install -m 0644 "$public_key" "$repo_dir/pve-toolbox.asc"
gpg --batch --yes --dearmor \
    --output "$repo_dir/pve-toolbox.gpg" "$public_key"
