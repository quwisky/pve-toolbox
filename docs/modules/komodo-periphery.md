# Komodo Periphery in LXC

Install, update or reconfigure **Komodo Periphery v2 as a systemd service** inside an existing
local LXC. Run the toolbox as **root on the PVE 9 host**. The initial supported
guest is **Debian 13 amd64**, including unprivileged containers.

The module installs the agent only. It does not create containers, install
Docker, install guest packages, change nesting or privileges, or change firewall
rules. Docker workloads require a separately configured Docker installation.
Core must already exist; choose a Periphery release compatible with your Core.

## Prerequisites

The guest must be running, unlocked, and use systemd. It needs Bash, jq,
coreutils, util-linux (`flock`), sed, findutils and dpkg-query. A missing
prerequisite is reported before installation. If necessary, an administrator
can install missing packages inside the guest; the module does not do this.
The host needs its usual Proxmox tools, curl and jq.

For a new installation, have the Core HTTP or HTTPS URL, a server name and a Core v2
onboarding key ready. Create the onboarding key in Core. The prompt hides the
key and transfers it in a protected file. The new agent connects outward to
Core, with its inbound listener explicitly disabled. HTTP connections are
unencrypted; HTTPS connections retain certificate validation. Core URLs may include
a port and path, but must not include credentials, a query or a fragment.
See [Komodo's connection guide](https://komo.do/docs/setup/connect-servers).

The new service runs as **root inside the guest**. Core can execute agent actions
with that account's privileges. The preview identifies the container and service
account before asking permission to apply changes.

## Install and update

Run these commands **as root on the PVE host**:

```bash
pve-toolbox install komodo-periphery
pve-toolbox update komodo-periphery
pve-toolbox check komodo-periphery
pve-toolbox status komodo-periphery
pve-toolbox doctor
pve-toolbox uninstall komodo-periphery
```

Install, update and uninstall select **one container per operation**. Repeat the
flow for additional containers. Install offers to update an existing agent's
executable or edit its connection configuration.
The plain menu's install/reconfigure action supports the same flow; its update-all
operation skips guest agents. The full-screen Update checklist leaves this
module unchecked until selected. Container-specific confirmation is still required.

Choose an exact stable v2 version, for example `2.3.3`, after checking Core
compatibility. The binary is fetched from the selected official GitHub release,
verified against that exact asset's SHA-256 metadata, and checked again inside
the guest before replacement. Missing or ambiguous checksums fail the operation.
A GitHub digest verifies integrity; it is not an independent signing certificate.
Downgrades and prereleases are not supported. Repeating a same-binary update does
not restart the agent.

`check` reports the installed version and the saved target version. It neither
changes the guest nor silently selects the latest release. To select a newer
release, run the explicit update flow. An ordinary `pve-toolbox update` never
updates Periphery agents, and toolbox APT upgrades never enter guests.

All mutations need a terminal and explicit confirmation. `--yes` and `--force`
cannot bypass this requirement. Declining the preview leaves the guest unchanged.
Read-only `status`, `check`, and `doctor` use the normal JSON/reporting interfaces.

## Updating an existing installation

The module can adopt a supported root-owned v2 executable managed by the system
`periphery.service`, including the standard upstream installer layout and direct
commands with custom absolute executable/configuration paths. Adoption shows the
detected installation and asks for separate confirmation.

An ordinary update replaces the executable and preserves configuration contents,
agent identity keys, unit files, drop-ins, connection mode, service account and
workloads. Enabled and active states are independent: an inactive service stays
inactive, and a disabled service is not silently enabled. When an active service
is restarted, local startup is checked before success is reported.

Unsupported installations are rejected before replacement: v1 agents,
package-manager-owned binaries, user services, masked units, Docker agents,
ambiguous shell wrappers, service environment configuration overrides, symlinked
or unsafe target paths, and unknown versions. Configuration directories and
complex continued service commands require manual review; this first version
supports explicit configuration files. Customizations are preserved when supported,
not silently rewritten into the standard layout.

Changes to an owned executable or service after adoption are reported as drift.
Do not force an overwrite. Inspect the installation and retained ownership
record first. A container identity change also blocks reuse of old host records.

## Updating connection configuration

Run `pve-toolbox install komodo-periphery` **as root on the PVE host**, select the
existing container, then choose **configure** at the existing-agent prompt.
The plain and full-screen install/reconfigure actions offer the same choice.
This edits configuration without downloading or upgrading the executable.

- Set the Core HTTP/HTTPS URL and server name, or leave either blank to keep it.
- Choose **keep**, **replace** or **remove** for the onboarding key. A replacement
  key is entered privately; existing keys are never displayed.
- Review the selected changes and confirm before applying them.

Configuration editing requires **Python 3.11 or newer in the guest** (including
the standard `tomllib` module). The toolbox does not install this dependency.
It supports one protected TOML file, including a custom file path, up to 1 MiB.
Selected connection fields must have unambiguous single-line assignments.
Invalid TOML, ambiguous edits, multiple config files and JSON/YAML configurations
are refused without stopping the service. Binary updates still support their
existing configuration layouts.

Comments and unrelated settings, configuration ownership and permissions, unit
files and the agent identity key are preserved. Changing the Core URL does not
reset the agent identity or guarantee that a different Core accepts it.
An active service restarts only when the configuration changes; an inactive or
failed service stays stopped, and its enabled/disabled policy is preserved.
Unchanged settings do not restart the agent. Confirm connectivity in Core after
an edit, and start a previously stopped service separately when appropriate.

The previous configuration is backed up before replacement. Restart failure
restores it and reports the original startup diagnostics and rollback result.
Interrupted edits use the same recovery flow as binary updates. If the file
changes after preview, the operation refuses to overwrite it.

## Paths and retained data

Fresh installations create these files **inside the guest**:

| Path | Purpose |
| --- | --- |
| `/usr/local/bin/periphery` | Agent executable |
| `/etc/komodo/periphery.config.toml` | Root-readable agent configuration |
| `/etc/systemd/system/periphery.service` | System service |
| `/etc/komodo/keys/` | Protected agent identity directory |
| `/var/lib/pve-toolbox/komodo-periphery/` | Protected ownership, transaction and recovery records |

Adopted installations keep their existing supported paths. The private key
remains in the guest. Binary updates do not remove onboarding keys or rewrite
connection configuration. After confirming enrollment in Core, use the configure
action to remove the onboarding key if desired; retain the agent private key.

The host stores desired versions and target identity through protected config
helpers in `/etc/pve-toolbox/komodo-periphery-CTID.conf`. The managed ID list is
`/etc/pve-toolbox/komodo-periphery.conf`. Non-secret outcomes are recorded in
`/var/lib/pve-toolbox/komodo-periphery-CTID.state`. Credentials are not stored in
host state. Temporary transfer files are protected and removed after the operation.

## Failure and recovery

The host and guest use locks, and agent changes wait for an operator to retry
when toolbox LXC package maintenance is active. The module checks locality and
identity again before transfers and mutation. It never starts, unlocks, reboots,
or migrates a container automatically.

A failed update restores the previous executable and toolbox-changed files and
checks the previous service state. Recovery failure is reported separately.
If the new service fails to start or remain healthy, the error includes the
start command's message, systemd state/result and process exit status, and up to
20 recent journal entries from that startup attempt. These details are captured
**before rollback**, so restarting the previous version does not hide the original
failure. Credential-bearing journal entries are withheld, other known credential
forms are filtered, and terminal control characters are removed. Diagnostic
collection has time and size limits; unavailable or oversized logs are reported
without preventing rollback. Diagnostics are displayed, not saved in toolbox state.
Backups include the original adopted installation and the previous transaction's
files. Do not delete transaction records or lock files to bypass a failure.

Host failure or guest disconnection can prevent immediate rollback or cleanup.
Rerun the explicit install/update flow for that same container. It offers to
recover a pending guest transaction or reconcile a completed guest transaction
whose host bookkeeping failed before attempting another change. If identity or
locality no longer matches, inspect it manually first. Incomplete cleanup retains
the protected staging location's transaction identifier in host configuration.

Rollback covers agent binary, service and toolbox-owned configuration changes.
It cannot undo commands already executed by Core or changes made to workloads.

Status distinguishes local service health from Core enrollment. **A running
service does not prove that Core accepted it.** Confirm that Core shows the
server online after installation, update and a separately scheduled reboot.
A stopped service is reported even when leaving it stopped was intentional.

Uninstall stops/disables the owned service and removes its executable and unit.
It retains configuration, identity keys, service overrides, stacks, repositories,
Docker data, adoption backups and Core's server record. Retained custom overrides
can affect a future installation and should be inspected before reuse.

## Validation limits

Automated tests exercise the real shell implementation in isolated guest roots
with controlled Proxmox and systemd boundaries. Release acceptance also requires
a disposable PVE 9 LXC and a Core v2 instance to check actual systemd startup,
agent enrollment, updates and reboot persistence. Mocked guest tests do not prove
live Core connectivity.
