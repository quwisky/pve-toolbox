# Automation output

`status`, `check`, and `doctor` support versioned JSON and output-free status
checks. `list` also supports `--json`, for a machine-readable module
inventory, but does not accept `--quiet`. `config show` supports `--json` too,
but it is root-only and shaped differently again — see
[`config show --json`](#config-show-json) below:

```bash
pve-toolbox status --json
pve-toolbox check --json
pve-toolbox doctor --json
pve-toolbox list --json
pve-toolbox config show --json zfs-scrub

pve-toolbox check --quiet
```

The options are deliberately limited to read-only commands. `--json` and
`--quiet` cannot be combined on a command that accepts both, because quiet
mode promises that no report is written. Both also force colour off
(`--color=never`) regardless of `--color` or `NO_COLOR`, since this output has
to stay parseable.

## Colour

stdout and stderr each decide colour independently: `auto` (the default)
colours a stream only when it is a terminal, so a script that captures stdout
but leaves stderr attached to a terminal can still see escape codes on
stderr. Set `--color=never`, or export [`NO_COLOR`](https://no-color.org),
to keep captured stderr free of escape codes regardless of the terminal.
`TERM=dumb` also turns colour off. `--color=always` overrides `NO_COLOR` and
`TERM=dumb`, but `--json` or `--quiet` anywhere on the line always win over
even an explicit `--color=always`, since their output has to stay parseable.

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Success, including an empty or skipped-only report |
| `1` | Operational failure |
| `2` | Warning, including an available module update |
| `64` | Invalid command, flag, argument, module name, or tag |
| `69` | Every meaningful result is unsupported on this host |

Failure takes precedence over warning, warning over success, and a successful
result over an unsupported one. This lets a broad doctor run report optional
unsupported subsystems without making a healthy host fail.

### Usage errors (exit 64)

A rejected command line changes nothing and prints no report. Nearly all
validation happens before the command starts. The exception is `status` and
`check` with `--json` or `--quiet`: they validate each named module as they
reach it, so the read-only status or check of a valid module named earlier on
the line may already have run when a later unknown module is rejected.

The error goes to stderr. Its first line is `error: <what was wrong>`
preceded by a single space, so match `error:` within the line rather than
anchoring a pattern on `^error:`. When a close candidate exists, a
`did you mean: a, b?` line follows (at most three, closest match first);
otherwise there is no suggestion line. The last line always names where to
read the usage. It is `run 'pve-toolbox help <command>' for usage` when a
known command rejects its own arguments or flags (an unknown module or tag, a
missing module name, a flag that command does not accept). It is the general
`run 'pve-toolbox help' for usage` for anything rejected before a command is
considered (an unknown command, an unknown flag such as `status --jsn`, or a
bad `--color` value) and for the internal `_complete` command:

```
 error: unknown command: stauts
did you mean: status?
run 'pve-toolbox help' for usage
```

This covers an unknown command, a flag the given command does not accept, an
unknown module or module tag, and an unknown top-level flag. An unknown tag to
`list` (for example `pve-toolbox list nope`, or `pve-toolbox list --json nope`)
is a usage error too; earlier releases printed nothing for a tag no module
carries.

Quiet mode prints nothing. Capture its status explicitly so Bash strict mode
does not treat an expected warning as an unhandled failure:

```bash
if pve-toolbox check --quiet; then
  printf '%s\n' 'all installed modules are current'
else
  rc=$?
  case $rc in
    2)  printf '%s\n' 'one or more module updates are available' ;;
    1)  printf '%s\n' 'a module check failed' >&2 ;;
    69) printf '%s\n' 'checks are unsupported on this host' >&2 ;;
    *)  printf 'pve-toolbox rejected the request (exit %d)\n' "$rc" >&2 ;;
  esac
fi
```

## JSON schema version 1

The top-level object is stable and deterministic for the same ordered result
set:

```json
{
  "schema_version": 1,
  "command": "doctor",
  "status": "warning",
  "exit_code": 2,
  "results": [
    {
      "id": "storage.capacity",
      "state": "warn",
      "summary": "storage is nearing capacity",
      "detail": "local:88.40%"
    }
  ]
}
```

`command` is `status`, `check`, or `doctor`. Top-level `status` is one of
`success`, `warning`, `failed`, or `unsupported`. Each result has a stable ID
and one of the states documented in the [doctor guide](doctor.md#result-states-and-exit-status).
Results retain module discovery or command-line order; the renderer does not
sort them.

An individual module failure is represented as a failed result inside valid
JSON. It does not truncate the document or prevent later modules from being
checked.

## `list --json`

`list --json` prints the module inventory rather than a result report, so its
document is shaped differently from `status`, `check`, and `doctor` above,
though it carries the same `schema_version` and `command`:

```json
{
  "schema_version": 1,
  "command": "list",
  "modules": [
    {
      "name": "zfs-scrub",
      "title": "ZFS scrub + Discord",
      "description": "scheduled scrub per pool, Discord message on start and on result",
      "tags": ["storage", "zfs", "monitoring", "notify"],
      "installed": true,
      "status": "pools:2  [rpool tank]"
    }
  ]
}
```

`modules` retains module discovery order, filtered by the optional tag
argument exactly like the plain `list [tag]` output. `name` is the module's
directory name, the same identifier every other command takes. `tags` is
always an array, empty when the module declares none. `installed` reflects
`module_status`: `false` only when that line is exactly `not installed`.
`title`, `description`, and `status` pass through the same cleanup as the
result reports above (see [Redaction](#redaction)) before they are rendered,
so a module string containing a credential-shaped value, a tab, or a newline
still comes out as valid JSON. `list --json` does not accept `--quiet`.

## `config show --json`

`config show <module>` (root only) prints a module's saved
`/etc/pve-toolbox/<module>.conf`, and any extra file the module names through
`module_config_files`. It never runs any of those files: it parses the
stored `KEY='value'` lines itself. `--json` shapes the document differently
again, one entry per configuration file rather than one flat list of results:

```json
{
  "schema_version": 1,
  "command": "config",
  "module": "zfs-scrub",
  "files": [
    {
      "name": "zfs-scrub",
      "keys": [
        {"key": "DISCORD_WEBHOOK", "set": true, "hidden": true},
        {"key": "POLL_INTERVAL", "set": true, "hidden": false, "value": "300"},
        {"key": "NOTIFY_START", "set": true, "hidden": false, "value": "1"}
      ]
    }
  ]
}
```

`module` echoes the name given on the command line. `files` lists every
configuration file that exists, in the order `config show` displays them: the
module's own file first, then each name `module_config_files` printed, in the
order it printed them. A module with no saved configuration at all gives an
empty `files` array rather than an error.

Each entry in a file's `keys` array is, in the order the key first appeared in
that file:

| Field | Meaning |
| --- | --- |
| `key` | The configuration key |
| `set` | `true` when the stored value is non-empty |
| `hidden` | `true` unless the module declares `key` public in `MODULE_CONFIG_PUBLIC` |
| `value` | The stored value, after the same cleanup as text output (see [Redaction](#redaction)). Present only when `hidden` is `false` |

A hidden key never carries a `value` field at all, not even `null`, so a
consumer that only checks `has("value")` cannot be tricked by an empty string.
`DISCORD_WEBHOOK` above is `set` but has no `value` because zfs-scrub does not
declare it public; `POLL_INTERVAL` and `NOTIFY_START` do, so their stored
values are shown as strings, exactly as saved.

### Exit codes

`config show` uses three of the codes in the table above:

| Code | When |
| ---: | --- |
| `0` | The module's configuration was read, including a module with nothing saved |
| `1` | Not running as root, or a configuration file or directory fails a check: a symbolic link, the wrong owner or mode, a line not in `KEY='value'` form, or `module_config_files` failing or listing an invalid name (see [Writing a module](writing-a-module.md#showing-configuration)) |
| `64` | An unknown module, an unknown `config` subcommand, or a missing or extra module name |

A refusal (exit `1`) prints nothing on stdout and names the offending file and
line on stderr, never its content. `--json` gives no partial document on a
refusal; either the whole call fails before anything is written, or the full
document is printed and the command exits `0`.

## Redaction

Terminal color escapes never appear in JSON. Before result text is retained,
the reporting layer removes common credential forms, authenticated URL user
information, Discord webhook credentials, and paths beneath `/etc/pve/priv`
or `/etc/pve-toolbox`.

Redaction is a defensive boundary, not permission to print secrets from a
module. Module status and health functions must still avoid tokens, passwords,
webhook URLs, private-key paths, and other secret values entirely.

## Monitoring example

This writes the deterministic JSON report and preserves the meaningful exit
status for the caller:

```bash
report=/var/tmp/pve-toolbox-doctor.json
rc=0
pve-toolbox doctor --json >"$report" || rc=$?
jq -e '.schema_version == 1' "$report" >/dev/null || exit 1
exit "$rc"
```
