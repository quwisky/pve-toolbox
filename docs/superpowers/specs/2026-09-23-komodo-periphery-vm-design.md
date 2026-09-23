# Komodo Periphery in existing Proxmox VMs

Date: 2026-09-23.

Status: implementation design. This extends the shipped LXC module on
`origin/master` at `179e034` and its
[LXC design](2026-09-22-komodo-periphery-lxc-design.md).

## Outcome and scope

An operator running pve-toolbox as root on a PVE 9 node can select one existing
local Linux VM and install, inspect, update, adopt, or uninstall a Komodo
Periphery systemd installation. The operator chooses QEMU Guest Agent (QGA) or
SSH as the transport. Transport selection is explicit and is never changed
automatically after a failure. Multiple VMs and LXCs can be tracked separately.

The first supported VM guest matches the LXC design: Debian 13 amd64 with Bash
and systemd. QGA mode requires an enabled, responsive QEMU Guest Agent whose
command execution is allowed. SSH mode requires an operator supplied address,
root key authentication, and a verified host key in a dedicated known-hosts
file. Neither mode installs QGA, SSH, Docker, or guest packages. Windows and
other Linux distributions are outside this initial support boundary.

All LXC design guarantees apply to VMs: a target-specific preview and consent,
exact release and checksum verification, protected credentials, service and
agent-identity preservation, rollback, ownership-checked removal, and honest
health reporting. The installed agent's root authority in the VM must be
presented before consent. Core enrollment is verified separately from local
service health.

## Approach

Implement the LXC plan's guest transaction helper once and add host-side
transport adapters for `lxc`, `qga`, and `ssh`. The guest helper receives the
same protected request and verified binary regardless of transport. Lifecycle
decisions, ownership checks, rollback, and service changes remain inside the
guest. The host handles target validation, transport, preview, and records.

The alternatives are a separate VM module, which would duplicate the
transaction engine, and an upstream installer invoked inside each VM, which
would lose the planned checksum, ownership, and rollback guarantees. Keep one
`komodo-periphery` module and add VM selection to its existing operator flow.

The LXC module has shipped and its `komodo-periphery-<CTID>` records must remain
readable. VM records use `komodo-periphery-qemu-<VMID>` and a separate managed
VM list. No LXC record migration is part of this feature.

## Target binding

Use the local node's PVE inventory to select exactly one non-template QEMU VM.
Reject invalid VMIDs, stopped or locked VMs, remote-node ownership, and
inconsistent PVE inventory/config/status reads. Do not start, unlock, migrate,
or change VM settings. Revalidate the VM before every guest action and after
acquiring the per-VM host lock.

QGA is tied to the selected PVE VMID by the host API. Require an enabled and
responsive agent, then inspect the guest machine ID, OS, architecture, service
layout, and transaction marker. SSH uses an operator supplied address and
host-key pin. Never derive an SSH destination solely from a reported guest IP.
For SSH, require a PVE `smbios1` UUID and compare it with the guest's DMI UUID
before mutation; a VM without that identity can use QGA or have its UUID
configured by the operator outside this module. Show VMID, node, VM name,
transport, SSH address and host-key fingerprint, PVE/guest UUID, and guest
machine ID in the preview. On later operations, compare these values with the
managed record. A mismatch requires fresh inspection and consent; it cannot
be forced past the check.

Keep guest-kind and VMID in every record, lock, doctor ID, and report. A VMID
reused for another guest must never inherit authority from the old record.
Switching a managed VM between QGA and SSH requires a fresh identity check and
target-specific confirmation; a failed transport does not trigger fallback.

## Transport contracts

`inspect` is read-only in both transports. It streams a self-contained guest
inspection script to Bash stdin and accepts one bounded, schema-validated JSON
result. It creates no guest file. The transaction helper uses that same
inspection code after it has been staged. Each mutable operation stages the
helper, verified binary, and protected request in a random root-owned
directory under guest `/run`, checks
the resulting file sizes and SHA-256 values in the guest, then invokes the
shared guest transaction helper. Guest staging paths are fixed by the module
and a validated nonce, never supplied as arbitrary operator paths.

