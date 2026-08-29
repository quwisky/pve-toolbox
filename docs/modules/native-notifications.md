# native-notifications

Provisions one module-owned Proxmox VE notification target and matcher. It
supports native webhook, Discord, Gotify, and SMTP endpoints, verifies delivery
before claiming success, and exposes a shared sender for other toolbox modules.

```text
Module      native-notifications
Config      /etc/pve-toolbox/native-notifications.conf (0600)
State       /var/lib/pve-toolbox/native-notifications.state (0644; no secrets)
Helper      /usr/local/bin/pve-toolbox-native-notify
Templates   /etc/pve/notification-templates/default/pve-toolbox-*.hbs
Backups     /var/lib/pve-toolbox/native-notifications-backups/ (0700)
```

This module targets PVE 9's native notification framework. It uses the
documented `/cluster/notifications/endpoints/*`, `matchers`, and target test
API paths instead of editing `notifications.cfg` directly.

## Safety and ownership

Target and matcher names must start with `pve-toolbox-`. Each object carries
the comment `managed by pve-toolbox/native-notifications`, and the same names
and endpoint type are recorded in module state. All three checks must agree
before an existing object is updated or removed.

An object with the requested name but no matching ownership state is treated as
user-managed and left untouched. Changing an owned object's name or endpoint
type requires uninstalling it first. Uninstall removes the matcher before its
target and never enumerates or deletes unrelated notification objects.

Before a transaction, the public and protected native PVE notification files
are copied into a timestamped, root-only backup directory. Configuration then
uses the API. If target creation, matcher creation, asset installation, or test
delivery fails, newly created objects are removed and previously owned objects
are reapplied from the last successful root-only module config. The backup is
retained for operator recovery; it may contain PVE's protected notification
secrets and must not be copied into Git.

Repeated installation updates the same owned endpoint and matcher. It never
creates a suffixed or duplicate object.

## Credential handling

PVE stores Gotify tokens, SMTP passwords, and webhook `secret` values in
`/etc/pve/priv/notifications.cfg`. The normal `/etc/pve/notifications.cfg`
contains only public settings and secret template references.

The module's own credential source is
`/etc/pve-toolbox/native-notifications.conf`, mode `0600`. Secrets are never
written to the `0644` state file, status or doctor results. API mutation errors
are deliberately reported without echoing PVE command output or arguments.
The config-backup module does not collect `/etc/pve-toolbox`; PVE's `priv/`
tree is excluded unless encrypted secret capture was explicitly enabled.

Generic webhooks require a named secret and require the URL, header, or body to
reference it as `{{ secrets.<name> }}`. This prevents authentication material
from accidentally entering the public, Git-backable PVE configuration. Keep
literal header and body values non-sensitive.

## Matcher rules

`NT_MATCH_SEVERITY` is a comma-separated subset of `info`, `notice`,
`warning`, `error`, and `unknown`. The default is `warning,error`.

`NT_MATCH_FIELD` is optional and uses PVE's native syntax:

```text
exact:type=vzdump
regex:hostname=^pve-(1|2)$
exact:type=pve-toolbox
```

`NT_MATCH_MODE` is `all` or `any` when more than one matcher property is set.
The shared helper emits events with the field `type=pve-toolbox`.

## Discord preset

The preset extracts `<id>/<token>` from the webhook URL and stores it as the
protected secret named `token`. The public URL remains:

```text
https://discord.com/api/webhooks/{{ secrets.token }}
```

Interactive install:

```bash
pve-toolbox install native-notifications
```

Unattended install:

```bash
NT_KIND=discord \
NT_DISCORD_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>' \
NT_MATCH_SEVERITY='warning,error' \
  pve-toolbox -y install native-notifications
```

## Gotify

```bash
NT_KIND=gotify \
NT_GOTIFY_SERVER='https://gotify.example.com' \
NT_GOTIFY_TOKEN='<application-token>' \
NT_MATCH_FIELD='exact:type=vzdump' \
  pve-toolbox -y install native-notifications
```

Use a Gotify application token, not a client token. The install fails and rolls
back if PVE cannot deliver its target test.

## SMTP

```bash
NT_KIND=smtp \
NT_SMTP_SERVER='smtp.example.com' \
NT_SMTP_PORT=587 \
NT_SMTP_MODE=starttls \
NT_SMTP_USERNAME='pve@example.com' \
NT_SMTP_PASSWORD='<app-password>' \
NT_SMTP_MAILTO='ops@example.com' \
NT_SMTP_FROM='pve@example.com' \
  pve-toolbox -y install native-notifications
```

Modes are `insecure`, `starttls`, or `tls`. A username requires a password.
The port must be between 1 and 65535.

## Generic webhook

This example keeps the bearer token in protected PVE config while the public
header only contains a template reference:

```bash
NT_KIND=webhook \
NT_WEBHOOK_URL='https://hooks.example.com/events' \
NT_WEBHOOK_METHOD=post \
NT_WEBHOOK_HEADER_NAME=Authorization \
NT_WEBHOOK_HEADER_VALUE='Bearer {{ secrets.api_token }}' \
NT_WEBHOOK_SECRET_NAME=api_token \
NT_WEBHOOK_SECRET_VALUE='<token>' \
  pve-toolbox -y install native-notifications
```

The default body is JSON with the rendered title, message, and severity. PVE
expects webhook headers, bodies, and secrets base64-encoded at its API boundary;
the module performs that encoding without printing the inputs.

## Shared sender

Other modules and operator scripts can emit an event into the same native
matcher graph:

```bash
pve-toolbox-native-notify warning \
  'Replication lag' \
  'tank/appdata has not replicated for 26 hours'
```

The helper accepts `info`, `notice`, `warning`, or `error`, preserves arbitrary
text as data, and calls `PVE::Notify` with the shipped `pve-toolbox` templates.
It does not contain or accept endpoint credentials. Delivery is determined by
the configured native matchers, so a matcher limited to `exact:type=vzdump`
will not receive custom `type=pve-toolbox` events.

## Lifecycle

- `install` creates or reconfigures the owned objects and must deliver a test.
- `check` reports drift in helper assets or ownership markers without changes.
- `update` resynchronizes assets and reapplies the last successful config, then
  tests delivery.
- `status` identifies the endpoint, matcher, filters, and helper without
  exposing credentials.
- `doctor` reports missing, disabled, ownership-drifted, or modified pieces.
- `uninstall` removes only objects and unmodified files owned by this module.

Changing a credential is done by re-running `install`. Existing secret values
are the prompt defaults internally but are never displayed.
