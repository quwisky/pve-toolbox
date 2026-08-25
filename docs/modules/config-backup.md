# config-backup

Snapshots the Proxmox host's declarative configuration — guest definitions,
storage, networking, firewall, users — into timestamped `tar.gz` archives on a
timer, and reports to Discord.

This is the layer between PBS/vzdump, which preserve what is *inside* a guest,
and nothing at all, which is how `/etc/pve` and the host's own files are
usually preserved. It records what the host *was*, so a rebuild does not depend
on memory.

```
Module      config-backup
Helper      /usr/local/bin/pve-config-backup
Config      /etc/pve-toolbox/config-backup.conf      (0600)
Archives    /var/lib/pve-toolbox/config-backup/      (0700 dir, 0600 per file)
Git repo    /var/lib/pve-toolbox/config-backup.git/  (0700, optional)
State       /var/lib/pve-toolbox/config-backup.state (0644)
Unit        pve-toolbox-config-backup.{service,timer}
```

## Two backends

| | `local` | `git` |
| --- | --- | --- |
| Produces | one `tar.gz` per change, with `.sha256` and `.manifest` | one commit per change |
| Answers | "give me the whole host as it was on the 4th" | "what changed, and when" |
| Retention | `CB_RETENTION_COUNT` / `CB_RETENTION_DAYS` | none — history is the point |
| Holds | everything captured | configuration only |

Either can be turned off, but not both. They share one capture: the tree is
collected, classified, scanned and hashed once, and only then handed to
whichever backends are enabled.

!!! warning "A cross-node restore has to be asked for explicitly"

    A source whose recorded node does not match this host is blocked until you
    say `--target-node` and pick a mode. Nothing is inferred, because the two
    modes have opposite consequences.

## What is captured

**Cluster configuration**, from `/etc/pve`

:   `qemu-server/*.conf` and `lxc/*.conf` as raw copies — they carry the
    snapshot stanzas that `qm config` omits, and they are what a restore writes
    back. A parallel `resolved/` tree records `qm config --current` and
    `pct config` output for reading — collected only when `CB_PVE_DIR` is the
    real `/etc/pve`, because `qm` and `pct` answer from the live cluster
    whatever that variable is set to. Plus `storage.cfg`, `datacenter.cfg`,
    `user.cfg`, `jobs.cfg`, `vzdump.cron`, `corosync.conf`, and the
    `firewall/`, `ha/`, `sdn/`, `mapping/` and `nodes/` trees.

**Host configuration**, outside pmxcfs

:   `/etc/network/interfaces` and `interfaces.d/`, the `if-*.d/` hooks,
    iptables/nftables/ufw persistence, `hosts`, `hostname`, `resolv.conf`,
    `timezone`, `fstab`, `crypttab`, apt sources and preferences,
    `modprobe.d/` and `modules-load.d/` (which is where vfio passthrough
    lives), the kernel command line and GRUB defaults, `sshd_config`, root's
    crontab and `cron.d/`.

    Only the real files under `/etc/systemd/system` are taken. Most of what is
    there is symlinks that `systemctl enable` created; those are not
    configuration, they are state that `systemctl enable` recreates.

**Derived state**, regenerated dumps kept for reference

:   `pveversion -v`, `dpkg --get-selections`, `lsblk`, `blkid`, `lspci -nnk`,
    `ip -j addr`/`route`, `pvesm status`, the cluster resource list, and — when
    ZFS is present — `zpool status`, `zpool get all` and the `zfs` property
    dumps. Also a `firewall-live/` directory holding the live rulesets.

    These are never written back. They exist so a rebuild has something to
    compare against.

## What is deliberately not captured

| Left out | Why |
| --- | --- |
| Guest disk contents | PBS and vzdump territory. This module is about the definitions, not the data |
| `/etc/pve/priv/`, `*.pem`, `*.key` | Secrets. See below |
| `/etc/apt/auth.conf` | Holds repository passwords in cleartext |
| Generated `grub.cfg` | Regenerated from `/etc/default/grub`; capturing both invites restoring the wrong one |

