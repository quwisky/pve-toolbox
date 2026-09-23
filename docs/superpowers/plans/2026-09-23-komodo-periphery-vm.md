# Komodo Periphery VM Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development or superpowers:executing-plans to
> implement this plan task by task. Steps use checkbox syntax for tracking.

**Goal:** Install and manage Komodo Periphery in selected existing PVE VMs
through either QEMU Guest Agent or SSH.

**Architecture:** Extend the planned `komodo-periphery` module rather than
building a second lifecycle engine. The host validates an exact QEMU target
and uses one explicit transport to run the shared guest inspection and
transaction helper. Both transports deliver the same protected request and
checksum-verified release; guest-side ownership, rollback, and recovery stay
transport-independent.

**Tech Stack:** Bash, PVE 9 `pvesh`/QGA and Perl API modules, OpenSSH, jq,
systemd, SHA-256, shell fixtures, Debian packaging, MkDocs.

**Spec:** [VM design](../specs/2026-09-23-komodo-periphery-vm-design.md),
extending the [LXC design](../specs/2026-09-22-komodo-periphery-lxc-design.md).
Read the [LXC implementation plan](2026-09-22-komodo-periphery-lxc.md) too.

## Global Constraints

- Target one existing local PVE 9 QEMU VM per action. Initial guest support is
  Debian 13 amd64 with Bash and systemd.
- Support both QGA and SSH; operator selects the transport explicitly. Never
  switch transports after failure without rechecking guest identity and consent.
- QGA must be enabled, responsive, and permit execution. SSH requires root
  key authentication, strict pinned host-key checking, and a PVE `smbios1`
  UUID matching the guest DMI UUID.
- Do not install QGA, SSH, Docker, guest packages, or new repositories; do not
  change VM settings, power, networking, or migration state.
- Preserve the LXC design's checksum, ownership, secret, consent, rollback,
  uninstall-retention, and honest-health guarantees.
- `--yes`, `--force`, update-all, package lifecycle, discovery, and check-only
  never authorize a VM mutation.
- Keep Bash compatible with Debian 13 / PVE 9. Keep module sourcing free of
  side effects. Use shared config/state/reporting helpers and kind-qualified
  records and locks.
- This is a plan only. Do not mutate a production guest while implementing or
  testing. The two prior LXC planning documents are untracked user work; keep
  them intact. Do not commit, push, or create a PR for this feature unless the
  user separately requests it.

## Review Focus

1. VMID reuse or live migration during transfer must abort before any further
   guest action; exercise it in Tasks 1, 2, and 4.
2. A pinned SSH host key for the wrong VM must fail the DMI UUID check before
   staging; exercise it in Task 4.
3. QGA has 60 KiB file-write and 64 KiB exec-input limits. Chunk boundaries,
   truncation, reordering, and agent loss must fail closed; exercise Task 3.
4. Secrets must not appear in process arguments, PVE task logs, shell trace,
   public state, or doctor output; exercise Tasks 3 through 5.
5. A successful guest commit followed by lost host connectivity or record
   failure must remain recoverable and must not report healthy; exercise Task 5.

## Baseline and file map

The LXC module, helper, and tests named below have shipped in v0.9.0 on this
branch's `origin/master` baseline. Preserve the shipped LXC record names and
`KP_IDS` list. Add separate `komodo-periphery-qemu-<VMID>` records and a VM
list; do not migrate existing LXC records. Reuse the guest transaction contract
and keep existing LXC behavior covered while adding the VM flow.

| File | Responsibility |
| --- | --- |
| `modules/komodo-periphery/module.sh` | Metadata and lifecycle entry points |
| `modules/komodo-periphery/host.sh` | Guest selection, consent, common orchestration and records |
| `modules/komodo-periphery/guest.sh` | Shared inspection, transaction and recovery |
| `modules/komodo-periphery/stage-receiver.sh` | Small guest staging bootstrap and chunk verification |
| `modules/komodo-periphery/transport-lxc.sh` | Existing `pct` adapter, changed to common interface |
| `modules/komodo-periphery/transport-qga.sh` | QGA invocation, polling, bounded staging |
| `modules/komodo-periphery/qga-bridge.pl` | Local PVE API calls from protected stdin; no secret argv |
| `modules/komodo-periphery/transport-ssh.sh` | Pinned SSH execution and streamed staging |
| `lib/pve.sh` | Exact local QEMU inventory/config/status validation |
| `tests/komodo-periphery-vm*.sh` | VM target, QGA, SSH, and lifecycle regressions |
| `tests/fixtures/komodo-periphery/*` | Disposable PVE/QGA/SSH command doubles |
| `docs/modules/komodo-periphery.md` | VM setup, operation, recovery, limits |
| `README.md`, `docs/modules/index.md`, `mkdocs.yml` | User entry points and navigation |
| `Makefile`, `tests/package.sh`, `tests/repository.sh` | Test registration and packaged behavior |

