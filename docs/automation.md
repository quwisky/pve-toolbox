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
written.

## Exit codes

| Code | Meaning |
| ---: | --- |
| `0` | Success, including an empty or skipped-only report |
| `1` | Operational failure |
| `2` | Warning, including an available module update |
| `64` | Invalid command, flag, argument, or module name |
| `69` | Every meaningful result is unsupported on this host |

Failure takes precedence over warning, warning over success, and a successful
result over an unsupported one. This lets a broad doctor run report optional
unsupported subsystems without making a healthy host fail.

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