SSH uses `BatchMode=yes`, strict host-key checking, no agent forwarding, and
the exact configured identity file and known-hosts file. No password, insecure
host-key acceptance, shell-interpolated operator input, or remote auto-discovery
is supported. Stream the helper, binary, and secret request over SSH stdin;
none are placed in command arguments. Limit output and time, and verify the
remote exit code. Root login is required in this first SSH version because
the transaction owns a system service and protected files.

QGA uses the PVE guest-exec and exec-status operations. The PVE file-write
endpoint overwrites a file and limits content to 60 KiB, while guest-exec
input is limited to 64 KiB. A small local bridge, run as root on the PVE node,
reads payloads from a protected file descriptor and calls the local PVE API;
it never puts onboarding keys or binary chunks in process arguments or logs.
The bridge accepts only the selected local VMID and a fixed set of QGA calls.
Stream inspection through guest-exec input. After consent, create a random
root-owned guest `/run` directory and place a small, non-secret staging receiver
there with one bounded file-write call. Verify its hash and mode before using
it. Stage larger files in bounded chunks through guest-exec input to that
receiver, which checks
nonce, offset, length, and per-chunk digest. Check a final whole-file digest
before invoking the transaction. Time out and poll guest processes explicitly;
reject truncated output, missing exit status, or a guest-agent disconnect.
Do not use file-write repeatedly to transfer a binary because each call
truncates the target.

Keep host and guest transaction intent until cleanup is proven. On QGA or SSH
loss after a mutation begins, report `transaction incomplete`; on the next
explicit operation, rebind the exact guest and resume the shared guest recovery
flow. A transport switch can recover only after the new transport proves the
same VM and guest identity.

## Operator flow and records

`install`, explicit `update`, `status`, `check`, `doctor`, and `uninstall` retain
the LXC plan's command names. Selection first chooses LXC or VM, then one local
guest; VM selection chooses QGA or SSH. An unqualified update-all skips guest
agents. Global `--yes` and `--force` do not bypass guest consent or adoption.

Store chosen SSH address, port, identity path, known-hosts path, transport,
Core address, server name, and selected version with the configuration helpers
under a guest-kind-qualified key. Store only derived facts such as UUIDs,
host-key fingerprint, machine ID hash, observed version, transaction status,
and owned paths through state helpers. The onboarding key is handled as a
protected short-lived input and never written to public state or output.
Private agent keys stay in the VM.

Status and doctor report each managed guest separately. A stopped service,
unreachable transport, ownership drift, failed rollback, or incomplete
transaction must not appear healthy. QGA health says whether the agent is
reachable, separately from Periphery service health. SSH health says whether
the pinned host can be reached, separately from service health. Neither
transport proves Komodo Core authentication without positive Core evidence.

## Validation

Test both adapters against command doubles and the real guest helper in an
isolated guest fixture. Cover wrong/stale VMID, node migration, template and
lock states, unavailable QGA, disabled QGA commands, QGA chunk truncation and
reordering, 60/64 KiB boundaries, process timeout, unexpected output, SSH
host-key change, wrong DMI UUID, SSH address drift, transfer interruption,
secret leakage, and cross-transport recovery. Reuse LXC tests for guest
transaction semantics rather than duplicating them.

Run `make lint`, the complete Debian 13 test suite with all required package
and repository gates, `mkdocs build --strict`, and `git diff --check` before
handoff. On a designated disposable PVE 9 node, validate fresh install and
update using both QGA and SSH against Debian 13 amd64 VMs, service persistence
after a controlled reboot, Core connectivity, rollback after induced failure,
and no change to host services. If no disposable PVE host is available, report
that integration gate as unrun.

## Sources

- [Komodo: Connect More Servers](https://komo.do/docs/setup/connect-servers)
- [Proxmox QGA API implementation](https://github.com/proxmox/qemu-server/blob/master/src/PVE/API2/Qemu/Agent.pm)
- [Proxmox QGA execution implementation](https://github.com/proxmox/qemu-server/blob/master/src/PVE/QemuServer/Agent.pm)
- [QEMU Guest Agent protocol](https://www.qemu.org/docs/master/interop/qemu-ga-ref)
