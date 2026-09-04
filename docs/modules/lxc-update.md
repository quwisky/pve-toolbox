# LXC package updates

`pve-toolbox lxc-update` updates packages inside running Debian and Ubuntu LXC
containers on the **local PVE 9 host**. Updates can be confirmed manually or
explicitly scheduled. Ordinary `pve-toolbox update` only updates toolkit
modules and never starts guest maintenance.

## Run

Run these commands **as root on the PVE host**:

```bash
# Configure exclusions, a Discord webhook and optional automatic updates.
pve-toolbox install lxc-update

# Read-only guest preview using cached indexes, which may be stale.
pve-toolbox lxc-update --dry-run

# Show targets and policy, then ask for confirmation before updating.
pve-toolbox lxc-update

# Restrict the run to explicit local container IDs.
pve-toolbox lxc-update 101 102

# Permit dependency removals, unused dependency cleanup and obsolete downloads.
pve-toolbox lxc-update --allow-removals

# Request one final Discord report (requires a configured webhook).
pve-toolbox lxc-update --notify

# Inspect schedule health, next and previous runs, and the retained report.
pve-toolbox status lxc-update

# Explicitly test an enabled automatic-update service now.
systemctl start pve-toolbox-lxc-update.service
```

Flags may be combined. `--yes` and `--force` cannot authorize execution;
a terminal and explicit confirmation are required. `--json` and `--quiet`
remain limited to the existing read-only reporting commands.

The plain menu has an `l` action for manual updates and an `a` action for
automatic-update configuration. The full-screen menu has separate **Update LXC
container packages** and **Configure automatic LXC updates** actions. Manual
updates default to a preview with removals and Discord unchecked. Enter optional
IDs after selecting the options; leaving the field empty selects all eligible
guests. Package execution asks for confirmation once.

## Automatic schedule

Automatic updates are disabled until an operator enables them through
`pve-toolbox install lxc-update` or either menu. Configuration offers daily and
weekly presets plus a custom systemd `OnCalendar` expression. The suggested
schedule is Sunday at 04:00 in the host's local timezone.

One host timer runs one sequential batch over all currently eligible local
containers, honoring the saved exclusions. Configure every PVE node separately;
the service never enters containers on another node. New eligible containers are
included on later runs without reconfiguration.

The timer adds a random delay of up to 30 minutes so separately configured PVE
nodes do not all begin together. It does not catch up after host downtime and
does not start an update when first enabled. Use the explicit `systemctl start`
command above when an immediate test is wanted.

The service uses an installed runner, guest helper, and shared toolbox
libraries, so it does not depend on the source checkout remaining in place.

Scheduled runs always use the default non-removing upgrade policy. They cannot
accept container IDs, previews, `--allow-removals`, or `--notify`. The configured
service is the only unattended path; ordinary command-line execution continues
to require a terminal and confirmation. Automatic Discord reporting is a
separate opt-in setting and sends one final report for every scheduled batch.

Useful service commands, run as root, are:

```bash
systemctl list-timers pve-toolbox-lxc-update.timer
journalctl -u pve-toolbox-lxc-update.service
systemctl start pve-toolbox-lxc-update.service
```

Reconfigure the module and answer **No** to automatic updates to disable future
runs. This removes the service and timer while keeping exclusions, webhook
configuration, the saved calendar, the scheduled notification preference and
the last report. A later reconfiguration can enable the saved calendar again.

## Selection and package policy

- Only local running containers are eligible. Stopped guests, templates,
  unsupported guest types, and saved exclusions are reported as skipped.
- Explicit IDs must exist locally. Saved exclusions also apply to explicitly
  selected IDs; reconfigure the module to remove an exclusion.
- Local configuration, running state, template status and Proxmox locks are
  checked again immediately before entering each container. Unverifiable or
  locked targets fail visibly rather than being updated.
- By default, upgrades may install new dependencies but cannot remove packages.
  `--allow-removals` permits dependency-resolving upgrades, then `autoremove`
  and `autoclean`. It does not purge package configuration files or override
  package holds, authentication, downgrade, or essential-package protections.
- Changed package conffiles are preserved. Other package questions use
  noninteractive defaults. A package that cannot proceed fails for manual attention.
- Execution refreshes package indexes and rejects any refresh error. It then
  checks current repository metadata against the guest's installed release
  codename. Different or unverifiable base releases block that guest. Third-party
  repositories remain enabled and must have trusted metadata. Repository files
  are never rewritten. APT repository trust still depends on the guest's own
  administrator-managed configuration.
- A guest must provide Bash, APT with `indextargets` and lock-timeout support,
  dpkg, and an installed release codename. Missing prerequisites fail visibly.
  This feature does not extend the toolkit's host support beyond PVE 9 / Debian 13.

