# Komodo Periphery in existing LXC containers

Status: approved by the user on 2026-09-22; no implementation is included.

Date: 2026-09-22.

Repository baseline: `origin/master` at
`a094197a1f7432c69ef4a7e1232931ca479cdbf3`. The current checkout is an older
development branch; implementation must start from the current default branch.

## Outcome and agreed scope

An operator running pve-toolbox as root on a PVE host can install Komodo
Periphery into an existing local LXC and update an existing Periphery systemd
installation, including a supported installation created outside pve-toolbox.
The user selected existing containers only, Komodo Core v2, and Periphery only
with systemd. Docker installation and container creation are outside this work.

Success means a selected container runs the selected Periphery version under
systemd, the service survives a container reboot, and its existing Komodo Core
v2 reports the agent connected. Updating preserves configuration, agent identity,
service customizations, and workloads. A failed operation is visible and does
not leave the toolbox claiming that an unhealthy installation is healthy.

The initial supported environment is a Debian 13 amd64 guest with Bash and
systemd on a local PVE 9 host. Include an unprivileged LXC in integration tests.
Neither container privileges nor nesting, firewall, mount, or Docker settings
are changed. Periphery's permissions inside the guest must be explained before
installation: the default system service runs as guest root and enables Core
to execute actions with that account's privileges.

## Approach

Add a host-only module named `komodo-periphery`. It uses Proxmox commands to
inspect and enter the chosen guest, and a small guest helper to perform guarded
installation transactions. Module discovery remains side-effect free.

Manage the released binary and systemd service directly, using the shared
toolbox helpers for release metadata, configuration, state, prompts, and output.
This gives the toolbox control over verification and recovery. The alternative
of invoking upstream's installer is simpler to integrate but does not supply
the required transaction and ownership behavior. Running Periphery in Docker
would introduce a runtime dependency outside the agreed scope.

Komodo recommends systemd for Periphery. Its v2 configuration supports outbound
connections to Core and onboarding keys. New installations use outbound mode
and explicitly disable the inbound server. Existing installations retain their
connection mode and authentication settings when only the binary is updated.

## Operator flow

The following describes proposed behavior, not commands available today.

- `pve-toolbox install komodo-periphery` selects one local LXC, inspects it,
  and offers installation or an update of a detected installation.
- `pve-toolbox update komodo-periphery` explicitly enters the agent update
  flow, selects one container, and previews the installed and requested versions.
  It also permits inspecting and adopting a supported pre-existing installation.
- `pve-toolbox check komodo-periphery` reports versions and available
  candidates without changing guests. This uses the existing launcher's
  read-only command, which invokes `module_update --check` internally.
- `pve-toolbox status komodo-periphery` and the existing doctor integration
  report the managed containers and their individual health.
- `pve-toolbox uninstall komodo-periphery` selects one managed container and
  previews exactly which owned service and executable files will be removed.

Each operation targets one container; repeat it for additional containers.
Multiple managed containers have separate configuration and state records.
The menus expose the same operations through the existing module UI.

Guest mutation requires a target-specific preview and interactive confirmation.
The preview identifies the node, container ID and name, action, versions, paths,
service account, connection mode, and expected service interruption. Global
`--yes` or `--force` does not bypass this confirmation or authorize adoption.

An unqualified toolbox-wide update must not update guest agents implicitly.
The launcher must distinguish explicit module selection from update-all before
dispatching a guest update. Update-all reports that Periphery updates require
explicit selection. Package installation and upgrade never enter containers.

Fresh setup asks for Core's HTTPS URL, the server name, an onboarding key, and
an exact stable v2 release appropriate to the operator's Core version. Preserve
certificate validation. Do not infer compatibility merely because both
versions start with 2, or automatically jump to an unrelated latest release.
Version changes are explicit; same-version installs are idempotent and
downgrades are not supported in this first version.

## Components and integration

- `modules/komodo-periphery/module.sh`: metadata, prompts, lifecycle hooks,
  aggregate status, and doctor reporting.
- `modules/komodo-periphery/guest.sh`: guest inspection, validated file
  operations, service changes, rollback, and uninstall.
