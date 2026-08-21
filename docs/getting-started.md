# Getting started

## Install

```bash
git clone https://github.com/quwisky/pve-toolbox.git /opt/pve-toolbox
cd /opt/pve-toolbox
./pve-toolbox link     # symlink into /usr/local/bin
pve-toolbox            # interactive menu
```

Run it on the PVE host as root. Modules that need raw disk or `zpool` access
declare `MODULE_HOST_ONLY=1` and warn if they detect an LXC.

## Commands

```
pve-toolbox                    interactive menu
pve-toolbox list [tag]         list modules and their status
pve-toolbox install <mod>...   install specific modules
pve-toolbox update [mod]...    update (all installed if none given)
pve-toolbox check [mod]...     report available updates, change nothing
pve-toolbox status [mod]       detailed status
pve-toolbox uninstall <mod>...
pve-toolbox self-update        git pull this checkout
```

Flags: `-y` non-interactive (modules read their env vars instead of
prompting), `-f` force, `-h` help.

## The menu

Type numbers to toggle selection, then a letter for the action:

```
    #  MODULE                   STATUS      DESCRIPTION
 *  1) Scrutiny collectors      v1.67.0     SMART / ZFS / MDADM collectors...
    2) ZFS scrub + Discord      pools:3     scheduled scrub per pool...
    3) ZFS replication          jobs:1      syncoid jobs on a timer...

  i install/reconfigure selected   u update all installed
  c check for updates              s status of selected
  x uninstall selected             q quit
```

## Unattended checks

`check` changes nothing, which makes it safe on a timer:

```bash
DISCORD_WEBHOOK=https://discord.com/api/webhooks/<id>/<token>

pve-toolbox check 2>&1 | grep -q 'update available' && \
  curl -sf -X POST "$DISCORD_WEBHOOK" \
       -H 'Content-Type: application/json' \
       -d "{\"content\": \"pve-toolbox updates available on $(hostname -s)\"}"
```

## Non-interactive install

Every module reads env vars in place of prompts under `-y`:

```bash
ZFS_SCRUB_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>' \
ZFS_SCRUB_POOLS='rpool tank' \
  pve-toolbox -y install zfs-scrub
```

The per-module pages list the variables each one accepts.

## Development

```bash
make syntax  # bash -n everything
make lint    # shellcheck everything
make test    # syntax + launcher smoke test against throwaway dirs
```

CI runs all three on every push and pull request, plus the smoke test again
inside a `debian:13` container to match the PVE 9 host.
