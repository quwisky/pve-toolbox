# scrutiny-collectors

Installs the [Starosdev/scrutiny](https://github.com/Starosdev/scrutiny)
collector binaries plus systemd timers, reporting to a Scrutiny web instance
running elsewhere — typically a Docker LXC.

```
Module      scrutiny-collectors
Binaries    /usr/local/bin/scrutiny-collector-{metrics,zfs,mdadm,performance}
Config      /opt/scrutiny/config/*.yaml   (0640)
Units       scrutiny-collector-<kind>.{service,timer}
```

## Collectors

| Collector | Default schedule | Notes |
| --- | --- | --- |
| `metrics` | `*-*-* 04:00:00` | SMART data, daily |
| `zfs` | `*:0/15` | Pool state, every 15 minutes |
| `mdadm` | `*:0/15` | Only offered when `/proc/mdstat` shows an array |
| `performance` | `Sun *-*-* 02:00:00` | fio-based, adds real disk load, off by default |

Install asks which ones you want, and skips the ZFS collector entirely when
there is no `zpool` binary. Every selected release asset is downloaded and
verified before any binary is installed; a missing asset leaves the existing
collector set untouched.

## Updates are the interesting part

`update` does more than swap binaries:

1. Downloads and checksum-verifies every required binary while the installed
   release and timers remain operational.
2. Pauses the timers and waits for any in-flight collection to finish.
3. Replaces every binary, keeping the old ones as `.prev`.
4. Smoke-tests each collector by running its unit once.
5. Rolls back the whole release if any collector fails, avoiding mixed
   versions, and re-tests the previous build.
6. Resumes every timer, including on replacement or smoke-test failure.

The recorded version only advances if **every** collector passed. If any
rolled back, state stays at the old version and the run says which ones. A
missing asset, failed download or bad checksum is detected before timers are
paused or installed binaries are touched.

Every release must provide a checksum file with an exact entry for each
selected asset. Installation and update refuse assets that cannot be verified.

### What `check` reports

`check` writes nothing, and answers before `-f` is considered — forcing a
reinstall is an `update` decision, not a reporting one.

| Installed vs release | Reported |
| --- | --- |
| Same release | `up to date` |
| Release is newer | `update available: <installed> -> <tag>` |
| Release is older | `<tag> is older than the installed <version>` |

The last row is reachable rather than theoretical: `SCRUTINY_VERSION` pins a
tag, so a `check` against a pinned older release says so instead of calling it
an update. Run `update` on the same pair and it warns and asks before going
ahead.

Versions are compared with the leading `v` stripped, because the release tag
carries one and `<collector> --version` does not — `1.69.1` and `v1.69.1` are
one release, not an available update.

## Env vars for `-y`

| Variable | Meaning |
| --- | --- |
| `SCRUTINY_API_ENDPOINT` | Base URL of the Scrutiny web instance |
| `SCRUTINY_API_TOKEN` | Collector token, blank if auth is off |
| `SCRUTINY_HOST_ID` | Host id shown in the dashboard |
| `SCRUTINY_VERSION` | Release tag, or `latest` |
| `SCRUTINY_SCHEDULE_METRICS` | `OnCalendar` per collector |
| `SCRUTINY_SCHEDULE_ZFS` | |
| `SCRUTINY_SCHEDULE_MDADM` | |
| `SCRUTINY_SCHEDULE_PERFORMANCE` | |

!!! note "ZED still beats polling"

    ZFS pool events reach you faster through ZED than any collector interval.
    Keep the ZED-to-Discord hook alongside this; the collectors are for trend
    data, not for alerting.

## Uninstall

Removes the binaries and units, leaves `/opt/scrutiny/config` in place so a
reinstall keeps the endpoint and token.
