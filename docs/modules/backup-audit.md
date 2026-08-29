# backup-audit

Audits whether every VM and container has adequate, recent backups without
starting or changing a backup job:

```text
Module      backup-audit
Config      /etc/pve-toolbox/backup-audit.conf (0600)
State       /var/lib/pve-toolbox/backup-audit.state (0644)
Mutations   none during an audit
```

Configure it once, then use the normal doctor output modes:

```bash
pve-toolbox install backup-audit
pve-toolbox doctor
pve-toolbox doctor --json
pve-toolbox doctor --quiet
```

The audit only performs `pvesh get` requests. It never starts a `vzdump` task,
edits a job, restores a guest, prunes retention, or deletes a backup.

## What it checks

The module reads the cluster-wide guest inventory and backup jobs, then reads
recent `vzdump` task history from each node that owns an inventoried guest. PVE
9 exposes the required history filters on these per-node endpoints. If any
node's task history is unavailable or malformed, the audit fails instead of
evaluating partial history. For each non-template VM or container it
distinguishes:

- covered by an enabled job;
- intentionally listed in an enabled job's exclusion list;
- matched only by a disabled job; or
- not covered by any job.

Covered guests are checked for their last successful backup and for failures
inside the configured freshness window. Two or more recent failures are a
failure; one is a warning. A covered guest with no successful task in the
available Proxmox task history fails closed.

The guest config is also inspected for `backup=0` on QEMU disks and for LXC
additional mount points that are not explicitly marked `backup=1`. Excluded
volumes are warnings because the remaining guest backup can succeed without
protecting their data.

Each enabled job should have either a positive calendar retention rule such as
`keep-daily`, `keep-weekly`, or `keep-monthly`, or `keep-last` at or above the
configured minimum. Missing and weak policies warn; the module does not change
them.

Finally, enabled backup-capable storage is read for every node that owns an
inventoried guest. Inactive or missing storage fails. Capacity warns and fails
at the configured percentages.

## Configuration

The defaults favor noticing protection gaps without requiring daily backups:

```ini title="/etc/pve-toolbox/backup-audit.conf"
BA_FRESHNESS_HOURS='48'
BA_STORAGE_WARN='85'
BA_STORAGE_FAIL='95'
BA_MIN_KEEP_LAST='2'
```

All four values are validated. Freshness and minimum retention must be positive
integers; storage thresholds must satisfy
`0 <= BA_STORAGE_WARN < BA_STORAGE_FAIL <= 100`. Invalid configuration is a
failed doctor result rather than a silently weakened audit.

For an unattended first install:

```bash
BA_FRESHNESS_HOURS=72 \
BA_STORAGE_WARN=80 \
BA_STORAGE_FAIL=90 \
BA_MIN_KEEP_LAST=3 \
  pve-toolbox -y install backup-audit
```

Re-running `install` reconfigures the thresholds. `update` adds settings
introduced by newer module versions without replacing existing values, and
`uninstall` removes only this module's config and state.

## Result IDs

The launcher prefixes these with `module.backup-audit.` in doctor and JSON
output:

| Pattern | Meaning |
| --- | --- |
| `inventory` | Guest and node inventory completed |
| `guest.<vmid>.coverage` | Enabled, excluded, disabled, or missing job coverage |
| `guest.<vmid>.freshness` | Age of the most recent successful backup |
| `guest.<vmid>.failures` | Failures inside the freshness window |
| `guest.<vmid>.volumes` | Explicit per-volume backup exclusions |
| `job.<id>.retention` | Retention exists and meets the minimum |
| `storage.<node>.<id>` | Backup storage availability and capacity |
| `api.<source>` | A required Proxmox response could not be read or validated |

JSON preserves exclusions and disabled jobs as separate warning summaries, so
monitoring can distinguish intentional policy from an accidental uncovered
guest instead of matching human-readable text.

## Current boundary

The first implementation audits Proxmox `vzdump` jobs and backup-capable
storage, including PBS storage as Proxmox exposes it to the node. It does not
yet query the PBS API for datastore-side snapshot verification. A missing
successful `vzdump` task still fails closed, leaving a clear place to add that
verification source without changing the result schema.
