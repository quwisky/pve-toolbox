# APT repository

The package repository supports PVE 9 / Debian 13 (`trixie`) only. PVE 8 hosts
should keep using the [git checkout](getting-started.md#git-checkout).

## Bootstrap

The installer verifies the host suite before making changes, checks the
downloaded repository key against the fingerprint pinned in the script, writes
a deb822 source, and installs the package:

```bash
curl -fsSL https://raw.githubusercontent.com/quwisky/pve-toolbox/master/scripts/install-apt.sh | bash
```

## Manual setup

Run these commands as `root` on a PVE 9 / Debian 13 (`trixie`) `amd64` host.
First install the HTTPS prerequisites and add the repository signing key to the
operator-managed keyring directory:

```bash
apt-get update
apt-get install -y ca-certificates curl gnupg
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://quwisky.github.io/pve-toolbox/apt/pve-toolbox.gpg \
  -o /etc/apt/keyrings/pve-toolbox.gpg
chmod 0644 /etc/apt/keyrings/pve-toolbox.gpg

expected=C3548BC52A3D537557DB2A7F84A43B72AE0434F2
actual=$(gpg --batch --with-colons --show-keys \
  /etc/apt/keyrings/pve-toolbox.gpg | awk -F: '$1 == "fpr" { print $10; exit }')
test "$actual" = "$expected"
```

Create `/etc/apt/sources.list.d/pve-toolbox.sources` with this deb822 source:

```text
Types: deb
URIs: https://quwisky.github.io/pve-toolbox/apt/
Suites: trixie
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/pve-toolbox.gpg
```

For example:

```bash
cat > /etc/apt/sources.list.d/pve-toolbox.sources <<'EOF'
Types: deb
URIs: https://quwisky.github.io/pve-toolbox/apt/
Suites: trixie
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/pve-toolbox.gpg
EOF

apt-get update
apt-get install -y pve-toolbox
```

APT now accepts packages from this repository only when its Release metadata
is signed by the installed key. Confirm the configured package source with:

```bash
apt-cache policy pve-toolbox
```

The binary keyring is published at
`https://quwisky.github.io/pve-toolbox/apt/pve-toolbox.gpg`, with an armored
copy at `https://quwisky.github.io/pve-toolbox/apt/pve-toolbox.asc`. It is
scoped to this source through `Signed-By`; it is not added to the system-wide
trusted keyring. Its primary fingerprint is:

```text
C354 8BC5 2A3D 5375 57DB  2A7F 84A4 3B72 AE04 34F2
```

## Package contents

The native, architecture-independent package starts at version `0.1.0`. The
repository indexes it for `amd64`, the PVE host architecture, because Debian
repositories place `Architecture: all` packages in each concrete client
architecture index. It installs:

| Path | Purpose |
| --- | --- |
| `/usr/bin/pve-toolbox` | launcher |
| `/usr/lib/pve-toolbox/lib/` | shared launcher libraries |
| `/usr/lib/pve-toolbox/modules/` | runtime modules; `_template` is excluded |
| `/usr/share/bash-completion/completions/pve-toolbox` | Bash completion |
| `/usr/share/zsh/vendor-completions/_pve-toolbox` | Zsh completion |
| `/etc/pve-toolbox/` | generated config and secrets, directory mode `0750` |
| `/var/lib/pve-toolbox/` | generated state, directory mode `0755` |

`curl` and `jq` are hard dependencies. `whiptail` and `zfsutils-linux` are
recommended; `smartmontools` and `sanoid` remain suggestions because only the
modules that use them need them.

Runtime config is not a dpkg conffile. Removing the package preserves both
config and state; purging removes them. Module-installed helpers and systemd
units under `/usr/local` and `/etc/systemd/system` remain owned by their
modules, not by the package.

## Checkout migration

`/usr/local/bin` precedes `/usr/bin` on the default root path. If a previous
`pve-toolbox link` symlink is still present, package installation warns because
that checkout would continue to shadow the package. It never deletes the
operator-owned symlink automatically.

Packaged installs reject `pve-toolbox link` and `pve-toolbox self-update`.
Upgrade them with:

```bash
apt update
apt upgrade pve-toolbox
```

## Publishing a release

A tag such as `v0.1.0` must match both `VERSION` and `debian/changelog`. The
release workflow can run from that tag, or be started manually from `master`.
A manual run derives the tag from `VERSION` and refuses any other branch or an
existing tag.

The workflow requires every test group, including the terminal UI, both shell
completions, config-backup gates, package lifecycle, and signed repository
tests. It then builds the `.deb`, imports the dedicated
signing subkey from the `APT_SIGNING_KEY` Actions secret, and verifies that it
matches the public certificate committed at `keys/pve-toolbox.asc`. It updates
the signed `trixie/main` repository on the `apt` branch, publishes both public
key formats, then creates a GitHub Release with generated changelog notes and
attaches the package plus its SHA-256 manifest.

Rerunning the same failed workflow is safe: an identical package already
present in the APT repository is kept and later release or Pages steps
continue. A different package with the same version is refused. A new manual
run still refuses an existing tag or GitHub Release; only a retry attempt of
the original run may resume it, and its tag must target the same commit.

Pages is assembled from the MkDocs site and the `apt` branch. The docs and
release workflows share one deployment concurrency group so neither can erase
or race the other.
