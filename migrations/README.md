# Package configuration migrations

Files named `NNN-description.sh` in this directory are installed under
`/usr/lib/pve-toolbox/migrations/` and run in filename order during Debian
package upgrades. They are trusted package code and must be side-effect free
when sourced.

Each fragment defines two indexed arrays and one function:

```bash
MIGRATION_FILES=(/etc/pve-toolbox/example.conf)
MIGRATION_UNITS=(pve-toolbox-example.timer)

migration_apply() {
    # Rewrite only files declared above. Return non-zero on any failure.
    printf 'FORMAT=current\n' > /etc/pve-toolbox/example.conf
}
```

`MIGRATION_FILES` lists every regular file the migration may replace or create
directly under `/etc/pve-toolbox` or `/var/lib/pve-toolbox`. The runner's own
completion and pending-transaction files are reserved. Existing files are
copied with their ownership and mode to
`/var/backups/pve-toolbox/migrations/`; absent files are recorded so rollback
can remove a partially created file. Symlinks and non-regular files are
rejected. The runner restores declared files when the migration fails and
before retrying an interrupted transaction.

`MIGRATION_UNITS` lists services or timers that must be stopped while the
configuration changes. Their enabled and active states are captured and
restored after either success or rollback. A migration that does not touch a
unit uses an empty array.

`migration_apply` is non-interactive and idempotent. It can inspect
`PVE_TOOLBOX_PREVIOUS_VERSION`, `PVE_TOOLBOX_CONF_DIR`, and
`PVE_TOOLBOX_STATE_DIR`. Check failures explicitly and return non-zero; do not
call `exit`, start services, delete backups, or edit the completion state.

The filename without `.sh` is the permanent migration ID. Never rename or
reuse an ID after release. Keep fragments mode `0644`; group-writable or
world-writable fragments are refused. Add success, rollback, retry, and
interruption coverage to `tests/migrations.sh`, plus a package upgrade fixture
when the installed layout or maintainer-script behavior changes.