Cluster membership is captured but classified never-restore: writing
`corosync.conf` back onto a live cluster is how a cluster gets split, and no
flag on this module will do it.

## Secrets policy

`/etc/pve/priv/`, anything named `*.pem` or `*.key`, and `/etc/apt/auth.conf`
are removed from the staged tree before anything else looks at it. What is left
is then scanned for private key headers, `password:`/`token=`-shaped
assignments in any case, bearer tokens and Discord webhook URLs. **An unexpected match
aborts the run** — no archive is written and the failure is reported.

That is deliberately louder than skipping the file. A capture that quietly
drops something is a capture you cannot reason about.

If a match is a false positive, name the path in `CB_SECRET_ALLOW`:

```ini title="/etc/pve-toolbox/config-backup.conf"
CB_SECRET_ALLOW='host/etc/cron.d/backup-job pve/sdn/controllers.cfg'
```

Entries are globs against the path *inside the archive*, which is what the
error message prints. A bare glob exempts a file from every pattern; a
`<glob>:<pattern>` pair exempts only that one — so allowing `user.cfg` for its
`token:` records leaves the private-key, bearer and webhook checks on it
intact.

To archive the secrets rather than drop them, set `CB_INCLUDE_SECRETS=1` and
give an age recipient. Each file is then encrypted to `secrets/<path>.age` and
the cleartext removed; without a recipient the install refuses. Keep the age
identity somewhere that is not the machine being backed up.

## Restore classes

Every captured path belongs to exactly one class, declared in a single table in
the runner so that capture and restore cannot drift apart. The class is written
into each archive's `.manifest` alongside the size and digest.

| Class | Examples | What restore will do |
| --- | --- | --- |
| `dropin` | `interfaces`, `fstab`, `modprobe.d/`, iptables persistence, custom units | Copy the file into place. Never auto-reload, never auto-`iptables-restore` |
| `pmxcfs` | `storage.cfg`, `firewall/`, `sdn/`, `jobs.cfg`, `user.cfg` | Write through the fuse mount, then re-read through the API to confirm PVE parsed it |
| `guest` | `qemu-server/*.conf`, `lxc/*.conf` | Pre-flight the VMID, storage and volumes, then classify restorable / degraded / blocked |
| `reference` | `zpool status`, `lspci`, dpkg selections, `firewall-live/` | Never written back. Printed as guidance, and diffable |
| `never` | `corosync.conf`, cluster keys, node certificates | Hard-blocked, and no `--force` lifts it |

A path the table does not cover fails the run rather than being archived
unclassified.

## Determinism

Two runs over an unchanged host produce **one** archive, not two.

The change-detection primitive is a content hash taken off the manifest: one
sorted line per path, carrying its class and its digest. A rename moves the
path, a byte change moves the digest, a new or deleted file adds or drops a
line — while mtimes, ownership and directory order move none of them. Symlinks
are walked too, so nothing reaches the archive without being classified first.
The hash is kept in state as `LAST_HASH`, and a run whose hash matches records
that it ran and stops.

**Reference-class paths are excluded from the hash**, and that exclusion is
what makes the guarantee hold at all. `pvesh get /cluster/resources` reports
live per-guest cpu, memory and uptime. `iptables-save` on a host running Docker
is rewritten by every container start, with addresses handed out in allocation
order. Neither is configuration. Hashing either one means every scheduled run
writes an archive, `ARCHIVE_COUNT` never settles, and — once
`CB_NOTIFY_ON_CHANGE` is on — Discord is pinged daily about a change that never
happened.

They stay *in* the archive, where the diagnostic value is. They are only held
out of the decision about whether anything changed.

What remains is normalised before hashing: `iptables-save` stamps the time it
ran into a comment on every dump, JSON is re-serialised through `jq -S`, and
`ip -j addr` reports DHCP lease lifetimes that count down every second.

