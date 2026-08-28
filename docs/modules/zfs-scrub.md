# zfs-scrub

Scrubs every ZFS pool on its own systemd timer and reports each run to a
Discord webhook twice: once when the scrub starts, once when it ends.

```
Module      zfs-scrub
Helper      /usr/local/bin/pve-toolbox-zfs-scrub
Config      /etc/pve-toolbox/zfs-scrub.conf   (0600)
Units       pve-toolbox-zfs-scrub@<pool>.{service,timer}
```

## Why a watcher instead of a plain timer

`zpool scrub` returns the moment the scrub is *queued*, not when it finishes.
A normal oneshot unit would exit immediately and the result would be lost.

Instead the unit stays active for the whole run — `TimeoutStartSec=infinity` —
and polls `zpool status` until the scan ends, then reports what zfs recorded.

!!! warning "Stopping the unit does not stop the scrub"

    The scrub runs in the kernel. Stopping the unit only stops the reporting,
    and you get a message saying exactly that rather than silence. A reboot
    mid-scrub is the same case: zfs resumes the scrub, the watcher does not,
    and the warning may not make it out before the network goes down.

    To actually stop a scrub: `zpool scrub -s <pool>`.

## One timer per pool

Defaults stagger the pools a week apart, because pools usually share spindles
and scrubbing them on the same night is how a Sunday turns into a slow Sunday:

```
pve-toolbox-zfs-scrub@rpool.timer   Sun *-*-01..07 03:00:00
pve-toolbox-zfs-scrub@tank.timer    Sun *-*-08..14 03:00:00
pve-toolbox-zfs-scrub@backup.timer  Sun *-*-15..21 03:00:00
```

Every schedule is a plain systemd `OnCalendar` you are asked about at install
time, so the stagger is a default, not a rule.

## What the report says

| Colour                                            | When                                                                                            |
|---------------------------------------------------|-------------------------------------------------------------------------------------------------|
| :material-circle:{ style="color:#3498db" } Blue   | Scrub started                                                                                   |
| :material-circle:{ style="color:#2ecc71" } Green  | Finished, nothing repaired, no errors                                                           |
| :material-circle:{ style="color:#f1c40f" } Yellow | Repaired something, pool not `ONLINE`, or scrub canceled or paused                              |
| :material-circle:{ style="color:#e74c3c" } Red    | Scan reported errors, `zpool status -v` knows about damaged files, or the scrub failed to start |

The result embed carries the raw `scan:` line as its description plus fields
for health, repaired, errors, scrub time, watched time, and data errors.

!!! tip "The sneaky case"

    A scan line can say `0 errors` while zfs still knows about permanently
    damaged files. The report reads `zpool status -v` separately and goes red
    on that, which a naive `with 0 errors` check would miss.

## Configuration

```ini title="/etc/pve-toolbox/zfs-scrub.conf"
DISCORD_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>'
POLL_INTERVAL=300
NOTIFY_START=1
```

The webhook URL is the only credential Discord checks, so it goes through
`conf_set` into a `0600` file rather than the world-readable state file.

`POLL_INTERVAL` is clamped to a minimum of 10 seconds.

## Env vars for `-y`

| Variable                    | Default   | Meaning                           |
|-----------------------------|-----------|-----------------------------------|
| `ZFS_SCRUB_WEBHOOK`         | —         | Discord webhook URL. Required.    |
| `ZFS_SCRUB_POOLS`           | all pools | Space-separated pools to schedule |
| `ZFS_SCRUB_INTERVAL`        | `300`     | Seconds between completion checks |
| `ZFS_SCRUB_NOTIFY_START`    | `y`       | Also notify when a scrub starts   |
| `ZFS_SCRUB_SCHEDULE_<POOL>` | staggered | `OnCalendar` for that pool        |

`<POOL>` is the pool name uppercased with anything non-alphanumeric turned
into `_`, so `tank-ssd` reads `ZFS_SCRUB_SCHEDULE_TANK_SSD`. Two selected pools
must not normalize to the same variable: `tank-ssd` and `tank_ssd` are rejected
instead of silently receiving one shared schedule.

Schedules are validated with `systemd-analyze calendar` before timer files are
written. A timer enable failure fails installation or update, and existing
invalid timer schedules are surfaced by status and repaired through update.

## Conflicting timers

`zfsutils-linux` ships its own `zfs-scrub-monthly@<pool>.timer`. Install
detects an enabled one and offers to disable it, so a pool is not scrubbed on
two schedules. The package files are never deleted, only disabled.

## Operating it

```bash
pve-toolbox-zfs-scrub --test tank      # send a test message, scrub nothing
systemctl list-timers 'pve-toolbox-zfs-scrub@*'
systemctl start pve-toolbox-zfs-scrub@tank.service   # scrub now
journalctl -u 'pve-toolbox-zfs-scrub@*' -f
```

A second run while a scrub is already in progress leaves the running one
alone and exits 0.

## Update semantics

There is no upstream release to track. `update` re-syncs the installed watcher
and the unit files with the checkout, removes timers for pools that no longer
exist, offers to schedule pools created since the last run, and repairs invalid
schedules. `check` reports all of that without changing anything.
