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
pve-toolbox ui                 full-screen menu (needs whiptail)
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

## The full-screen ui

`pve-toolbox ui` is the same set of actions behind whiptail, which a PVE host
already has - it is what debconf draws its prompts with. On a stripped-down
Debian it may not be there, and `ui` says so rather than guessing; `apt install
whiptail` is the fix. Arrow keys move, space toggles a module, Enter confirms,
Esc goes back a level.

```
                 pve-toolbox
    Arrows move, Enter chooses, Esc quits.

      install   Install or reconfigure modules
      update    Update installed modules
      check     Check for updates, change nothing
      status    Show detailed status
      uninstall Remove installed modules
      quit      Exit

              <Ok>            <Cancel>
```

Picking an action opens a checklist of the modules it applies to, each with
its current status. `update`, `check` and `uninstall` only list what is
actually installed, and say so plainly instead of showing an empty box.
`uninstall` asks once more before it removes anything.

The widgets only ever *choose*. Modules prompt and print as they work, which
cannot happen inside a whiptail box, so once something is picked the screen is
handed back and the module runs exactly as it does from the command line. It
pauses for a keypress afterwards so the output stays readable.

Set `TUI_BIN=dialog` to use dialog instead; an override that is not installed
is reported rather than ignored. On a terminal neither can draw on (`TERM=dumb`,
which is what most CI containers set) `ui` refuses with a message rather than
appearing to quit the moment it starts - whiptail exits 1 in that case, the same
code it uses for Cancel, so it has to be caught before the first box.

The numeric menu at `pve-toolbox` with no arguments is unchanged.

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
make syntax    # bash -n everything
make lint      # shellcheck everything
make test      # syntax + tests/ against throwaway dirs
make test-tui  # drive `ui` through a pty, needs whiptail + expect
```

CI runs these on every push and pull request, plus the tests again inside a
`debian:13` container to match the PVE 9 host. The ui test skips wherever
whiptail is missing, so in practice it runs in that container, where CI marks
it required rather than skippable.