!!! note "`CB_VOLATILE_SECTIONS` widens that exclusion"

    A space-separated list of path prefixes kept in the archive but held out of
    the hash, on top of everything already classified reference-only. Reach for
    it when something under `pve/` or `host/` turns out to churn on its own.

## Git history

`CB_GIT_ENABLED=1` maintains a working clone whose history *is* the
configuration's history. A commit happens only when the content hash moved, so
`git log` is a list of real changes rather than a list of times the timer
fired.

**The git tree holds configuration only.** Everything classified reference-only
— `derived/`, `resolved/`, `firewall-live/`, `meta/` — is excluded. Those are
regenerated dumps, and `resolved/` in particular is a *recomputed* view: a PVE
upgrade can change a resolved default with no operator edit behind it, and
committing that makes the history a worse answer to "what changed" than no
history at all. They stay in the archives, which is where the diagnostic value
was always meant to live.

`CB_VOLATILE_SECTIONS` widens that exclusion for anything under `pve/` or
`host/` that turns out to churn on a particular host.

!!! danger "`secrets/*` never reaches git"

    The local backend prunes; git has no retention, and a pushed blob is
    permanent — scrubbing one means rewriting remote history. Encrypted or not,
    that is not a decision to make on an operator's behalf. Secrets stay in the
    archives, under `CB_RETENTION_*`.

### Pushing

Set `CB_GIT_REMOTE` and `CB_GIT_PUSH=1`. Two rules:

- **Never a force push.** If the remote branch has commits this host does not,
  the snapshot is still committed locally, the remote is left exactly as it
  was, and a warning goes to Discord. Reconcile by hand — an automated
  reconciliation of two divergent configuration histories is a way to lose one
  of them.
- **Nothing can block.** Every git call runs with `GIT_TERMINAL_PROMPT=0` and
  ssh `BatchMode=yes`, under a `timeout`. A passphrase-protected deploy key
  fails fast instead of hanging a timer forever.

For SSH, point `CB_GIT_SSH_KEY` at a deploy key. For HTTPS, put the token in a
file and set `CB_GIT_TOKEN_FILE` — it is read through a credential helper when
git asks, so the value never reaches `.git/config`, the process table or the
journal.

!!! warning "Do not put a credential in the remote URL"

    `https://<token>@host/repo.git` is the habitual way to configure a remote,
    and install refuses it — along with any other userinfo, and any `http://`
    remote, which would send both the token and the whole host configuration in
    cleartext. Git would otherwise write the credential verbatim into
    `.git/config`, re-apply it on every run, and print it in `status --long`.

```bash
pve-config-backup log          # commit history
git -C /var/lib/pve-toolbox/config-backup.git log -p --follow pve/storage.cfg
```

## Restoring

Four stages, and you have to pass through them in order:

```bash
pve-config-backup inspect latest              # what does this source hold
pve-config-backup diff    latest              # what would change
pve-config-backup restore latest              # dry run - shows the plan
pve-config-backup restore latest --confirm    # actually write
pve-config-backup rollback --confirm          # undo it
```

`restore` and `rollback` are **dry runs unless you say `--confirm`**. A second
argument narrows the operation to a path prefix:

```bash
pve-config-backup restore latest pve/firewall --confirm
```

### Nothing is written until everything checks out

Every pre-flight check runs before the first byte. A restore that fails half
way through is worse than one that never started, so a hard failure aborts with
the host untouched:

| Check | |
| --- | --- |
| The source verifies against its `.sha256` | hard — no sidecar is also a refusal |
| The source's node matches this host | hard |
| Nothing selected is class `never` | hard, and `--force` does not lift it |
| pmxcfs is mounted and writable | hard, when any `pmxcfs`/`guest` path is selected |
| The target's parent directory exists | hard — a missing parent usually means the subsystem is gone, and creating a path nothing reads gives false confidence |
| No earlier restore left an in-progress marker | hard |
| A selected guest is running | warning — the live process keeps its own device set |
| The target is a symlink | warning — it would be replaced by a regular file |

The restore class is re-derived from the current table, never read out of the
archive's manifest. An archive written before a path was reclassified must not
be able to resurrect it.

