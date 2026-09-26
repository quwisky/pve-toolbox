# lib/discord.sh

Webhook reporting, shared by modules and by the helper scripts they install.

Deliberately standalone: it needs only `curl` and `jq`, and pulls in nothing
else from the toolbox. That is what lets a runner in `/usr/local/bin` use it
without the checkout still existing.

## Sourcing it

Modules get it through `lib/common.sh` automatically. A standalone runner
sources it from the installed location:

```bash
TOOLBOX_LIB="${PVE_TOOLBOX_LIB:-/usr/local/lib/pve-toolbox}"
# shellcheck source=../../lib/discord.sh
source "$TOOLBOX_LIB/discord.sh" 2>/dev/null \
    || { printf 'error: cannot source %s/discord.sh\n' "$TOOLBOX_LIB" >&2; exit 1; }
```

Install it from a module with `install_toolbox_lib discord.sh` and set
`Environment=PVE_TOOLBOX_LIB=$TOOLBOX_LIB_DIR` in the unit. It is shared, so
`module_uninstall` should leave it in place.

## discord_notify

```
discord_notify <webhook> <color> <title> <description> [name value ...]
```

Returns non-zero when nothing was delivered — no webhook configured, or the
POST failed. That split matters:

```bash
# a --test mode should fail loudly
discord_notify "$WEBHOOK" "$DISCORD_INFO" "Test" "..." \
    || fail "could not deliver the test notification"

# a scheduled run should not abort because Discord was down
discord_notify "$WEBHOOK" "$DISCORD_OK" "Done" "..." || true
```

!!! warning "`set -e` and the return value"

    Under `set -euo pipefail` an unguarded `discord_notify` that fails will
    abort the script. Append `|| true` anywhere the notification is not the
    point of the run.

## Colours

| Constant | Value | Use |
| --- | --- | --- |
| `DISCORD_INFO` | `3447003` | blue — something started |
| `DISCORD_OK` | `3066993` | green — finished clean |
| `DISCORD_WARN` | `15844367` | yellow — finished, but not entirely |
| `DISCORD_ERR` | `15158332` | red — failed |

## Fields

Pass fields as **alternating name/value arguments**, never as one pre-joined
string:

```bash
discord_notify "$WEBHOOK" "$DISCORD_OK" "ZFS scrub finished - tank" "$scan" \
    Host       "$(hostname -s)" \
    Pool       tank \
    Repaired   0B \
    "Scrub time" 04:12:33
```

The payload is assembled by `jq` from `$ARGS.positional`, so a value holding
quotes, backticks, backslashes or newlines survives intact. Nothing is escaped
by hand and nothing is stripped.

An empty value renders as `-` rather than producing an invalid embed.

## Validating a webhook URL

`valid_webhook_url <url>` is a prompt validator for
[`ask_secret`](common.md#prompts):

```bash
ask_secret MY_WEBHOOK "Discord webhook URL" valid_webhook_url
```

- An empty value is refused (`a webhook URL is required`), which makes the
  prompt required.
- Anything that is not an `https://` URL made of letters, digits and
  `._~/-` is refused.
- An `https://` URL outside `discord.com/api/webhooks/`,
  `discordapp.com/api/webhooks/` and `ptb.discord.com/api/webhooks/` is
  accepted with a warning, since any endpoint taking the same JSON works.
- The reason it gives never repeats the URL, which carries the webhook token.

It uses `warn` from `lib/common.sh`, so only modules call it; the standalone
runners do not.

## Other helpers

`discord_payload <color> <title> <desc> [name value ...]`
: Prints the JSON without posting it. Useful in tests.

`discord_fields [name value ...]`
: Prints just the fields array.

`discord_fence <text> [room]`
: Wraps text in a code block, keeping the **last** `room` characters
  (default 3000) so a long log tail truncates from the top and the closing
  fence always survives.

```bash
desc=$(printf 'syncoid exited %s:\n%s' "$rc" "$(discord_fence "$tail")")
```

## Limits

Discord's own caps are applied here, so an oversized message truncates instead
of the whole POST being rejected:

| Variable | Default | Applies to |
| --- | --- | --- |
| `DISCORD_MAX_TITLE` | 250 | embed title |
| `DISCORD_MAX_DESC` | 3800 | embed description |
| `DISCORD_MAX_FIELD` | 1000 | each field value |

`DISCORD_FOOTER` defaults to `pve-toolbox on <short hostname>` and can be set
before calling.
