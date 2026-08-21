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
there is no `zpool` binary.

## Updates are the interesting part

`update` does more than swap binaries:

1. Pauses the timers and waits for any in-flight collection to finish.
2. Replaces each binary, keeping the old one as `.prev`.
3. Smoke-tests each collector by running its unit once.
4. Rolls back the ones that failed, and re-tests them on the previous build.
5. Resumes the timers.

The recorded version only advances if **every** collector passed. If any
rolled back, state stays at the old version and the run says which ones.

Release assets are checksum-verified when the release ships a checksum file.

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