### The rollback point

A **full snapshot is taken first, unconditionally**, before anything is
written, and its name is recorded. If that snapshot fails, the restore does
not happen — a restore with no way back is not one worth having.

`rollback` is a *sync*, not a replay. It restores what changed **and deletes
what the restore created**: a file that did not exist beforehand is by
definition absent from the snapshot, so replaying the snapshot alone would
leave it behind forever. It also reuses the selector the restore ran with, so
rolling back a scoped restore does not revert unrelated edits made since.

### Nothing is reloaded

Writing a file is reversible. Applying a bad network configuration to a host
you reach over that network is not. So the summary prints the commands and
leaves them to you:

```
Nothing was reloaded. Run these yourself when you are ready:
  ifreload -a   # or: systemctl restart networking
  systemctl reload ssh
```

It also says when a reboot is warranted — `modprobe.d/`, the kernel command
line, GRUB, `fstab` and `crypttab` only take effect at boot.

`pmxcfs` writes are re-read afterwards, because that is the one place PVE
parses on our behalf and so the one place a write can be confirmed rather than
assumed.

Every restore appends to `/var/lib/pve-toolbox/config-backup/restore.log`
(0600) — when, from which source, at which hash, with which rollback point, and
how it ended. The marker is written *before* the first write, so an interrupted
restore leaves evidence rather than looking like it never happened.

!!! warning "Known limits of the same-node check"

    The node check compares `hostname -s`. A rebuilt machine that kept its name
    passes it, even though its disks and storage are entirely different.
    `storage.cfg` is not reconciled against the live LVM or ZFS backends, and
    `fstab` UUIDs are not checked against `blkid` — a stale UUID surfaces at the
    next boot. Read the `diff` before you `--confirm`.

## Restoring onto a different node

Between extracting the source and planning the restore, a **transform layer**
rewrites the staged tree to describe the target instead of the source, and
prints a full report before anything is written.

```bash
# the source node is gone; keep its identities
pve-config-backup restore latest --target-node pve2 \
    --mode dr --source-node-gone --confirm

# the source node is alive; everything must be regenerated
pve-config-backup restore latest --target-node pve2 \
    --mode clone --vmid-offset 1000 --regenerate-macs \
    --map-storage local=nas --map-bridge vmbr0=vmbr9 --confirm
```

| Transform | What moves |
| --- | --- |
| node path | `nodes/<src>/` → `nodes/<tgt>/`, with the source node read from the staged tree rather than trusted from metadata |
| `--map-storage A=B` | anchored on the field (`^key: A:`), so mapping `local` leaves `local-lvm` and `my-local` alone |
| `--map-bridge A=B` | `bridge=A` in a `netN:` line; the model, MAC, tag and firewall options survive byte for byte |
| `--vmid-offset N`, `--map-vmid A=B` | the filename and the `vm-<id>-`, `subvol-<id>-` and `<id>/` tokens — never a bare number, which would rewrite `memory: 100` and `tag=100` |
| `--regenerate-macs` | the MAC in both serialisations — qemu's `net0: <model>=<mac>,…` and LXC's `hwaddr=<mac>`. One new address per old one, so an interface keeps the same MAC in the running config and in every snapshot stanza |

Covers qemu (`scsiN`, `ideN`, `virtioN`, `sataN`, `efidiskN`, `tpmstateN`,
`unusedN`, `vmstate`) and LXC (`rootfs`, `mpN`), and reaches inside `[snapshot]`
and `[PENDING]` sections, which carry their own copies of every disk line.

### What it refuses to do

Refusing beats a transform that is right most of the time.

- **`--target-node` must name this host.** A cross-node restore still writes
  host-level files — `sshd_config`, `cron.d`, custom units — through *this*
  machine's filesystem, and records its rollback point in *this* machine's
  state. Naming a different node would put both on the wrong box. SSH to the
  target and run it there.