## Task 1: Make guest identity and host records guest-kind aware

**Files:** Modify `modules/komodo-periphery/host.sh`, `module.sh`, and
`tests/komodo-periphery.sh`; create `modules/komodo-periphery/vm.sh` and
`tests/komodo-periphery-vm-records.sh`.

**Interfaces:** `kp_target_key <lxc|qemu> <decimal-id>` prints
`lxc-<id>` or `qemu-<id>` only for a validated kind/ID. Host config/state
VM keys are `komodo-periphery-qemu-<id>`; existing LXC keys remain
`komodo-periphery-<id>`. `kp_transport_inspect` and
`kp_transport_stage_apply` are the common adapter entry points; each receives
kind, ID, node, and an explicit transport. Guest transaction request schema
stays unchanged.

- [ ] Write a failing record-isolation test. Create managed fixture records for
  LXC 101 and QEMU 101; assert distinct keys, locks, status lines and doctor
  IDs, and confirm uninstalling one never names the other:

  ```bash
  [[ $(kp_target_key lxc 101) == lxc-101 ]] || fail 'LXC key'
  [[ $(kp_target_key qemu 101) == qemu-101 ]] || fail 'VM key'
  if kp_target_key qemu '../101'; then fail 'unsafe VMID accepted'; fi
  ```

- [ ] Run `bash tests/komodo-periphery.sh`; expect the new key and adapter
  interface assertions to fail.
- [ ] Implement `kp_target_key` with an exact kind allowlist and decimal ID
  validation. Keep shipped LXC record names and add a separate VM list. The
  existing `guest.sh` is 36 KiB and can be streamed for read-only QGA
  inspection; enforce a 60 KiB build-time limit and split it only if it grows
  past that bound. Move only transport calls out of `host.sh`:

  ```bash
  kp_target_key() {
      [[ $1 == lxc || $1 == qemu ]] || return 1
      [[ $2 =~ ^[1-9][0-9]{2,8}$ ]] || return 1
      printf '%s-%s' "$1" "$2"
  }
  ```

- [ ] Run the LXC host/guest suites. Test an LXC id reused as a VM id and a
  wrong guest-kind recovery request; both must be rejected without mutation.

## Task 2: Validate an exact local QEMU target

**Files:** Modify `lib/pve.sh`; create `tests/komodo-periphery-vm-target.sh`;
extend fixture PVE commands and `Makefile`.

**Interfaces:** `pve_qemu_inventory <local-node>` sets `PVE_QEMU_JSON` to a
validated local array or clears it and sets `PVE_QEMU_ERROR` on failure.
`pve_qemu_ready <local-node> <vmid>` fetches config and current status, sets
`PVE_QEMU_CONFIG_JSON`, and succeeds only for a running, unlocked,
non-template QEMU VM still on that node. Both functions are read-only.

- [ ] Add fixture responses for `/nodes/pve1/qemu`,
  `/nodes/pve1/qemu/201/config`, and
  `/nodes/pve1/qemu/201/status/current`; log every endpoint and fail unknown
  calls. Write the successful and rejected cases:

  ```bash
  pve_qemu_ready pve1 201 || fail 'local running VM rejected'
  for id in 0 99 201x '../201'; do
      if pve_qemu_ready pve1 "$id"; then fail 'unsafe VMID accepted'; fi
  done
  PVE_TEST_MODE=remote
  if pve_qemu_ready pve1 201; then fail 'remote VM accepted'; fi
  [[ -z $PVE_QEMU_CONFIG_JSON ]] || fail 'stale config retained'
  ```

- [ ] Run `bash tests/komodo-periphery-vm-target.sh`; expect missing helper
  failures. Implement exact local-node API calls and reject duplicate IDs,
  malformed JSON, templates, locks, stopped VMs, and changed locality. Validate
  node/VMID before interpolating either into an endpoint.
- [ ] Add cases for agent disabled, missing SMBIOS UUID in SSH mode, and changed
  SMBIOS UUID. The generic readiness helper may return a valid VM without QGA;
  the QGA/SSH adapter applies its own stricter prerequisites.
- [ ] Run `bash tests/pve.sh` and the new target test; inspect logs to confirm
  no VM power or config write endpoint was called.

## Task 3: Implement bounded QGA transport without secret arguments

**Files:** Create `transport-qga.sh`, `qga-bridge.pl`,
`stage-receiver.sh`, and `tests/komodo-periphery-vm-qga.sh`; extend fixtures
and `Makefile`.

