#!/usr/bin/env bash
# Bootstrap the signed pve-toolbox APT repository on PVE 9 / Debian 13.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "error: run this installer as root" >&2; exit 1; }

# shellcheck source=/dev/null
source /etc/os-release
if [[ ${VERSION_CODENAME:-} != trixie ]]; then
    echo "error: the APT repository supports Debian 13 (trixie) / PVE 9 only" >&2
    echo "use the git-clone installation on older PVE releases" >&2
    exit 1
fi
if [[ $(dpkg --print-architecture) != amd64 ]]; then
    echo "error: the PVE 9 APT repository is published for amd64 hosts" >&2
    exit 1
fi

repo_url="${PVE_TOOLBOX_APT_URL:-https://quwisky.github.io/pve-toolbox/apt}"
keyring=/etc/apt/keyrings/pve-toolbox.gpg
source_file=/etc/apt/sources.list.d/pve-toolbox.sources
tmp_key=$(mktemp)
tmp_source=$(mktemp)
trap 'rm -f "$tmp_key" "$tmp_source"' EXIT

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl

curl -fsSL --retry 3 "$repo_url/pve-toolbox.gpg" -o "$tmp_key"
[[ -s $tmp_key ]] || { echo "error: downloaded repository key is empty" >&2; exit 1; }

cat > "$tmp_source" <<EOF
Types: deb
URIs: $repo_url/
Suites: trixie
Components: main
Architectures: amd64
Signed-By: $keyring
EOF

install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$tmp_key" "$keyring"
install -m 0644 "$tmp_source" "$source_file"

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y pve-toolbox