- **Cluster-shared files are blocked, and `--force` does not lift it.**
  `storage.cfg`, `datacenter.cfg`, `user.cfg`, `jobs.cfg`, `firewall/cluster.fw`,
  `sdn/` and `ha/` are one file for the whole cluster. A guest's own
  `firewall/<vmid>.fw` is not, and travels with it. A restore installs a whole
  file, so restoring another node's copy would delete every entry this cluster
  has that the source lacked — instantly, on every node. Doing it correctly
  needs per-entry merge semantics this tool does not have.
- **A VMID-remapped guest is `degraded`, never `restorable`.** The config is
  rewritten; the volumes are not, because nothing here touches storage. A guest
  renamed 100 → 1100 refers to `vm-1100-disk-0` while the volume is still
  called `vm-100-disk-0`. Move the volumes first; the report names them.
- **An archive from a cluster keeps only its own node.** `/etc/pve/nodes/`
  holds a directory per member, so an archive taken on a cluster contains every
  node's guests. The transform keeps the source node's and drops the rest —
  they belong to a live machine and must never be written here. An archive that
  does not record which node it came from is refused rather than guessed at, as
  is one whose `nodes/` entry is a symlink.
- **`--mode dr` requires `--source-node-gone`.** DR mode deliberately reuses
  the source's VMIDs, MACs and IPs. This tool cannot tell a dead node from a
  partitioned one, and guessing wrong puts a second guest with a duplicate
  identity on the same network, possibly writing to the same shared storage.

### Dropped automatically

Whatever the flags say, because they describe hardware or identity that did not
move: `interfaces` and `interfaces.d/` (NIC naming), `fstab` and `crypttab`
(UUIDs), `modprobe.d/`, `modules-load.d/`, GRUB and the kernel command line
(PCI addresses), `hostname`, `hosts`, and SSH host keys.

A guest with any `hostpci*` line is **blocked** — the PCI address it names is a
fact about the source machine.

A VMID already live on *another* node is a collision and blocks that guest. One
found under the source node's own directory is not: a dead node's tree survives
in pmxcfs, and reusing that VMID is exactly what DR mode is for.

## Retention

```
CB_RETENTION_COUNT=30    # never prune below this, whatever the age
CB_RETENTION_DAYS=90     # prune older than this, once COUNT is satisfied
```

In one sentence: **you always have the last 30 runs, and anything older than 90
days beyond that is pruned.**

Count is a floor, not a cap. An archive that is outside the newest 30 but
younger than 90 days is kept — so on a frequent timer the directory can hold
more than `CB_RETENTION_COUNT` archives. That is the intended reading. Either
knob accepts `0` for unlimited on that axis.

Age alone would fail the case that matters most: a host powered off for four
months comes back, and the first run prunes exactly the pre-outage
configuration you wanted. Count alone would tie the window to the timer
frequency, where 30 archives is 30 days on a daily timer and 30 hours on an
hourly one.

These are gzipped configuration files. The knob is about noise in `list`
output, not about disk.

## Configuration

```ini title="/etc/pve-toolbox/config-backup.conf"
DISCORD_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>'
CB_ARCHIVE_DIR='/var/lib/pve-toolbox/config-backup'
CB_RETENTION_COUNT='30'
CB_RETENTION_DAYS='90'
CB_NOTIFY_ON_CHANGE='0'
CB_INCLUDE_SECRETS='0'
CB_AGE_RECIPIENT=''
CB_VOLATILE_SECTIONS='firewall-live/'
CB_SECRET_ALLOW='pve/user.cfg:credential derived/dpkg-selections.txt:credential'
```

A failed capture always reports. `CB_NOTIFY_ON_CHANGE=1` additionally reports
when the configuration changed — off by default, because editing a guest is
routine and a channel that pings on every edit stops being read.

## Env vars for `-y`

