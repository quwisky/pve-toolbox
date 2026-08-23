# pve-toolbox

[![CI](https://github.com/quwisky/pve-toolbox/actions/workflows/ci.yml/badge.svg)](https://github.com/quwisky/pve-toolbox/actions/workflows/ci.yml)
[![Docs](https://github.com/quwisky/pve-toolbox/actions/workflows/docs.yml/badge.svg)](https://github.com/quwisky/pve-toolbox/actions/workflows/docs.yml)

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
│   └── tui.sh               # whiptail/dialog widgets for `pve-toolbox ui`
├── modules/
│   ├── _template/           # copy this to start a new module (underscore = hidden)
│   ├── scrutiny-collectors/ # SMART/ZFS/MDADM collectors for a remote Scrutiny
│   ├── zfs-scrub/           # scheduled scrub per pool, reported to Discord
│   └── zfs-replication/     # syncoid jobs on a timer, reported to Discord
├── completions/             # bash + zsh completion, installed by `link`
├── tests/                   # what `make test` runs, incl. a driven ui test
├── docs/                    # mkdocs-material sources
└── Makefile                 # make syntax / lint / test
```

## Install

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
pve-toolbox uninstall <mod>...
pve-toolbox self-update        git pull this checkout
```

Flags: `-y` non-interactive (modules read their env vars instead of prompting),
`-f` force, `-h` help.

`link` also installs bash and zsh completion for commands, module names and
tags. Candidates are queried from the launcher, so a new module completes
without regenerating anything. See
[Getting started](https://quwisky.github.io/pve-toolbox/getting-started/#shell-completion).

## Modules

| Module | What it does |
| --- | --- |
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
`module_status_long` is optional and falls back to `module_status`.

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
make lint      # shellcheck everything
make test      # syntax + tests/ against throwaway dirs
make test-tui  # drive `ui` through a pty, needs whiptail + expect
```

CI runs these on every push and pull request, plus the tests again inside a
`debian:13` container to match the PVE 9 host. The ui test only runs there,
since that container is the one with whiptail. The docs build with
`mkdocs build --strict`, so a broken internal link fails the build.

```bash
pip install -r docs/requirements.txt
mkdocs serve
```
