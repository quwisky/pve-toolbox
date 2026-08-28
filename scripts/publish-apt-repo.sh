#!/usr/bin/env bash
# Add a package to the signed trixie repository rooted at the given directory.
set -euo pipefail

[[ $# -eq 3 ]] || {
    echo "usage: $0 <repository-dir> <deb> <signing-key-fingerprint>" >&2
    exit 2
}

repo_dir=$1
deb=$2
fingerprint=$3
[[ -f $deb ]] || { echo "error: package not found: $deb" >&2; exit 1; }
[[ $fingerprint =~ ^[0-9A-Fa-f]{40}$ ]] \
    || { echo "error: expected a 40-character signing-key fingerprint" >&2; exit 1; }

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

reprepro --basedir "$repo_dir" includedeb trixie "$deb"
gpg --batch --yes --output "$repo_dir/pve-toolbox.gpg" --export "$fingerprint"
