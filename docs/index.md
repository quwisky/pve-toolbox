# pve-toolbox

Custom Proxmox VE host scripts behind one interactive launcher.

Each script is a *module*: a self-contained directory that knows how to
install, update, report on, and remove itself. The launcher discovers modules
at runtime, so adding a new script means dropping in a directory — there is no
registry to edit.

```
pve-toolbox/
├── pve-toolbox              # launcher
├── lib/
│   ├── common.sh            # output, prompts, releases, systemd, state, conf
│   ├── discord.sh           # webhook reporting
│   ├── doctor.sh            # read-only host and module health checks
│   ├── report.sh            # versioned, redacted automation results
│   └── tui.sh               # whiptail widgets behind `pve-toolbox ui`
├── modules/
│   ├── _template/           # copy this to start a new module
│   ├── backup-audit/
│   ├── certificate-watch/
│   ├── config-backup/
│   ├── native-notifications/
│   ├── scrutiny-collectors/
│   ├── storage-hygiene/
│   ├── zfs-scrub/
│   └── zfs-replication/
├── completions/             # bash + zsh, installed by `link`
├── tests/                   # smoke tests, and a pty-driven test for the ui
└── Makefile                 # make syntax / lint / test
```

## Modules

| Module | What it does |
| --- | --- |
| [backup-audit](modules/backup-audit.md) | Read-only guest backup coverage, freshness, retention, and storage audit |
| [certificate-watch](modules/certificate-watch.md) | Read-only cluster certificate, chain, hostname, and ACME health audit |
| [config-backup](modules/config-backup.md) | Timestamped snapshots of `/etc/pve` and host config, reported to Discord |
| [native-notifications](modules/native-notifications.md) | Owned native PVE targets and matchers with protected secrets and tested delivery |
| [storage-hygiene](modules/storage-hygiene.md) | Read-only snapshots, content ownership, storage definitions, and capacity audit |
| [zfs-scrub](modules/zfs-scrub.md) | Scrubs each pool on its own timer, reports start and result to Discord |
| [zfs-replication](modules/zfs-replication.md) | Runs `syncoid` jobs on timers, reports duration and size to Discord |
| [scrutiny-collectors](modules/scrutiny-collectors.md) | SMART / ZFS / MDADM collectors feeding a remote Scrutiny instance |

## Design

Three ideas hold the whole thing together.

**Modules are discovered, not registered.** The launcher globs
`modules/*/module.sh`, sources each one to read its metadata, and builds the
menu from that. A directory starting with `_` is skipped.

**Modules are isolated.** Every module function runs in a subshell, so module
globals cannot leak into the launcher or into each other. Metadata is read in
a separate subshell again, which is why a module file must stay side-effect
free at source time.

**State and config are different things.** What the module knows goes in
`/var/lib/pve-toolbox/<module>.state` at `0644`. What the operator set — a
token, a webhook URL — goes in `/etc/pve-toolbox/<module>.conf` at `0600`.
See [Writing a module](writing-a-module.md#state-versus-config).

!!! note "Where things land"

    | Path | Contents | Mode |
    | --- | --- | --- |
    | `/usr/bin/pve-toolbox` | packaged launcher | `0755` |
    | `/usr/lib/pve-toolbox/` | packaged libraries and real modules | `0755` |
    | `/usr/local/bin/` | checkout launcher symlink and module helper scripts | `0755` |
    | `/usr/local/lib/pve-toolbox/` | shared libs the helpers source | `0644` |
    | `/etc/pve-toolbox/` | per-module config, secrets included | `0600` |
    | `/var/lib/pve-toolbox/` | per-module state | `0644` |
    | `/var/log/pve-toolbox/` | per-job logs | `0640` |
    | `/etc/systemd/system/` | units and timers | `0644` |
    | `/usr/share/bash-completion/completions/` | bash completion symlink | `0644` |
    | `/usr/share/zsh/vendor-completions/` | zsh completion symlink | `0644` |

    Every one of these is overridable — `TOOLBOX_BIN_DIR`, `TOOLBOX_LIB_DIR`,
    `TOOLBOX_CONF_DIR`, `TOOLBOX_STATE_DIR`, `TOOLBOX_SYSTEMD_DIR`,
    `TOOLBOX_BASH_COMPLETION_DIR`, `TOOLBOX_ZSH_COMPLETION_DIR` — which is what
    makes the modules testable off a real host.

    The two completion paths are regular package files under an APT install.
    For a checkout, `link` symlinks into them so `self-update` refreshes them,
    and skips either directory that is not already there rather than creating
    a tree for a shell that is not installed.
