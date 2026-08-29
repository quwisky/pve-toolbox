# certificate-watch

`certificate-watch` adds a read-only cluster TLS and native ACME audit to
`pve-toolbox doctor`. It never orders, renews, installs, or replaces a
certificate.

```text
Module      certificate-watch
Config      /etc/pve-toolbox/certificate-watch.conf (0600)
State       /var/lib/pve-toolbox/certificate-watch.state (0644)
Mutations   module configuration only
```

## Configure

```bash
pve-toolbox install certificate-watch
pve-toolbox doctor
```

The module inspects each node returned by the cluster API. It prefers the
custom proxy bundle `pveproxy-ssl.pem` and otherwise checks the internal
`pve-ssl.pem`. An unavailable node is reported without preventing checks of
the replicated certificate files or the other nodes.

For each active certificate, the report includes:

- expiry against configurable UTC thresholds;
- DNS hostname coverage from the leaf certificate;
- issuer, subject, and subject alternative names;
- chain verification against the system trust store for custom certificates,
  or the cluster root CA for internal certificates.

Thresholds are inclusive: an already-expired certificate fails, a certificate
at or below the failure boundary fails, and one at or below the warning
boundary warns. Defaults are 7 and 30 days.

```ini title="/etc/pve-toolbox/certificate-watch.conf"
CW_WARN_DAYS=30
CW_FAIL_DAYS=7
CW_ACME_STALE_DAYS=45
```

When ACME is configured, `acmerenew` and `acmenewcert` task history is read
from every node. The latest failure is a failure when it is newer than the
latest success; an absent or stale success is a warning. An unavailable or
malformed node history fails the audit rather than hiding a partial result.
Task inspection does not trigger renewal.

## Monitoring

JSON output and the shared native notification helper can be combined in a
timer or external monitoring job:

```bash
report=$(mktemp)
trap 'rm -f -- "$report"' EXIT
rc=0
pve-toolbox doctor --json >"$report" || rc=$?
if jq -e '.results[] | select(.id | startswith("module.certificate-watch."))
  | select(.state == "warn" or .state == "fail")' "$report" >/dev/null; then
  pve-toolbox-native-notify warning certificate-watch \
    "certificate watch requires attention (doctor exit $rc)"
fi
```

The helper is installed by `native-notifications`. Sending remains an explicit
monitoring action; running doctor alone never sends anything.

## Limitations

- Chain validation reflects the local node's current trust store.
- ACME health is inferred from the most recent 200 tasks on each node, so older
  history may be unavailable.
- The audit complements certificate and ACME checks in Proxmox; it does not
  replace renewal monitoring or official operational guidance.
