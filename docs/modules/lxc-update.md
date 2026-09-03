# LXC package updates

`pve-toolbox lxc-update` updates packages inside running Debian and Ubuntu LXC
containers on the **local PVE 9 host**. It is a manual maintenance command;
ordinary `pve-toolbox update` only updates toolkit modules.

## Run

Run these commands **as root on the PVE host**:

```bash
# Optional: configure saved exclusions and a Discord webhook.
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
```

Flags may be combined. `--yes` and `--force` cannot authorize execution;
a terminal and explicit confirmation are required. `--json` and `--quiet`
remain limited to the existing read-only reporting commands.

The plain menu has an `l` action. The full-screen menu has **Update LXC container
packages**, with preview selected by default and removals/Discord unchecked.
Enter optional IDs after selecting the options; leaving the field empty selects
all eligible guests. Package execution asks for confirmation once.

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
reboots, distribution-release upgrades, or scheduled/unattended runs**. Arrange
backups separately. Package maintainer scripts and existing guest hooks can
restart services; run during an appropriate maintenance window. A reboot result
only reports the guest's `/var/run/reboot-required` marker, not application health.

## Reports and configuration

The command shows progress and a final per-container summary. The last execution
or preview report is stored in `/var/lib/pve-toolbox/lxc-update.state`, with one JSON
record per `ct_ID` key plus completion, policy and notification state.
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

Run `pve-toolbox install lxc-update` to reconfigure. Use `none` to clear a field.
Configuration is optional unless exclusions or notifications are wanted.
Uninstall removes configuration and retains the last report.

`--notify` sends one bounded summary after a confirmed run, including failures or
cancellation. It contains the host, removal policy and per-container outcomes,
including held packages and reported reboot requirements when available. Long
summaries are marked as truncated; full retained detail stays local. Raw package
output is never sent. A missing or malformed webhook blocks execution before
any package changes. Delivery failure is displayed and recorded without changing
the package-update exit status. No notification is sent for previews or declined
confirmation.

Exit status is `0` for successful execution (including documented skips), `1`
for an operational or attempted-update failure, `64` for invalid arguments, and
`130` for cancellation after execution begins. Packages left held back are
reported but are not themselves a failure. An update success is a package-manager
result, not a service-health guarantee.
