# upgrade-readiness

`upgrade-readiness` is a read-only preflight for routine Proxmox VE upgrades.
The first shipped policy targets PVE 9 on Debian 13 (`trixie`). It reports
blockers and operator-review risks; it does not edit repositories, install or
remove packages, reboot nodes, or start backups.

```bash
pve-toolbox install upgrade-readiness
pve-toolbox doctor
```

## Checks

The module checks:

- official Debian and Proxmox repository suites;
- unknown third-party repositories, which always produce a warning for human
  compatibility review;
- held packages and a pending-reboot marker;
- free space on the policy's critical filesystems;
- every cluster node's reachability and PVE major version;
- failed services and inactive enabled storage on reachable nodes;
- successful guest backups against an explicit freshness policy.

Failures contribute the standard doctor exit status `1`, so a failed preflight
cannot appear healthy to automation. Warnings produce status `2` when no check
fails.

```ini title="/etc/pve-toolbox/upgrade-readiness.conf"
UR_POLICY=pve-9
UR_BACKUP_HOURS=48
UR_MIN_FREE_MB=2048
```

The backup age is deliberately operator-controlled. Set it to the recovery
policy your environment actually requires; the default is 48 hours. The
preflight can coexist with `backup-audit`, but it independently verifies this
upgrade prerequisite so an uninstalled module cannot silently skip it.

## Release policies

Release-specific facts live under `modules/upgrade-readiness/policies/`.
The `pve-9` policy declares the expected major, supported suite, known official
repository hosts, and critical filesystems. A missing, mismatched, symlinked,
or malformed policy fails closed.

## Before upgrading

Resolve every failure and review every warning, then rerun doctor until the
result matches your maintenance policy. Keep the JSON report with the change
record when useful:

```bash
pve-toolbox doctor --json >preflight.json
```

!!! warning

    This report complements, but does not replace, the official Proxmox
    release notes and upgrade guidance. Read those documents in full for the
    exact versions and upgrade path you are using. Repository recognition also
    does not prove subscription status or third-party compatibility.
