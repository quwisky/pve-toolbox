# Automation output

`status`, `check`, and `doctor` support versioned JSON and output-free status
checks:

```bash
pve-toolbox status --json
pve-toolbox check --json
pve-toolbox doctor --json

pve-toolbox check --quiet
```

The options are deliberately limited to read-only commands. `--json` and
`--quiet` cannot be combined because quiet mode promises that no report is
written. Both also force colour off (`--color=never`) regardless of `--color`
or `NO_COLOR`, since this output has to stay parseable.

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

A rejected command line never runs anything. It always writes to stderr as
`error: <what was wrong>`, first line, and stops there when nothing close
matches; when a close candidate exists, a `did you mean: a, b?` line follows
(at most three, closest match first); and the last line always names where to
read the usage: `run 'pve-toolbox help <command>' for usage` when the command
itself is known, or `run 'pve-toolbox help' for usage` otherwise:

```
error: unknown command: stauts
did you mean: status?
run 'pve-toolbox help' for usage
```

This covers an unknown command, a flag the given command does not accept, an
unknown module or module tag, and an unknown top-level flag. An unknown tag to
`list` (for example `pve-toolbox list nope`) is a usage error too; earlier
releases printed nothing for a tag no module carries.

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
