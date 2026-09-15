# restore-drill

`restore-drill` validates a specific VM or container backup by restoring it to
a collision-free temporary VMID. The helper is intentionally separate from
the normal module lifecycle because every real run consumes storage and may
boot a guest.

!!! danger "Resource and data safety"

    A restore drill is a destructive-capable maintenance operation. The
    default invocation only prints a plan. A real run can consume substantial
    storage and compute, and its final step deletes the temporary guest and
    restored disks. Verify the backup, target storage, VMID, capacity, and
    maintenance window before confirming. Never use production storage unless
    that choice is deliberate.

## Configure

```bash
pve-toolbox install restore-drill
```

```ini title="/etc/pve-toolbox/restore-drill.conf"
RD_STORAGE=local-lvm
RD_VMID_START=900000
RD_BOOT_PROBE=1
RD_BOOT_TIMEOUT=60
RD_ALLOW_UNATTENDED=0
```

The VMID range is scanned without overwriting existing guests. Set the target
to storage intended for temporary drill data. Boot probing can be disabled,
but configuration and isolation checks always run.

## Plan first

Supply the exact Proxmox backup volume or archive path:

```bash
pve-toolbox-restore-drill \
  --backup local:backup/vzdump-qemu-100-2026_08_29-01_00_00.vma.zst
```

This prints the selected backup, node, storage, allocated VMID, isolation,
probe, and cleanup plan. It performs no restore and writes no run state.

## Execute interactively

After reviewing the plan, add `--execute`:

```bash
pve-toolbox-restore-drill \
  --backup local:backup/vzdump-qemu-100-2026_08_29-01_00_00.vma.zst \
  --storage drill-storage \
  --execute
```

The helper requires an exact `RESTORE <vmid>` confirmation. It restores with
unique MAC generation, disables VM network links (or removes container network
devices), marks restored disks out of scheduled backups, disables on-boot, and
does not create HA or replication jobs. The optional boot probe only checks
that the isolated guest reaches its running state.

For non-interactive use, both controls are required: configure
`RD_ALLOW_UNATTENDED=1` and pass `--unattended --execute`. The flag alone is
not authorization.

## Failure and cleanup

The current operation is recorded at
`/var/lib/pve-toolbox/restore-drill-run.state` with the exact backup, run ID,
VMID, phase, elapsed duration, probe result, and cleanup result. A failed probe
preserves the isolated guest for inspection. A restore or isolation failure is
not automatically deleted because ownership may not yet be provable.

Resume proven cleanup explicitly:

```bash
pve-toolbox-restore-drill --cleanup
```

Cleanup requires `DELETE <vmid>` confirmation, or the same two-part unattended
policy. It proceeds only when the state says the guest was created and the
guest configuration contains the matching unpredictable run marker. A VMID
collision, missing marker, altered marker, malformed state, or failed destroy
stops cleanup without trying another target. `--keep` preserves a successful
drill for later inspection and explicit cleanup.

After successful teardown, the evidence moves to
`/var/lib/pve-toolbox/restore-drill-last.state`. Uninstall refuses while a live
run record exists and retains the last report. If automatic cleanup is refused,
inspect the run state and VMID manually; never delete a guest based only on its
number.

When the package-owned native notification helper can route to a configured PVE
matcher, restore and probe outcomes are sent through it. Notification failure
never weakens restore safety.
