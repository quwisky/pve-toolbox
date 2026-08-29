# Doctor

`pve-toolbox doctor` is a read-only health audit for the local Proxmox host,
its cluster, and installed toolbox modules:

```bash
pve-toolbox doctor
```

Run it as `root` on the PVE host so the Proxmox task and storage APIs are
readable. The command never changes host, guest, storage, or module state.
Unavailable subsystems are reported as skipped or unsupported instead of
preventing the remaining checks from running.

## Built-in checks

| ID | What it checks |
| --- | --- |
| `cluster.quorum` | A clustered node is quorate; standalone nodes pass as not applicable |
| `systemd.failed` | No systemd units are failed |
| `zfs.pools` | Every configured ZFS pool reports `ONLINE` |
| `storage.capacity` | Enabled Proxmox storage is active and below the capacity thresholds |
| `pve.tasks` | Failed Proxmox tasks on every cluster node during the last 24 hours |
| `host.reboot` | No pending-reboot marker exists |
| `module.<name>.status` | Every installed toolbox module can report its status |

Installed modules may add more read-only checks. Their IDs are namespaced
under `module.<name>.` and a malformed or failed module check becomes its own
failure without corrupting the rest of the report.

For example, the [backup-audit module](modules/backup-audit.md) contributes
guest coverage, backup freshness, failure history, retention, excluded-volume,
and per-node backup-storage results after it is configured.
The [native-notifications module](modules/native-notifications.md) checks that
its owned target, matcher, helper, and templates remain enabled and intact.
The [storage-hygiene module](modules/storage-hygiene.md) adds snapshot age,
volume ownership evidence, stale content, and backend pressure checks.
The [certificate-watch module](modules/certificate-watch.md) checks every
cluster node's active TLS certificate, trust chain, hostname coverage,
reachability, and native ACME task history.
The [upgrade-readiness module](modules/upgrade-readiness.md) applies a
release-specific preflight policy to repositories, packages, filesystems,
cluster nodes, services, storage, and recent backups.

## Result states and exit status

| State | Meaning |
| --- | --- |
| `PASS` | The check completed and found no problem |
| `WARN` | Operator attention is advisable, but the subsystem is still available |
| `FAIL` | The check found an operational failure or could not safely evaluate critical state |
| `SKIP` | The subsystem is not configured, such as ZFS on a non-ZFS host |
| `N/A` | A command or API needed by the check is unavailable |

The final process status is `0` when there are no warnings or failures, `2`
when the strongest result is a warning, and `1` when any check fails. Skipped
and unsupported checks remain visible but do not make an otherwise healthy run
fail.

## Storage thresholds

Storage usage warns at 85 percent and fails at 95 percent by default. Override
the thresholds for one run with integers from 0 through 100; the warning value
must be lower than the failure value:

```bash
PVE_TOOLBOX_DOCTOR_STORAGE_WARN=80 \
PVE_TOOLBOX_DOCTOR_STORAGE_FAIL=90 \
  pve-toolbox doctor
```

An invalid threshold is itself a failed check. Storage explicitly configured
as `disabled` is listed as informational detail because it has no capacity to
audit. Any other non-active storage remains a failure regardless of its
reported utilization.

## Task history

The cluster task-list endpoint does not expose historical filters on PVE 9, so
the doctor enumerates the cluster nodes and reads each node's task history with
the supported failure and 24-hour filters. If any node cannot be queried, the
check fails rather than reporting an incomplete cluster as healthy.

## Example

```text
PASS cluster.quorum               cluster is quorate
PASS systemd.failed               no failed systemd units
PASS zfs.pools                    all ZFS pools are online
WARN storage.capacity             storage is nearing capacity
     local:88.40%
PASS pve.tasks                    no failed Proxmox tasks in the last 24 hours
PASS host.reboot                  no pending reboot marker

Summary: 5 passed, 1 warning, 0 failed, 0 skipped, 0 unsupported
```

Use `pve-toolbox doctor --json` for the stable versioned schema or
`pve-toolbox doctor --quiet` for exit-status-only monitoring. See
[Automation output](automation.md).
