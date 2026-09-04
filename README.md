# pve-toolbox

[![CI](https://github.com/quwisky/pve-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/quwisky/pve-toolbox/actions/workflows/ci.yml)
[![Release](https://github.com/quwisky/pve-toolbox/actions/workflows/release.yml/badge.svg)](https://github.com/quwisky/pve-toolbox/actions/workflows/release.yml)

Custom Proxmox VE host scripts behind one interactive launcher.

**📖 [Documentation](https://quwisky.github.io/pve-toolbox/)**

Each script is a *module*: a self-contained directory that knows how to install,
update, report on, and remove itself. The launcher discovers modules at runtime,
so adding a new script means dropping in a directory — no registry to edit.

```
pve-toolbox/
├── pve-toolbox              # launcher
├── lib/
│   ├── common.sh            # output, prompts, releases, systemd, state, conf
│   ├── discord.sh           # webhook reporting, also installed for helper scripts
│   ├── doctor.sh            # read-only host and module health checks
│   ├── pve.sh               # validated, read-only Proxmox API helpers
│   ├── report.sh            # versioned, redacted automation results
│   └── tui.sh               # whiptail/dialog widgets for `pve-toolbox ui`
├── modules/
│   ├── _template/           # copy this to start a new module (underscore = hidden)
│   ├── backup-audit/        # read-only guest backup protection and freshness audit
│   ├── certificate-watch/   # read-only cluster TLS and ACME health audit
│   ├── config-backup/       # snapshots /etc/pve and host config, reported to Discord
│   ├── lxc-update/          # confirmed or scheduled container package updates
│   ├── native-notifications/ # owned native PVE targets and matchers
│   ├── restore-drill/       # guarded isolated backup restore validation
│   ├── scrutiny-collectors/ # SMART/ZFS/MDADM collectors for a remote Scrutiny
│   ├── storage-hygiene/     # read-only snapshot, content, and capacity audit
│   ├── upgrade-readiness/   # read-only, policy-driven upgrade preflight
│   ├── zfs-scrub/           # scheduled scrub per pool, reported to Discord
│   └── zfs-replication/     # syncoid jobs on a timer, reported to Discord
├── migrations/              # ordered package configuration migrations
├── scripts/                 # package helpers and installation scripts
├── share/                   # package-owned notification templates
├── completions/             # bash + zsh completion, installed by `link`
├── tests/                   # what `make test` runs, incl. a driven ui test
├── docs/                    # mkdocs-material sources
└── Makefile                 # make syntax / lint / test
```

## Install on PVE 9

```bash
curl -fsSL https://raw.githubusercontent.com/quwisky/pve-toolbox/master/scripts/install-apt.sh | bash
pve-toolbox
```

The bootstrap verifies the downloaded signing key against the pinned
fingerprint, configures the signed `trixie` repository, and installs the
`pve-toolbox` package. Future releases arrive through `apt upgrade`.
Package upgrades back up and migrate older toolbox configuration before
restarting package-managed services; failed or interrupted migrations restore
the prior files and remain retryable.
When an upgrade transfers a toolbox-managed notification target and matcher to
PVE ownership, it preserves the PVE objects and protected credentials, tests
delivery, and then removes the obsolete toolbox copy of their configuration.
The trusted repository signing key has fingerprint
`C354 8BC5 2A3D 5375 57DB 2A7F 84A4 3B72 AE04 34F2`.

PVE 8 remains on the git-checkout installation path:

```bash
git clone https://github.com/quwisky/pve-toolbox.git /opt/pve-toolbox
cd /opt/pve-toolbox
./pve-toolbox link     # symlink into /usr/local/bin, plus completions
pve-toolbox            # interactive menu
```

Run it on the PVE host as root. Modules that need raw disk or `zpool` access
declare `MODULE_HOST_ONLY=1` and warn if they detect an LXC.

## Usage

```
pve-toolbox                    interactive menu
pve-toolbox ui                 full-screen menu (needs whiptail)
pve-toolbox list [tag]         list modules and their status
pve-toolbox install <mod>...   install specific modules
pve-toolbox update [mod]...    update (all installed if none given)
pve-toolbox check [mod]...     report available updates, change nothing
pve-toolbox status [mod]       detailed status
pve-toolbox doctor             read-only host and module health audit
pve-toolbox lxc-update [ID]...  update local running Debian/Ubuntu containers
pve-toolbox uninstall <mod>...
pve-toolbox self-update        git pull this checkout (git installs only)
pve-toolbox --version          print the installed version
```

Flags: `-y` non-interactive (modules read their env vars instead of prompting),
`-f` force, `--json` versioned output, `--quiet` exit-status-only output,
`-V` version, `-h` help. JSON and quiet output apply to `status`, `check`, and
`doctor`.

Use `pve-toolbox lxc-update --dry-run` as root on PVE 9 to preview container
package updates. Execution requires a terminal and confirmation; `--allow-removals`
enables removals and cleanup, and `--notify` sends an optional Discord summary.
Configure exclusions, the webhook, and optional automatic updates with
`pve-toolbox install lxc-update`. Automatic updates use a node-local systemd
timer and always keep the non-removing package policy.
See [LXC package updates](docs/modules/lxc-update.md) for safeguards and limitations.

`doctor` checks cluster quorum, failed units, ZFS pools, Proxmox storage,
recent failed tasks, pending reboots, and installed module health without
changing the host. See the [doctor
guide](https://quwisky.github.io/pve-toolbox/doctor/) for result states,
thresholds, and exit codes. The [automation
guide](https://quwisky.github.io/pve-toolbox/automation/) documents the JSON
schema, redaction, and monitoring examples.

`link` also installs bash and zsh completion for commands, module names and
tags. Candidates are queried from the launcher, so a new module completes
without regenerating anything. See
[Getting started](https://quwisky.github.io/pve-toolbox/getting-started/#shell-completion).

## Modules

| Module | What it does |
| --- | --- |
| [backup-audit](https://quwisky.github.io/pve-toolbox/modules/backup-audit/) | Finds uncovered guests, stale or failed backups, excluded volumes, weak retention, and unhealthy backup storage |
| [certificate-watch](https://quwisky.github.io/pve-toolbox/modules/certificate-watch/) | Checks cluster TLS expiry, hostname coverage, chains, reachability, and ACME task history |
| [lxc-update](https://quwisky.github.io/pve-toolbox/modules/lxc-update/) | Updates local running Debian/Ubuntu containers through confirmed runs or an opt-in safe schedule, with exclusions, previews, and optional Discord reporting |
| [config-backup](https://quwisky.github.io/pve-toolbox/modules/config-backup/) | Snapshots `/etc/pve` and host config into verified tar.gz archives on a timer |
| [native-notifications](https://quwisky.github.io/pve-toolbox/modules/native-notifications/) | Provisions owned PVE notification targets and matchers with protected credentials and rollback |
| [restore-drill](https://quwisky.github.io/pve-toolbox/modules/restore-drill/) | Plans and explicitly runs isolated, ownership-checked VM or container restore drills |
| [storage-hygiene](https://quwisky.github.io/pve-toolbox/modules/storage-hygiene/) | Audits old snapshots, unreferenced-looking storage, stale content, and capacity pressure without cleanup |
| [upgrade-readiness](https://quwisky.github.io/pve-toolbox/modules/upgrade-readiness/) | Reports repository, package, space, cluster, service, storage, and backup blockers before upgrades |
| [zfs-scrub](https://quwisky.github.io/pve-toolbox/modules/zfs-scrub/) | Scrubs each pool on its own timer, reports start and result to Discord |
| [zfs-replication](https://quwisky.github.io/pve-toolbox/modules/zfs-replication/) | Runs `syncoid` jobs on timers, reports duration and size to Discord |
| [scrutiny-collectors](https://quwisky.github.io/pve-toolbox/modules/scrutiny-collectors/) | SMART / ZFS / MDADM collectors feeding a remote Scrutiny instance |

## Writing a module

```bash
cp -r modules/_template modules/my-thing
$EDITOR modules/my-thing/module.sh
```

Set the metadata (`MODULE_NAME` must match the directory name) and implement
`module_install`, `module_update`, `module_status`, `module_uninstall`.
`module_status_long` and the read-only `module_doctor` health hook are optional.

Two rules:

- **Keep the file side-effect free at source time.** The launcher sources every
  module just to read its metadata for the menu.
- **State is `0644`, config is `0600`.** Facts go through `state_set` into
  `/var/lib/pve-toolbox/`; secrets go through `conf_set` into
  `/etc/pve-toolbox/`.

Full contract, helper reference and the Discord reporting API:
**[Writing a module](https://quwisky.github.io/pve-toolbox/writing-a-module/)**.

## Development

```bash
make syntax    # bash -n everything
make lint      # shellcheck scripts and actionlint workflows
make test      # syntax + tests/ against throwaway dirs
make test-tui  # drive `ui` through a pty, needs whiptail + expect
```

`make lint` requires
[ShellCheck](https://www.shellcheck.net/) and
[actionlint](https://github.com/rhysd/actionlint). CI runs the portable suite,
strict documentation build, and complete Debian 13 package suite as separate
jobs. One stable aggregate job requires all three. The Debian job builds one
`.deb`, then passes that exact file through package, repository, APT download,
and install checks. The ui test is required there rather than skippable.
Root-only package lifecycle and APT consumer checks run only when their
required-gate variables are set, and must be used on a clean disposable host.

Releases are proposed from Conventional Commits by Google Release Please.
Merging its release pull request approves a draft-first, provenance-attested
publication; see [APT repository and releases](docs/apt-repository.md#publishing-a-release).

```bash
pip install -r docs/requirements.txt
mkdocs serve
```