**Interfaces:** `kp_qga_exec <node> <vmid> <command-json> <stdin-file>` starts a
guest command and polls its PID until exit, returning bounded stdout/stderr
and exact exit code. The bridge reads a JSON request from stdin, accepts only
`exec`, `exec-status`, and a bounded `file-write` for the fixed staging
receiver path, calls the local PVE QGA implementation, and emits a
single JSON response. `kp_qga_stage <node> <vmid> <kind> <host-file> <guest-run-dir>`
streams chunks of at most 48 KiB; `stage-receiver.sh stage-chunk` validates transaction
nonce, kind (`helper|binary|request`), offset, byte count and SHA-256 before
append. A final guest-side whole-file SHA-256 check is mandatory.

- [ ] Write bridge tests with stub PVE Perl modules. Reject remote node,
  unknown operation, excessive body, invalid VMID, invalid command array and
  payload over 48 KiB. Assert that argv contains only fixed bridge path,
  operation and VMID, never a fixture onboarding key.
- [ ] Run `bash tests/komodo-periphery-vm-qga.sh`; expect failure because the
  adapter and bridge are absent.
- [ ] Implement the bridge with PVE CLI environment setup and PVE's local
  QGA execution/status functions. Read bounded JSON from stdin; decode the
  payload in memory, validate the local VM owner, and never print input data.
  Do not invoke `pvesh --input-data` or `pvesh --content` for secrets: those
  options would put the value in process arguments. `file-write` accepts only
  the small non-secret receiver at the nonce-bound `/run` path. Keep Perl
  limited to this bridge, since the rest of the toolkit is Bash.
- [ ] Implement QGA inspect by invoking `/bin/bash -s -- inspect` with the
  `guest.sh` script as exec input. Make the serialized inspection script
  smaller than 60 KiB and assert that size in tests. Poll exec-status with a
  deadline; require `exited`, no signal, no truncation, valid JSON and expected
  exit status. Reject an agent disconnect rather than retrying on another node.
- [ ] Implement post-consent guest staging. First create and validate a random
  root-owned directory under guest `/run`; transfer the non-secret
  `stage-receiver.sh` via the bridge's bounded file-write and verify its hash
  and mode. `stage-chunk` writes only to the
  nonce-bound root-owned guest `/run` directory and requires current length to
  equal the requested offset; it receives bytes through stdin. The host sends
  binary chunks in order, checks per-chunk acknowledgments, then verifies
  total size and SHA-256. Apply the same protocol to the helper and protected
  request; request JSON and onboarding secrets never appear in argv or output.
- [ ] Add tests at 48 KiB, 60 KiB and 64 KiB boundaries, plus reordered,
  duplicated, shortened and corrupted chunks, QGA process timeout, PID change,
  output truncation, agent loss, and failure after a guest transaction starts.
  On transport loss, assert an incomplete transaction record and no healthy
  status. Run the QGA suite and Perl syntax check on a PVE 9 runner.

## Task 4: Implement pinned SSH transport and identity proof

**Files:** Create `transport-ssh.sh` and
`tests/komodo-periphery-vm-ssh.sh`; extend fixtures and `Makefile`.

**Interfaces:** `kp_ssh_inspect <vmid> <address> <port> <key-file>
<known-hosts-file>` streams the guest inspection script and returns validated
JSON. `kp_ssh_stage_apply` streams the same helper/binary/request protocol as
QGA and returns the shared guest outcome. Both use root key authentication and
the same fixed SSH options. The host verifies the PVE `smbios1` UUID against
`/sys/class/dmi/id/product_uuid` read inside the pinned SSH guest.

- [ ] Write a failing SSH fixture that records argv and stdin separately.
  Assert `BatchMode=yes`, `StrictHostKeyChecking=yes`, a dedicated
  `UserKnownHostsFile`, `ForwardAgent=no`, and exact address/port/key selection.
  A changed host key, wrong UUID, non-root session, or missing known-hosts
  entry must fail before stage or apply.
- [ ] Run `bash tests/komodo-periphery-vm-ssh.sh`; expect the missing adapter
  failure. Implement fixed SSH options and validate address, port and key/host
  file paths before use. Require an existing root-readable key and a pinned
  known-hosts entry; never run `ssh-keyscan` as implicit trust setup.
- [ ] Stream read-only inspection through `ssh -T ... root@ADDRESS
  '/bin/bash -s -- inspect'` with `guest.sh` on stdin. Validate one bounded
  response. Compare the guest DMI UUID (case-insensitively) with the UUID from
  PVE config. Store the verified SSH host-key fingerprint and guest machine ID
  for later checks; reject mismatch before mutation.
- [ ] Stream staged files over SSH stdin to the same guest receiver used by
  QGA. Transfer the small receiver into a root-owned guest `/run` directory
  after consent and verify its hash and mode. Keep the remote command fixed
  except for validated nonce and byte
  count. Revalidate PVE locality, UUID, host key and machine ID after locking
  and before each mutating phase. Do not infer an SSH address from DHCP or QGA.
