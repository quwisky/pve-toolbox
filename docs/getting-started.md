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

## Shell completion

`pve-toolbox link` also symlinks completions for bash and zsh into
`/usr/share/bash-completion/completions/` and
`/usr/share/zsh/vendor-completions/`. A directory that is not there is skipped
rather than created, so if you install zsh later, run `link` again. They are
symlinks into the checkout, so `self-update` refreshes them with everything
else.

Open a new shell, then:

```
pve-toolbox <TAB>              commands
pve-toolbox list <TAB>         tags, gathered from every module
pve-toolbox install <TAB>      module names
pve-toolbox uninstall <TAB>    only the modules actually installed
pve-toolbox -<TAB>             flags
```

Candidates come from `pve-toolbox _complete`, not from a list baked into the
completion scripts, so a module dropped into `modules/` is completable straight
away with nothing to regenerate. Names already on the line are not offered a
second time.

`uninstall` is the one target that has to ask every module whether it is
installed, so that TAB can pause for a moment; the others only read metadata.

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
make test    # syntax + tests/smoke.sh against throwaway dirs
```

CI runs all three on every push and pull request, plus the smoke test again
inside a `debian:13` container to match the PVE 9 host.