| Variable | Default | Meaning |
| --- | --- | --- |
| `CB_WEBHOOK` | — | Discord webhook URL. Required |
| `CB_ARCHIVE_DIR` | `/var/lib/pve-toolbox/config-backup` | Where archives are written |
| `CB_SCHEDULE` | `daily` | systemd `OnCalendar` for the timer |
| `CB_RETENTION_COUNT` | `30` | Archives kept whatever their age; `0` for unlimited |
| `CB_RETENTION_DAYS` | `90` | Prune past this age, beyond the count; `0` for unlimited |
| `CB_NOTIFY_ON_CHANGE` | `n` | Also report when the configuration changed |
| `CB_INCLUDE_SECRETS` | `n` | Archive secrets, encrypted. Needs `CB_AGE_RECIPIENT` |
| `CB_AGE_RECIPIENT` | — | age recipient (`age1...`) for encrypted secrets |
| `CB_SECRET_ALLOW` | `pve/user.cfg:credential derived/dpkg-selections.txt:credential` | Space-separated path globs the secret scan may ignore |
| `CB_RUN_NOW` | `n` | Take the first snapshot at the end of the install |
| `CB_TEST_NOTIFY` | `y` | Send a test notification during install |
| `CB_LOCAL_ENABLED` | `y` | Keep `tar.gz` archives |
| `CB_GIT_ENABLED` | `n` | Keep a git history |
| `CB_GIT_DIR` | `/var/lib/pve-toolbox/config-backup.git` | Working clone |
| `CB_GIT_REMOTE` | — | Push target; must not embed a credential |
| `CB_GIT_BRANCH` | `master` | Branch to commit on |
| `CB_GIT_PUSH` | `n` | Push after each commit |
| `CB_GIT_SSH_KEY` | — | Deploy key for an ssh remote |
| `CB_GIT_TOKEN_FILE` | — | File holding a token, for an https remote |

```bash
CB_WEBHOOK='https://discord.com/api/webhooks/123/abc' \
CB_SCHEDULE='daily' \
CB_RETENTION_COUNT=60 \
CB_RUN_NOW=y \
  pve-toolbox -y install config-backup
```

Two more override the paths the collector reads, so it can be pointed at a
fixture tree rather than at a live host: `CB_PVE_DIR` (default `/etc/pve`) and
`CB_ROOT_DIR` (default `/`). They are what makes the collector testable off a
PVE host, and they are not prompted for.

## Operating it

```bash
pve-config-backup run              # capture now
pve-config-backup run --dry-run    # classify and hash, write nothing
pve-config-backup run --force      # archive even if nothing changed
pve-config-backup list             # archives newest first
pve-config-backup log              # commit history, when git is enabled
pve-config-backup inspect latest   # what a source holds
pve-config-backup diff latest      # what restoring it would change
pve-config-backup --test           # send a test notification
```

The newest archive is always reachable as `latest`, a symlink that is
re-pointed after every prune.

!!! warning "Each node accounts only for its own archives"

    Retention, `list` and the `latest` symlink all match archives named for
    *this* node. Pointing two cluster members at one NFS-backed
    `CB_ARCHIVE_DIR` is safe — they will not prune each other — but neither
    sees or counts the other's.

```bash
tar -tzf /var/lib/pve-toolbox/config-backup/latest | head
sha256sum -c /var/lib/pve-toolbox/config-backup/*.sha256
column -t -s $'\t' /var/lib/pve-toolbox/config-backup/*.manifest
```

Each archive ships two sidecars: a `.sha256` verified immediately after the
write, and a `.manifest` of `path`, restore class, size and digest. Both are
pruned with their archive.

Only one capture runs at a time — a second invocation finds the lock held,
says so and exits successfully rather than piling up behind the first.

## Update semantics

There is no upstream release to track, so `update` re-syncs the installed
runner and the systemd unit with this checkout and fills in any configuration
key added since the host was installed. Keys you added by hand are left alone,
and the timer's `OnCalendar` is read back off disk and preserved.

`check` reports whether the runner or the config is out of sync and changes
nothing. `-f` forces the reinstall even when everything already matches.

Uninstall removes the runner, the unit and the state, asks before removing the
config, and asks separately before deleting the archives — defaulting to
keeping them.
