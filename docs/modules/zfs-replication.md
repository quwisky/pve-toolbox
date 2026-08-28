# zfs-replication

Runs [`syncoid`](https://github.com/jimsalterjrs/sanoid) replication jobs on
systemd timers and reports each run to a Discord webhook — green on success,
red with the tail of the log on failure.

```
Module      zfs-replication
Helper      /usr/local/bin/pve-toolbox-zfs-sync
Config      /etc/pve-toolbox/zfs-replication.conf   (0600)
Logs        /var/log/pve-toolbox/<job>.log          (0640)
Units       pve-toolbox-zfs-sync@<job>.{service,timer}
```

Needs `sanoid` for `syncoid`; install pulls it in.

## One timer per job

An hourly `appdata` sync and a nightly `media` sync are separate units with
separate schedules and separate messages:

```
pve-toolbox-zfs-sync@appdata.timer   *-*-* 02:30:00
pve-toolbox-zfs-sync@media.timer     Sun *-*-* 04:00:00
```

## A job

```ini title="/etc/pve-toolbox/zfs-replication.conf"
DISCORD_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>'
JOBS='appdata'
LOG_DIR='/var/log/pve-toolbox'
NOTIFY_START='0'

JOB_APPDATA_SRC='fast-data-pool/appdata'
JOB_APPDATA_DST='data-pool/appdata-backup'
JOB_APPDATA_OPTS='--recursive --compress=zstd-fast'
JOB_APPDATA_CHOWN='102105:102105'   # optional
JOB_APPDATA_CHMOD='775'             # optional
JOB_APPDATA_PATH=''                 # blank = the target's own mountpoint
```

Job keys are the job name uppercased with anything non-alphanumeric turned
into `_`. Job names must match `^[A-Za-z][A-Za-z0-9_.:-]*$`, because they
become systemd instance names. The normalized key must also be unique:
`app-data` and `app_data` cannot coexist because both would become
`JOB_APP_DATA_*`. Install, update, status and the runner all reject that
configuration instead of choosing one silently.

## What the report says

The success embed carries duration, how much the target grew, its total size,
and the snapshot count before and after. The failure embed carries the exit
code and the last 25 log lines in a code block.

:material-circle:{ style="color:#2ecc71" } Green
: syncoid succeeded and any requested ownership fixup landed

:material-circle:{ style="color:#f1c40f" } Yellow
: syncoid succeeded but a requested `chown`/`chmod` was skipped

:material-circle:{ style="color:#e74c3c" } Red
: syncoid exited non-zero

## Behaviour worth knowing

**`flock` per job.** A run that overruns its schedule will not have a second
copy started on top of it — the next trigger sees the lock, logs, and exits 0.
Locks live under root-owned, mode `0700` `/run/pve-toolbox`, are opened without
truncation, and fail closed if the directory or lock cannot be verified.

**Logs are not in `/tmp`.** Each run writes `/var/log/pve-toolbox/<job>.log`
at `0640`, keeping the previous run as `.log.prev`.

**Ownership fixups are reported, not assumed.** If `chown`/`chmod` was
requested but the target has no local mountpoint, the path is not a directory,
or either command fails, the run records a degraded result, finishes yellow,
and exits non-zero instead of reporting a clean success.

**The target path is derived.** With `JOB_*_PATH` blank the fixup applies to
the target dataset's own `mountpoint`, so there is no hardcoded `/mnt/...` to
go stale. An explicit path must resolve to that mountpoint or one of its
children. Broad roots such as `/`, `/etc`, `/var` and `/mnt` are always
refused before a recursive permission change.

Every schedule is validated with `systemd-analyze calendar` before its timer is
written. A timer that systemd cannot enable fails installation or update rather
than being counted as a working job.

!!! tip "Why the payload is built with `jq`"

    A syncoid failure often contains quotes, backticks or backslashes.
    Hand-rolled JSON — `-d "{\"content\":\"$ERROR\"}"` — either breaks the
    request or has to strip characters out of the error you actually wanted to
    read. Fields are passed to `jq` as separate arguments, so the message
    arrives intact.

## Env vars for `-y`

| Variable | Meaning |
| --- | --- |
| `ZFS_REPL_WEBHOOK` | Discord webhook URL. Required. |
| `ZFS_REPL_JOBS` | Space-separated job names |
| `ZFS_REPL_NOTIFY_START` | Also notify when a job starts |
| `ZFS_REPL_<JOB>_SRC` | Source dataset |
| `ZFS_REPL_<JOB>_DST` | Target dataset |
| `ZFS_REPL_<JOB>_OPTS` | syncoid options |
| `ZFS_REPL_<JOB>_CHOWN` | `uid:gid` for the post-run fixup |
| `ZFS_REPL_<JOB>_CHMOD` | mode for the post-run fixup |
| `ZFS_REPL_<JOB>_PATH` | fixup path, blank for the mountpoint |
| `ZFS_REPL_<JOB>_SCHEDULE` | `OnCalendar` for that job |

```bash
ZFS_REPL_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>' \
ZFS_REPL_JOBS='appdata' \
ZFS_REPL_APPDATA_SRC='fast-data-pool/appdata' \
ZFS_REPL_APPDATA_DST='data-pool/appdata-backup' \
ZFS_REPL_APPDATA_CHOWN='102105:102105' \
ZFS_REPL_APPDATA_CHMOD='775' \
  pve-toolbox -y install zfs-replication
```

## Operating it

```bash
pve-toolbox-zfs-sync --list             # configured jobs
pve-toolbox-zfs-sync --test appdata     # send a test message, replicate nothing
systemctl start pve-toolbox-zfs-sync@appdata.service
journalctl -u 'pve-toolbox-zfs-sync@*' -f
tail -f /var/log/pve-toolbox/appdata.log
```

`pve-toolbox status zfs-replication` shows each job's source, target,
schedule, and the outcome of its last run.

## Update semantics

`update` re-syncs the installed runner and the unit files with the checkout,
offers to remove timers for jobs no longer in `JOBS`, and prompts for the
settings of jobs that are configured but have no timer. Invalid schedules are
reported and rewritten through the same validated prompt. `check` reports that
without changing anything.