## Failures, cancellation and recovery

Containers run sequentially. A failure in one container does not prevent later
containers from being attempted. A host-level updater lock prevents overlapping
batches. APT waits up to 120 seconds for its package database lock; locks are
never deleted. A broken package database requires manual repair.

Ctrl+C stops further containers and waits for the active guest operation to
finish. There is no forced package-transaction timeout: a stuck maintainer
script can require manual intervention. A forced kill, host failure or lost
connection can leave the active container's outcome unknown; inspect the
saved in-progress state and guest package logs before running again.

There are **no automatic backups, snapshots, rollback, container starts,
reboots, or distribution-release upgrades**. Arrange backups separately. Package
maintainer scripts and existing guest hooks can restart services; choose an
appropriate maintenance window. A reboot result only reports the guest's
`/var/run/reboot-required` marker, not application health.

A scheduled batch that finds only documented skips succeeds. If an attempted
container update fails, later containers are still attempted and the service
returns failure after the batch. Failed containers are not retried or queued;
the next attempt is the next configured window or an explicit manual start.
Another manual or scheduled batch holding the updater lock causes the new run to
exit without entering a guest. An overlapping scheduled invocation is a
successful skip, records its timestamp separately from the active batch report,
and remains visible in status and the system journal.

The service runs with reduced CPU and idle I/O priority. systemd does not impose
a start or stop timeout and signals only the supervising process, allowing the
existing cancellation path to wait for an active APT/dpkg transaction. A stuck
maintainer script can therefore require manual intervention.

## Reports and configuration

The command shows progress and a final per-container summary. The last execution
or preview report is stored in `/var/lib/pve-toolbox/lxc-update.state`, with one JSON
record per `ct_ID` key plus invocation type, planned schedule, start and
completion times, policy and notification state.
Use `pve-toolbox status lxc-update` to inspect it. Reports use the shared credential filter, retain a bounded output tail
per container, and replace the previous run. Preview writes local report state
but never sends a notification.
Treat an in-progress report as incomplete, never as evidence of success.

Operator input is stored through the config helpers in
`/etc/pve-toolbox/lxc-update.conf` (mode `0600`):

| Setting | Meaning |
| --- | --- |
| `LX_EXCLUDE` | Space-separated container IDs to skip |
| `DISCORD_WEBHOOK` | Optional Discord webhook URL for this module |
| `LX_SCHEDULE_ENABLED` | `1` when automatic updates are explicitly enabled |
| `LX_SCHEDULE` | Validated systemd `OnCalendar` expression |
| `LX_SCHEDULE_NOTIFY` | `1` to report every scheduled batch to Discord |

Run `pve-toolbox install lxc-update` to reconfigure. Use `none` to clear a field.
Configuration is optional unless exclusions, notifications, or scheduling are
wanted. Existing hosts remain unscheduled until enabled. Module updates preserve
the exact saved calendar, enabled state, and scheduled-notification choice. If
the scheduled runner needs replacement while a batch is active, the module
update fails and asks the operator to retry after the batch finishes.

Uninstall disables and removes the timer, service, scheduled runner and
configuration, and retains the last report.

`--notify` sends one bounded summary after a confirmed manual run, including
failures or cancellation. An enabled automatic report uses the same bounded
format after every scheduled batch. It contains the invocation type, host,
removal policy and per-container outcomes,
including held packages and reported reboot requirements when available. Long
summaries are marked as truncated; full retained detail stays local. Raw package
output is never sent. A missing or malformed webhook blocks execution before
any package changes. Delivery failure is displayed and recorded without changing
the package-update exit status. No notification is sent for previews or declined
confirmation. If automatic reporting is enabled but its webhook is missing or
malformed, the scheduled service fails before entering any container.

`pve-toolbox status lxc-update` reports a configured timer as degraded when its
calendar is invalid, its runner or units are missing or unsafe, its timer is
disabled, inactive or failed, its webhook cannot support requested reports, or
its previous service execution failed. Timer history remains visible when a
degraded systemd timer can still provide it. Full execution history remains in
the system journal; the main structured state file contains only the most recent
preview, manual run, or scheduled run. The latest overlap skip is stored in
`/var/lib/pve-toolbox/lxc-update-overlap.state` so it cannot race the active
batch's report writes.

Exit status is `0` for successful execution (including documented skips), `1`
for an operational or attempted-update failure, `64` for invalid arguments, and
`130` for cancellation after execution begins. Packages left held back are
reported but are not themselves a failure. An update success is a package-manager
result, not a service-health guarantee.
