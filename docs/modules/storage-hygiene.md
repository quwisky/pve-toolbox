# storage-hygiene

Adds a read-only storage hygiene pass to `pve-toolbox doctor`. It inventories
guest snapshots, configured storage content, PVE storage definitions, directory
inodes, ZFS objects, and LVM thin pools without offering a delete command.

```text
Module      storage-hygiene
Config      /etc/pve-toolbox/storage-hygiene.conf (0600)
State       /var/lib/pve-toolbox/storage-hygiene.state (0644)
Mutations   none during an audit
```

```bash
pve-toolbox install storage-hygiene
pve-toolbox doctor
pve-toolbox doctor --json
```

## Checks

### Snapshots

Every non-template VM and container is queried through its PVE snapshot API.
A snapshot older than `SH_SNAPSHOT_DAYS` warns with the VMID, node, snapshot
name, creation epoch, and calculated age. The synthetic `current` entry is
ignored. A snapshot without a usable timestamp is reported with unknown age.

### Guest volumes and storage content

Active guest disk and mount-point volume IDs form the reference set. PVE
storage content of type `images` or `rootdir` is compared with it:

- a volume listed in a guest's `unusedN` config entry warns as explicitly
  unused, with that config entry as its evidence;
- a volume naming a VMID absent from the cluster inventory is an **orphan
  candidate**;
- a volume naming a live VMID but absent from its active config is
  **ownership unknown**, not orphaned.

The last category matters. Snapshots, replication, import workflows, storage
plugins, or external tools may still own a volume that does not appear in the
active guest config. The audit never assumes absence from one inventory is
permission to remove data.

ISO and `vztmpl` entries with a PVE content creation time older than
`SH_CONTENT_DAYS` warn as stale. Age is evidence of review need, not evidence
that content is unused.

### Definitions and availability

Disabled storage definitions warn. Enabled definitions with identical backend
signatures—type plus path, pool, volume group, thin pool, server, share, and
portal—warn as suspicious duplicates. They may be intentional aliases.

Runtime storage status is checked on every cluster node. Disabled or inactive
storage fails. Capacity warns and fails at the configured thresholds. Content
queries respect a definition's PVE node restriction.

For local `dir` storage whose path exists on the audit node, `df -Pi` adds inode
pressure using the same capacity thresholds. Remote-node inode use is not
inferred from the local filesystem.

### ZFS and LVM thin pools

When `zfs` is available, datasets and volumes with conventional
`vm-<id>-...` or `subvol-<id>-...` names are compared with the PVE reference
set. Missing owner VMIDs produce orphan candidates; live owner VMIDs produce
unknown-ownership warnings. Unconventional dataset names remain unclassified
instead of being guessed at.

When `lvs` is available, thin-pool data and metadata percentages are reported.
The higher pressure value determines warning or failure. Ordinary logical
volumes are not classified as orphaned from LVM names alone; PVE's content
inventory is the evidence source for those candidates.

## Thresholds

```ini title="/etc/pve-toolbox/storage-hygiene.conf"
SH_SNAPSHOT_DAYS='30'
SH_CONTENT_DAYS='180'
SH_CAPACITY_WARN='85'
SH_CAPACITY_FAIL='95'
SH_THIN_WARN='80'
SH_THIN_FAIL='95'
```

Age values must be positive integers. Percentage pairs must satisfy
`0 <= warning < failure <= 100`. Invalid settings fail the module doctor check.

Unattended configuration:

```bash
SH_SNAPSHOT_DAYS=45 \
SH_CONTENT_DAYS=365 \
SH_CAPACITY_WARN=80 \
SH_CAPACITY_FAIL=90 \
SH_THIN_WARN=75 \
SH_THIN_FAIL=90 \
  pve-toolbox -y install storage-hygiene
```

## Manual verification

Treat every result as an investigation starting point. Before considering a
cleanup outside this tool:

1. Re-run the audit and preserve its JSON evidence.
2. Inspect the guest config, including `unusedN` entries and snapshots.
3. Inspect storage content with `pvesm list <storage>` on the owning node.
4. Check backup, replication, import, HA, and external automation records.
5. For ZFS, inspect snapshots, clones, origins, holds, and dependent datasets.
6. For LVM thin pools, inspect logical-volume attributes and open devices.
7. Take and verify a backup before any manual removal.

There is intentionally no force flag, cleanup helper, prune action, or deletion
API in this release. Cleanup requires a separate proposal and review.

## Result ID families

| Pattern | Evidence |
| --- | --- |
| `guest.<vmid>.snapshot.<name>` | Snapshot name, node, timestamp, and age |
| `volume.<volid>.unused-config` | Matching guest `unusedN` reference |
| `volume.<volid>.orphan-candidate` | Parsed owner VMID is absent |
| `volume.<volid>.ownership-unknown` | Live owner exists but active config lacks the ID |
| `content.<volid>.stale` | Content type, node, storage, and creation time |
| `definition.*` | Disabled definition or duplicate backend signature |
| `storage.<node>.<id>.*` | Availability and byte capacity |
| `inode.<id>` | Local directory path and inode counts |
| `zfs.*` | Dataset name, type, byte figures, and owner evidence |
| `lvm-thin.*` | Volume group, pool, data use, and metadata use |

All IDs are automatically prefixed with `module.storage-hygiene.` in doctor
and JSON output.