- `lib/pve.sh`: narrowly scoped shared local-container validation helpers.
  Reuse the safety rules demonstrated by `lxc-update`; avoid a broad refactor.
- `lib/common.sh`: extend release verification to accept an exact asset's
  valid GitHub SHA-256 digest when a checksum manifest is unavailable. Preserve
  the existing checksum-manifest behavior and fail-closed guarantees.
- `pve-toolbox`: explicit-selection dispatch needed to protect guests from
  implicit update-all and unconfirmed multi-module operations.
- Tests, Bash and Zsh completion coverage, module documentation, README module
  list, module overview, and documentation navigation accompany the feature.

The package already copies ordinary module directories. Verify the new helper
is present in the built package and operates without a source checkout. No
package migration or post-install guest action is needed. Release Please keeps
ownership of version changes and generated release entries.

## Target and ownership checks

Use the local node's Proxmox inventory. Reject invalid IDs, templates, stopped
containers, locked containers, unsupported guests, and remote-node targets.
Revalidate locality, running state, configuration, and recorded identity before
each mutating phase. Retain enough guest identity information to detect normal
container-ID reuse; an identity mismatch requires fresh inspection and consent.
Do not start, reboot, unlock, or migrate a container automatically.

Use locks to prevent overlapping toolbox operations on the same target. The
guest helper also holds a guest-local lock. Coordinate with toolbox LXC package
maintenance where applicable. If the container disappears or moves during an
operation, stop and report an incomplete outcome; do not act on another node or
retry against an unverified replacement container.

Before adoption, inspect `periphery.service`, its effective settings and
drop-ins, binary path, configuration paths, service user, and installed version.
Show those findings and require explicit adoption confirmation. Support the
standard upstream root/systemd layout, including its known shell-wrapped
ExecStart form, and clearly resolved direct-binary services. Parse supported
forms without evaluating arbitrary unit text as shell code.

Preserve supported custom paths and service overrides. Refuse ambiguous shell
wrappers, multiple or unresolved executable targets, package-owned binaries,
Docker-based agents, systemd user services, and unknown versions. A detected
v1 installation is reported as requiring a separate v1-to-v2 migration; this
feature must not silently convert its authentication or configuration.

Record adoption only after a successful transaction. Keep the pre-adoption
service and binary backup. Future changes compare recorded ownership and
relevant file fingerprints; unexplained drift requires inspection rather than
overwriting administrator changes. Reject unsafe symlinks and non-regular
replacement targets, and validate directories before writing or deleting.

## Configuration, credentials, and agent identity

For a fresh installation, use `/usr/local/bin/periphery`,
`/etc/komodo/periphery.config.toml`, and
`/etc/systemd/system/periphery.service` inside the guest. Preserve upstream's
agent root-directory convention, including its private-key location. Use
root-readable configuration and protected key directories; do not weaken
existing restrictive permissions on an adopted installation.

Use toolbox config helpers for host-side operator settings, including the
target selection and desired version. State helpers store only derived,
non-secret facts such as the observed version, identity fingerprint, paths,
ownership, and last transaction result. Do not persist onboarding credentials
in host state. Transfer secrets through protected input/files, never command
arguments, and remove temporary copies on success, failure, and cancellation.
Filter guest output before terminal display or retention.

Agent private keys remain in the guest and survive updates and uninstall.
Onboarding keys are unnecessary after successful enrollment according to
upstream. Do not remove an onboarding key on the assumption that a running
service proves enrollment; only remove it after positive enrollment evidence
or explicit operator confirmation. No Core API credential is required for the
initial module. The operator can confirm enrollment in Core's UI.

## Installation and update transaction

1. Inspect and validate the exact target, existing installation, ownership,
   prerequisites, selected release, and available storage.
2. Resolve exactly one `periphery-x86_64` asset from the selected upstream
   release. Require a valid SHA-256 value, download over HTTPS, verify the
   staged binary on the host. Missing,
   ambiguous, or mismatched checksum information aborts before service changes.
   A metadata checksum is integrity verification, not an independent signature.
3. Produce the preview, obtain confirmation, acquire locks, and recheck the
   target and inspected files before mutation.
4. Transfer the staged binary and verify its checksum inside the guest.
   Securely back up the previous binary and any files the operation will
   change, including their permissions and prior service enabled/active state.
   Validate the candidate's version before stopping the current service.
