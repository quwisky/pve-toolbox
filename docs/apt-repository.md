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

Google Release Please maintains one release pull request against `master` from
Conventional Commit history. Merging that pull request is the release
approval. It updates `CHANGELOG.md`, `VERSION`, and the release manifest; the
workflow synchronizes the same notes into `debian/changelog` on the release
branch.

Before version 1.0, `fix` commits produce a patch release, while `feat` and
breaking commits produce a minor release. Release notes show `feat`, `fix`,
`perf`, `docs`, and `deps`; routine `ci`, `test`, `style`, `build`, and `chore`
entries stay hidden unless they carry a breaking-change declaration. Weekly
Dependabot commits use the `deps` type.

The workflow also supports a guarded manual request from `master`. Supply a
new stable version such as `0.4.2`; the request fails if the version is not
newer or its tag or GitHub Release already exists. It still creates a release
pull request rather than bypassing review.

CI requires the portable tests, strict documentation build, and complete
Debian 13 suite through one stable aggregate check. The Debian job builds the
`.deb` once, records its SHA-256 digest, verifies every runtime source is in
the package, and carries those exact bytes through signed repository metadata,
APT update, candidate selection, download, and installation.

When the release pull request merges, Release Please creates the version tag
and a draft GitHub Release. A separate reusable CI invocation builds one `.deb`
on Debian 13 and carries its SHA-256 through every required test. Later jobs:

1. create GitHub/Sigstore build provenance for the tested package;
2. import `APT_SIGNING_KEY` only inside the protected `release` environment;
3. verify that key against `keys/pve-toolbox.asc` and publish signed `Release`,
   `Release.gpg`, and `InRelease` metadata;
4. retain and index the newest three stable package versions for rollback;
5. attach the `.deb`, SHA-256 manifest, and provenance bundle, publish the
   GitHub Release, and read it back to verify its tag, commit, assets, and
   latest stable status; and
6. build the documentation from that release commit, include the exact signed
   APT repository commit, recheck that the release is still latest, and deploy
   the combined site to Pages.

`RELEASE_PLEASE_TOKEN` is a repository secret so its pull-request updates
trigger CI. `APT_SIGNING_KEY` is an environment secret scoped to the `release`
environment and must match the committed public certificate. The release job
never exposes the signing secret to build, test, provenance, Pages, or final
GitHub Release jobs.

Rerunning a failed workflow is safe. The repository publisher stages and
verifies complete metadata before changing the `apt` checkout, restores the
previous contents if publication fails, accepts an identical version only when
its bytes match, and rejects same-version substitutions. Pages runs only after
the GitHub Release is public and verified. A Pages failure leaves that valid
release published so the failed jobs can be rerun. An older release run cannot
replace Pages after a newer stable release is public.

Verify a downloaded release package and its provenance with:

```bash
gh attestation verify pve-toolbox_0.4.2_all.deb \
  --repo quwisky/pve-toolbox
```

The release workflow is the only Pages publisher. Documentation changes on
`master` are validated by CI but remain unpublished until the next successful
release.
