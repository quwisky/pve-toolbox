# Modules

A module is a directory under `modules/` containing at least `module.sh`. The
launcher discovers them at runtime; directories starting with `_` are skipped.

| Module | Tags | Host only | Helper installed |
| --- | --- | --- | --- |
| [backup-audit](backup-audit.md) | `backup audit monitoring` | yes | none; contributes doctor checks |
| [config-backup](config-backup.md) | `backup config notify` | yes | `pve-config-backup` |
| [native-notifications](native-notifications.md) | `monitoring notify webhook smtp gotify` | yes | `pve-toolbox-native-notify` |
| [storage-hygiene](storage-hygiene.md) | `storage audit monitoring zfs lvm` | yes | none; contributes doctor checks |
| [zfs-scrub](zfs-scrub.md) | `storage zfs monitoring notify` | yes | `pve-toolbox-zfs-scrub` |
| [zfs-replication](zfs-replication.md) | `storage zfs backup replication notify` | yes | `pve-toolbox-zfs-sync` |
| [scrutiny-collectors](scrutiny-collectors.md) | `storage monitoring smart zfs` | yes | four collector binaries |

Filter by tag:

```bash
pve-toolbox list zfs
```

## What every module implements

| Function | Called by | Purpose |
| --- | --- | --- |
| `module_install` | `install`, menu `i` | Interactive install or reconfigure |
| `module_update` | `update`, `check`, menu `u`/`c` | Update in place; `--check` reports only |
| `module_status` | menu, `list` | One short line; exits 1 when not installed |
| `module_status_long` | `status`, menu `s` | Detailed status; optional, falls back to `module_status` |
| `module_doctor` | `doctor` | Read-only module health results; optional |
| `module_uninstall` | `uninstall`, menu `x` | Remove what install created |

See [Writing a module](../writing-a-module.md) for the full contract.