5. Stop Periphery only after staging succeeds. Atomically replace the binary.
   Create configuration and the unit for a fresh installation; an ordinary
   update preserves existing configuration and service customizations.
6. Reload systemd when needed and enable/start a fresh installation. An update
   restores the prior enabled/active policy: previously stopped or disabled
   services are not silently enabled. For a previously running service, require
   sustained startup and the expected executable/version before local success.
7. Record the outcome only after local checks complete. Retain the previous
   version as a bounded recovery copy. Report Core enrollment separately.

If a changed service fails to start, restore the previous binary and all
toolbox-changed files, restore the previous service policy, and check recovery.
Report the original failure and any recovery failure separately. Never report
successful recovery merely because a restore command was attempted.

Cancellation uses the same recovery path when the guest remains reachable.
Host failure or lost guest access can prevent immediate rollback; retain an
in-progress transaction marker and validated backup paths for the next run.
The next mutation must resolve that incomplete transaction first. Rollback
covers toolbox-owned binary/configuration/service changes, not commands already
executed by Core or arbitrary changes made by the agent to workloads or data.

Missing guest prerequisites produce actionable errors. This first version
does not install Docker, run guest package upgrades, or add package repositories.

## Health and uninstall

Report each container as not installed, running, stopped, unreachable, drifted,
failed, or transaction incomplete, with an explanatory reason. Show installed
and selected versions and whether the service is enabled. A running process
does not prove Core authentication or enrollment; label that result unverified
unless there is positive evidence. Retained operator confirmation must be
identified as historical, not a live connectivity measurement.

Uninstall requires ownership and target checks plus a preview and confirmation.
Stop/disable the selected owned service, remove only owned executable and unit
files, and retain configuration, private keys, stacks, repositories, Docker
data, and unrelated service customizations. Report retained files and any
remaining administrator overrides. Do not recursively delete `/etc/komodo`
or remove the Core server record. Keep failure/recovery records when cleanup
is incomplete.

## Validation and acceptance

Automated tests must cover side-effect-free discovery; fresh installation;
updating and adopting a standard existing systemd installation; supported
custom paths; idempotence; disabled/stopped service preservation; and multiple
independently tracked containers.

Failure tests must cover unsupported guests/layouts/v1 versions, invalid and
reused IDs, stopped/locked/remote containers, locality changes, ownership drift,
concurrent operations, unsafe paths, absent or mismatched checksums, incomplete
downloads/transfers, service start failure, rollback failure, cancellation,
incomplete transaction recovery, secret redaction, and uninstall retention.
Test that update-all, package lifecycle hooks, discovery, and update checks do
not mutate guests. Verify exact guest targets and that executable/service
installation never happens on the PVE host.

Before implementation handoff, run `make lint`, the complete Debian 13 test
suite with all required gate flags, and `mkdocs build --strict`. Package and
repository gates apply because package contents change. Exercise both terminal
interfaces and completions; capture the changed terminal flow for PR evidence
as required by repository guidance.

On a disposable PVE 9 host, test an unprivileged Debian 13 amd64 LXC with a
Core v2 instance: fresh installation, adoption of an upstream systemd install,
an actual older-to-newer supported v2 update, induced startup failure and
recovery, agent identity preservation, container reboot persistence, Core
connectivity, and uninstall retention. The human must be told if this hardware
validation is unavailable; mocked command tests do not substitute for it.

This specification adds no runtime behavior. No runtime tests or PVE integration
tests have been performed for the proposed feature.

## Sources

- [Komodo: connect more servers](https://komo.do/docs/setup/connect-servers)
- [Komodo v2.3.3 configuration](https://github.com/moghtech/komodo/blob/v2.3.3/config/periphery.config.toml)
- [Komodo v2.3.3 systemd installer](https://github.com/moghtech/komodo/blob/v2.3.3/scripts/setup-periphery.py)
- [Komodo v2.3.3 release metadata](https://api.github.com/repos/moghtech/komodo/releases/tags/v2.3.3)

The versioned references document research inputs; they do not mandate that
v2.3.3 remain the default when the module is implemented.