- [ ] Test an SSH endpoint swapped between inspection and transfer, changed
  host key, changed guest UUID, interrupted binary stream, secret with shell
  metacharacters, and guest rollback failure. Assert no secret in argv, logs,
  state, JSON output, or diagnostics. Run the SSH and shared guest suites.

## Task 5: Expose VM flow, recovery and reporting

**Files:** Modify `host.sh`, `module.sh`, `pve-toolbox` only if the LXC plan's
explicit-update guard has not yet landed, `tests/komodo-periphery-vm.sh`, UI
fixtures, completions if their behavior changes, and `Makefile`.

**Interfaces:** `kp_host_change <install|update|uninstall>` asks guest kind,
exact target, and VM transport; `kp_host_status`, `kp_host_check`, and
`kp_host_doctor` read kind-qualified records. Transport changes require an
explicit re-pair preview and the same machine ID plus PVE/guest UUID; a failed
QGA call never silently falls back to SSH.

- [ ] Write failing terminal-driven tests for LXC and VM 201 sharing an ID
  namespace, QGA install, SSH install, adoption, explicit update, check-only,
  update-all, status, doctor, uninstall and cross-transport recovery. Include
  `-y`, `--force`, nonterminal input and declined consent; assert zero guest
  mutation for each bypass attempt.
- [ ] Implement VM selection and transport-specific prerequisites in the
  existing module flow. The preview names node, VMID, VM name, transport,
  identity evidence, service account, release, file paths and interruption.
  For SSH it also names address, port and host-key fingerprint. Require exact
  target-specific confirmation after release verification and before staging.
- [ ] Store operator-selected transport/address/key paths and desired version
  with `conf_set`; store observed non-secret identity and health with
  `state_set`. On guest commit followed by host record failure, retain pending
  intent and reconcile with the matching guest journal on the next explicit
  operation. Never label it healthy during the gap.
- [ ] Report VM and LXC statuses separately, including QGA/SSH reachability,
  Periphery active/enabled state, drift and incomplete transactions. Label Core
  connectivity unverified without positive Core evidence. Verify an inactive
  service is not called healthy merely because the transport is reachable.
- [ ] Run the host, TUI, completion, smoke and doctor suites. Check that
  sourcing the module and running package lifecycle scripts never call QGA,
  SSH or `pct`, and that update-all skips both VM and LXC Periphery agents.

## Task 6: Document and validate packaged VM behavior

**Files:** Modify `docs/modules/komodo-periphery.md`, `README.md`,
`docs/modules/index.md`, `mkdocs.yml`, `tests/package.sh`,
`tests/repository.sh`, and `Makefile`. Review `debian/changelog`; Release Please
continues to own version changes.

- [ ] Document the root-on-PVE commands from the LXC plan, VM prerequisites,
  QGA and SSH choices, dedicated known-hosts setup, required SMBIOS UUID for
  SSH, root-service authority, exact version selection, consent, recovery,
  retained keys/configuration, and Core verification limits. Use copy-safe
  examples and distinguish commands run on the host from those run in a VM.
- [ ] Extend package tests to assert all VM adapter and bridge files are
  installed under `/usr/lib/pve-toolbox`, and that package
  install/upgrade/remove never invokes a guest transport. Add dynamic Bash
  and Zsh completion coverage only for semantics that changed.
- [ ] Run `make lint`, then the complete disposable Debian 13 validation:

  ```bash
  TUI_TEST_REQUIRED=1 ZSH_TEST_REQUIRED=1 CB_GATE_TESTS_REQUIRED=1 \
  PACKAGING_TEST_REQUIRED=1 PACKAGING_INSTALL_TEST_REQUIRED=1 \
  REPOSITORY_TEST_REQUIRED=1 make test
  mkdocs build --strict
  git diff --check
  ```

- [ ] On a designated disposable PVE 9 node, test QGA and SSH against separate
  Debian 13 amd64 VMs. Record agent/Core versions, fresh install, supported
  adoption, update, induced failed start and rollback, controlled VM reboot,
  Core online status, and uninstall retention. Verify the host itself never
  gains a Periphery binary or service. Capture TUI screenshots and a short GIF
  for the changed flow. Report missing PVE hardware validation explicitly.
- [ ] Review `README.md`, the module guide, `debian/changelog`, the complete
  diff, `git status --short`, and required PR checks before handoff. Keep
  unrelated untracked planning files and secrets out of any future commit.

## Execution handoff

This plan uses the shipped LXC transaction foundation. Integrate Tasks 1-6 in
order. A VM transport is complete only when both
QGA and SSH pass their failure tests and the shared guest recovery contract.
