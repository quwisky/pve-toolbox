# Native notifications

Proxmox VE owns notification targets, matchers, routing, enabled state, and
credentials. Configure them in **Datacenter → Notifications** in the PVE web
interface. pve-toolbox no longer provisions, updates, diagnoses, or removes
these native objects.

The Debian package keeps a small sender for toolbox jobs that need to emit a
custom event through the native PVE notification framework:

```bash
pve-toolbox-native-notify warning 'Backup warning' 'Guest 101 has no recent backup.'
```

The severity must be `info`, `notice`, `warning`, `error`, or `unknown`. The
sender uses the package templates in
`/usr/share/pve-toolbox/notification-templates/` and emits the matcher field
`type=pve-toolbox`. Create or update a PVE matcher if those events should reach
a particular target; for example, add `exact:type=pve-toolbox` as a matcher
rule.

## Upgrading an older installation

Older releases could create a target and matcher through the
`native-notifications` module. During upgrade, pve-toolbox verifies the
recorded identity, the PVE target and matcher, the installed templates, and
both target and custom-event delivery. Successful verification records the
ownership migration and removes only the obsolete toolbox files:

- the `native-notifications` module;
- `/etc/pve-toolbox/native-notifications.conf` and
  `/var/lib/pve-toolbox/native-notifications.state`;
- the unmodified legacy sender at
  `/usr/local/bin/pve-toolbox-native-notify`; and
- private migration backups under
  `/var/lib/pve-toolbox/native-notifications-backups/`.

The upgrade preserves the PVE target, matcher, routing rules, enabled state,
templates, and protected credentials. The comment
`managed by pve-toolbox/native-notifications` may remain as provenance and can
be edited in PVE.

Package cleanup runs only after the migration is recorded. If verification or
delivery fails, dpkg leaves the compatibility module and private state in
place, reports the problem, and remains retryable. Correct the named issue,
then run as root:

```bash
dpkg --configure pve-toolbox
```

The retained compatibility module writes template contents without changing
permissions under `/etc/pve`, where Proxmox assigns permissions by path. This
fixes the legacy `install: setting permissions ... Operation not permitted`
failure during asset installation or restoration. If restoring assets fails,
the error reports the retained private backup directory for recovery instead
of claiming that restoration succeeded.

## Removing an old target

Review the route in **Datacenter → Notifications** before deleting anything.
Disable or remove the matcher first, verify that other notification paths still
cover the intended events, then remove the matcher and target through the PVE
web interface or API. PVE removes its protected credential when the target is
deleted. The pve-toolbox package never deletes a PVE target, matcher, template,
or credential.
