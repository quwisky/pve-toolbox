# Getting started

## Install on PVE 9

The signed APT repository supports PVE 9 / Debian 13 (`trixie`):

```bash
curl -fsSL https://raw.githubusercontent.com/quwisky/pve-toolbox/master/scripts/install-apt.sh | bash
pve-toolbox
```

The bootstrap installs a key at `/etc/apt/keyrings/pve-toolbox.gpg`, writes a
deb822 source at `/etc/apt/sources.list.d/pve-toolbox.sources`, and installs the
package. Normal `apt upgrade` runs then keep it current. See
[APT repository](apt-repository.md) for the manual setup and package layout.

If `/usr/local/bin/pve-toolbox` still points to an older checkout, it precedes
`/usr/bin` in the default root `PATH`. Package installation warns about that
symlink but never removes it automatically; verify the packaged command and
remove the old symlink yourself.

## Package upgrade migrations

Package upgrades may include migrations for configuration created by an older
release. They run automatically during `apt upgrade`, before package-managed
services are restarted, and never prompt for input. A fresh installation does
not initialize or run migrations.

Before a migration changes a file, the package copies it with its ownership and
permissions into `/var/backups/pve-toolbox/migrations/`. Completed migration IDs
are recorded in `/var/lib/pve-toolbox/migrations.state`, so reinstalling or
retrying the package does not repeat completed work.

If a migration fails, its declared files and systemd unit state are restored
and dpkg leaves `pve-toolbox` unconfigured. Read the named migration and backup
path in the error, correct the underlying problem, and retry as root:

```bash
dpkg --configure pve-toolbox
```

An interrupted migration is restored from its retained backup before the same
migration is attempted again. Do not delete
`/var/lib/pve-toolbox/migration.pending` or its referenced backup while recovery
is pending.

The notification ownership migration verifies the legacy toolbox identity,
the PVE target and matcher, the shipped templates, and both target and custom
event delivery. It then removes only
`/etc/pve-toolbox/native-notifications.conf` and
`/var/lib/pve-toolbox/native-notifications.state`. The target, matcher, enabled
state, routing rules, templates, and protected PVE credentials remain in PVE.
The verification sends one PVE target test and one custom `pve-toolbox` event,
so matching notification destinations receive test messages during the upgrade.
If an object or helper has changed since the toolbox created it, the package
upgrade stops with a specific error and leaves the legacy files in place.

## Git checkout

PVE 8 hosts use the checkout path, which remains fully supported:

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
pve-toolbox doctor             read-only host and module health audit
pve-toolbox uninstall <mod>...
pve-toolbox self-update        git pull this checkout (git installs only)
pve-toolbox --version          print the installed version
```

Flags: `-y` non-interactive (modules read their env vars instead of
prompting), `-f` force, `--json` versioned output, `--quiet` exit-status-only
output, `-V` version, `-h` help. JSON and quiet output are available for
`status`, `check`, and `doctor`.

The [`doctor` command](doctor.md) checks the host and every installed module
without making changes. Its exit status distinguishes a healthy report from a
warning or failure, so it can also run from monitoring automation.

## Shell completion

The Debian package installs completions directly. For a checkout,
`pve-toolbox link` symlinks completions for bash and zsh into
`/usr/share/bash-completion/completions/` and
`/usr/share/zsh/vendor-completions/`. A directory that is not there is skipped
rather than created, so if you install zsh later, run `link` again. They are
symlinks into the checkout, so `self-update` refreshes them with everything
else. Packaged installs refuse `link` and `self-update` because those commands
would overwrite dpkg-owned paths; use `apt upgrade pve-toolbox` instead.

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

`check` changes nothing, which makes it safe on a timer. Quiet mode reports an
available update with exit status `2` and an operational failure with `1`:

```bash
rc=0
pve-toolbox check --quiet || rc=$?
case $rc in
  0) printf '%s\n' 'all installed modules are current' ;;
  2) printf '%s\n' 'one or more updates are available' ;;
  *) printf 'module check failed with exit %d\n' "$rc" >&2 ;;
esac
```

See [Automation output](automation.md) for the JSON schema, all exit codes,
redaction behavior, and monitoring examples.

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
make lint      # shellcheck scripts and actionlint workflows
make test      # syntax + tests/ against throwaway dirs
make test-tui  # drive `ui` through a pty, needs whiptail + expect
```

CI runs portable tests, the strict documentation build, and the complete
Debian 13 package suite as separate jobs behind one aggregate required check.
The Debian job requires the terminal UI and other dependency-sensitive tests,
then validates one `.deb` through package inspection, signed repository
creation, APT download, and installation.
The package lifecycle and APT consumer mutations are opt-in required gates for
a clean disposable root environment; a normal `make test` does not run them.
