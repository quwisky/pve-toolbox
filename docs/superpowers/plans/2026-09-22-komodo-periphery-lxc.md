# Komodo Periphery LXC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development or superpowers:executing-plans to
> implement this plan task-by-task after the user reviews the plan and selects
> an execution method. Steps use checkbox syntax for tracking.

**Goal:** Install and update Komodo Periphery systemd services in existing local
LXC containers, including adoption of supported existing installations.

**Architecture:** A host-only module selects and validates one guest and sends
a verified release to a guest transaction helper. Shared helpers provide exact
release verification and local-container validation. The launcher distinguishes
explicit module updates from update-all; the guest preserves ownership,
configuration, agent identity, service policy, and recoverable transaction state.

**Tech Stack:** Bash, Proxmox `pvesh`/`pct`, systemd, curl, jq, SHA-256, Debian
packaging, existing shell/Expect tests, and MkDocs.

**Spec:** [Approved design](../specs/2026-09-22-komodo-periphery-lxc-design.md).
Read it together with this plan and the repository's `AGENTS.md`.

## Global Constraints

- Existing containers only, Komodo Core v2, and Periphery only with systemd.
- Initial support: Debian 13 amd64 guests with Bash and systemd on local PVE 9.
- No Docker installation, container creation, privilege/nesting changes,
  firewall changes, guest package upgrades, or added package repositories.
- Guest mutation requires a target-specific preview and interactive confirmation.
- Global `--yes` or `--force` does not bypass confirmation or authorize adoption.
- Package installation and upgrade never enter containers.
- An unqualified toolbox-wide update must not update guest agents implicitly.
- Existing configuration, identity keys, service customizations, and workloads
  survive binary updates. Supported existing v2 installations can be adopted;
  v1-to-v2 migrations and downgrades are excluded.
- Discovery is side-effect free. Read-only checks never stage files in guests.
- Use configuration helpers for operator input and state helpers for derived,
  non-secret facts. Never put secrets in command arguments or public state.
- No commits, remote writes, or PR creation until separately requested for this
  feature. The prior PR requests concerned earlier fixes. Release Please owns
  release versions. No unrelated workflow edits.

## Review Focus

1. A reused CTID or migrated guest must not receive changes intended for the old
   guest; exercise identity and locality changes in Tasks 2 and 5.
2. A custom service with quoted paths, drop-ins, or environment substitutions
   must be preserved if unambiguous or rejected before mutation; Task 3.
3. A crash after replacing a binary but before writing host state must retain
   enough guest-local evidence to recover or finish recording safely; Tasks 4–5.
4. A disabled service that is running, or an enabled service that is stopped,
   must keep those two independent settings on update and rollback; Task 4.
5. Credentials containing quotes, backslashes, or terminal controls must not
   alter configuration syntax, become shell commands, or escape into reports;
   Tasks 4–5.

## Baseline and execution order

Research used `origin/master` at
`a094197a1f7432c69ef4a7e1232931ca479cdbf3`. The current checkout is on the older
`feat/release-please` branch. At execution time preserve these two uncommitted
documents, establish an isolated feature workspace from current `origin/master`,
and inspect any intervening changes before using this plan. Do not reset the
existing checkout or revive unrelated prunable worktrees.

Tasks 1 and 2 supply independent helpers; Task 3 supplies inspection and fixtures;
Task 4 consumes Task 3; Task 5 combines Tasks 1–4; Task 6 connects Task 5 to the
launcher; Tasks 7–8 finish documentation and validation. This is one feature,
with no separate Docker or container-provisioning subsystem.

```text
1 release verification ───────────┐
2 local target validation ────────┼── 5 host lifecycle ── 6 launcher/UI
3 guest inspection ── 4 recovery ┘                          │
                                          7 docs/package ── 8 validation
```

## File map and boundaries

| File | Responsibility |
| --- | --- |
| `lib/common.sh` | Exact-asset SHA-256 verification alongside existing checksum manifests |
| `lib/pve.sh` | Read-only local LXC inspection and target validation |
| `modules/komodo-periphery/module.sh` | Side-effect-free metadata and module lifecycle hooks |
| `modules/komodo-periphery/host.sh` | Selection, host locks, release staging, guest transport, host records |
| `modules/komodo-periphery/guest.sh` | Guest inspection and durable installation/update/uninstall transactions |
| `pve-toolbox` | Explicit update context, menu selection, and safe update-all |
| `modules/_template/module.sh` | Document the new optional update-context contract |
| `tests/komodo-periphery-release.sh` | Exact-release selection and checksum regression tests |
| `tests/komodo-periphery-target.sh` | Locality, guest eligibility, and identity tests |
| `tests/komodo-periphery-guest.sh` | Inspection, adoption, transaction and recovery tests |
| `tests/komodo-periphery.sh` | Module, transport, records, and launcher integration tests |
| `tests/komodo-periphery-ui.sh` | Driven plain/full-screen flows |
| `tests/fixtures/komodo-periphery/command.sh` | Controlled Proxmox, network, binary and systemd command doubles |
| `tests/fixtures/komodo-periphery/harness.sh` | Isolated roots, fixture creation, invocation and assertions |
| `tests/fixtures/komodo-periphery/drive.exp` | Terminal prompts, cancellation and confirmation driver |
| `Makefile` | Include new tests and nested fixture scripts in relevant checks |
| `tests/package.sh`, `tests/repository.sh` | Packaged runtime and no guest activity during lifecycle checks |
| `tests/smoke.sh`, `tests/completion-zsh.sh` | Discovery and completion contracts |
| `completions/pve-toolbox.bash`, `completions/_pve-toolbox` | Module/tag completion behavior; retain dynamic discovery |
| `README.md`, `docs/modules/index.md`, `mkdocs.yml` | Module listing and navigation |
| `docs/modules/komodo-periphery.md` | Operator prerequisites, flows, adoption, limitations and recovery |
| `docs/reference/common.md`, `docs/writing-a-module.md` | Shared helper and update-context contracts |

All new shell files use the repository's Bash/ShellCheck conventions. Do not
split or rewrite the existing LXC updater as part of this feature.

## Task 1: Verify an exact release asset without weakening existing checks

**Files:** Modify `lib/common.sh`; create `tests/komodo-periphery-release.sh`;
modify `Makefile` and `docs/reference/common.md`.

**Interfaces:**

- Consume `gh_release <repo> <tag>` and its `GH_JSON`, `GH_TAG` outputs.
- Add `gh_exact_asset <asset-name>`: return 0 and set `GH_ASSET_URL`,
  `GH_ASSET_SHA256` only for exactly one asset with an HTTPS URL and a digest
  matching `sha256:[0-9a-fA-F]{64}`. Clear outputs before every call; return 1
  on missing, duplicate or malformed assets.
- Add `verify_sha256 <file> <hex-digest>`: return 0 on an exact match, 1 otherwise.
  It never downloads or installs anything.
- Preserve the public interfaces and behavior of `gh_fetch_checksums`,
  `verify_checksum`, and `install_release_binary`; never turn a failed supplied
  manifest into successful fallback verification.

- [ ] Write a failing exact-selection test using a local metadata fixture:

  ```bash
  asset_digest=$(sha256sum "$WORK/asset" | awk '{print $1}')
  GH_JSON=$(jq -nc --arg digest "sha256:$asset_digest" '{assets:[{
    name:"periphery-x86_64", digest:$digest,
    browser_download_url:"https://github.com/moghtech/komodo/releases/download/v2.3.3/periphery-x86_64"
  }]}')
  gh_exact_asset periphery-x86_64 || fail 'exact asset rejected'
  verify_sha256 "$WORK/asset" "$GH_ASSET_SHA256" || fail 'digest rejected'
  GH_JSON=$(jq '.assets += .assets' <<<"$GH_JSON")
  if gh_exact_asset periphery-x86_64; then fail 'duplicate asset accepted'; fi
  [[ -z $GH_ASSET_URL && -z $GH_ASSET_SHA256 ]] || fail 'stale outputs retained'
  ```

- [ ] Run `bash tests/komodo-periphery-release.sh`; expect failure because the
  new functions do not exist, rather than a missing test dependency.
- [ ] Implement exact selection with `jq` and hash validation:

  ```bash
  jq -ce --arg name "$1" '
    [.assets[] | select(.name == $name)]
    | if length == 1 then .[0] else error("ambiguous asset") end
    | select(.digest | type == "string" and test("^sha256:[0-9A-Fa-f]{64}$"))
    | select(.browser_download_url | type == "string" and startswith("https://"))
  ' <<<"$GH_JSON"
  ```

  Capture this result before assigning outputs; validate a nonempty object and
  reject control characters in the URL. Hash only a validated regular file.
- [ ] Add assertions for absent digest, null/non-string digest, unsupported
  digest algorithm, malformed metadata, `periphery-aarch64` only, wrong hash,
  truncated file and an existing checksum-manifest mismatch. No network calls.
- [ ] Run `bash tests/komodo-periphery-release.sh` and `bash tests/lib.sh`;
  expect both to pass. Register the new test in `make test` and document that
  GitHub's digest verifies integrity without providing an independent signature.

## Task 2: Validate one exact local LXC target

**Files:** Modify `lib/pve.sh`; create `tests/komodo-periphery-target.sh`;
modify `Makefile`.

**Interfaces:**

- `pve_lxc_inventory <node>` sets `PVE_LXC_JSON` to a validated inventory array
  or clears it and sets `PVE_LXC_ERROR` on failure; return 0/1.
- `pve_lxc_ready <node> <ctid>` re-fetches configuration and current status,
  sets `PVE_LXC_CONFIG_JSON`, and returns 0 only for a running, unlocked,
  non-template Debian container on that node. Clear result on failure.
- The host module obtains `/etc/machine-id` through guest inspection (Task 3)
  and combines it with node, CTID and rootfs identity (Task 5). Do not treat
  hostname alone as identity or use a full configuration digest as stable identity.

- [ ] Write fixtures for `/nodes/pve1/lxc`, `/nodes/pve1/lxc/101/config`, and
  `/nodes/pve1/lxc/101/status/current`. Fail unexpected `pvesh` endpoints and any
  action other than `get`.
- [ ] Add the failing validation cases:

  ```bash
  pve_lxc_ready pve1 101 || fail 'running local Debian guest rejected'
  for bad_id in 0 99 101x '../101' '101;id'; do
      if pve_lxc_ready pve1 "$bad_id"; then fail 'unsafe CTID accepted'; fi
  done
  PVE_TEST_MODE=locked
  if pve_lxc_ready pve1 101; then fail 'locked guest accepted'; fi
  [[ -z $PVE_LXC_CONFIG_JSON ]] || fail 'old config survived failure'
  ```

- [ ] Run `bash tests/komodo-periphery-target.sh`; confirm the intended missing
  function failure, then implement the helpers using validated node names,
  decimal CTIDs `^[1-9][0-9]{2,8}$`, and exact local-node API paths.
- [ ] Reject duplicate inventory IDs, malformed JSON, unsupported OS, templates,
  failed API calls, stopped status, and disappearance between inventory and
  readiness check. Do not fall back to cluster-wide lookup.
- [ ] Run `bash tests/pve.sh` and `bash tests/komodo-periphery-target.sh`; expect
  all cases to pass. Keep `lxc-update` unchanged and register the new suite.

## Task 3: Inspect guest installations and establish a safe test harness

**Files:** Create `modules/komodo-periphery/guest.sh`,
`tests/komodo-periphery-guest.sh`, and the fixture `harness.sh`/`command.sh`;
modify `Makefile`.

**Interfaces:**

- `bash guest.sh inspect` performs read-only inspection and prints one JSON
  object. Use `jq` in the guest as an explicit prerequisite, alongside Bash,
  systemd, coreutils, `flock`, `dpkg-query`, and `timeout`; report missing tools
  without installing packages. No Docker prerequisite.
- Result schema: `schema=1`, `machine_id`, `os_id`, `os_version`, `arch`,
  `layout` (`absent|supported|unsupported`), `reason`, `version`, `binary`,
  `unit`, `config_paths` (array), `service_user`, `active`, `enabled`,
  `masked`, `fingerprint`, and `transaction` (`none|pending|committed`).
  No config contents, environment values, or private keys enter this JSON.
- `bash guest.sh inspect-request <request-file>` also validates requested
  paths and ownership for a staged action, without applying it (Task 4).
- Harness functions: `kp_fixture <scenario>` resets isolated guest and host
  roots plus the call log; `kp_guest <action> [request-file]` executes the real
  helper under the fixture root; `kp_assert_no_guest_mutation` rejects any
  mutating command/file change. `kp_fixture` defines `KP_TEST_ROOT`,
  `KP_TEST_LOG`, `KP_TEST_REQUEST`, `KP_TEST_CONFIG`, and `KP_TEST_BINARY`.

- [ ] Implement the harness with a temporary root, explicit command doubles,
  and cleanup. Run the real guest script in a disposable Debian 13 chroot with
  that temporary root when testing absolute paths; do not add a production
  environment variable that redirects privileged guest paths. A required run
  lacking root/chroot dependencies must fail rather than skip silently.
- [ ] Add fixtures named `absent`, `upstream-v2`, `custom-direct-v2`,
  `shell-injection`, `package-owned`, `docker`, `user-service`, and `v1`.
  Each contains a complete unit/config/binary stub and machine-id; service
  introspection doubles return its corresponding effective systemd properties.
- [ ] Write and run the inspection regression:

  ```bash
  kp_fixture upstream-v2
  inspected=$(kp_guest inspect)
  jq -e '.layout == "supported" and .version == "2.3.2"
      and .binary == "/usr/local/bin/periphery"' <<<"$inspected" >/dev/null
  kp_assert_no_guest_mutation
  kp_fixture shell-injection
  inspected=$(kp_guest inspect)
  jq -e '.layout == "unsupported"' <<<"$inspected" >/dev/null
  [[ ! -e $KP_TEST_ROOT/tmp/injected ]] || fail 'unit text executed'
  ```

  Run `bash tests/komodo-periphery-guest.sh`; confirm failure before adding the
  parser. Stubs must not silently return success for unknown commands.
- [ ] Parse `systemctl show` effective properties and unit/drop-in identities.
  Accept a single direct absolute Periphery executable with explicit config
  paths, plus the exact upstream `/bin/sh -lc` invocation form. Recognize
  supported quoting with a finite parser; never `eval`, source, or execute unit
  text. Reject substitutions, extra commands, unresolved specifiers, multiple
  executable entries, ambiguous `EnvironmentFile` overrides, and masked units.
- [ ] Validate every resolved path component and reject symlinks, non-regular
  files, unsafe writable parents, and `dpkg-query -S` ownership of the binary.
  Require Debian 13 amd64 and a valid machine-id before mutation eligibility.
  For a supported root-owned binary, invoke only its `--version`, with a short
  timeout and bounded output; unknown/v1/prerelease outputs are unsupported.
- [ ] Fingerprint binary content plus unit/drop-in content and effective
  service settings. Exclude mutable agent data and private-key contents so key
  rotation does not look like ownership drift. Preserve config files; report
  only validated paths. Editing a unit or binary invalidates adoption preview.
- [ ] Cover paths with spaces, quoted config paths, CR/LF/control injection,
  symlinked parents, readonly filesystems, missing prerequisites and existing
  private-key rotation. Run the guest suite and ShellCheck on the fixture code.

## Task 4: Implement durable guest transactions and rollback

**Files:** Extend `modules/komodo-periphery/guest.sh`,
`tests/komodo-periphery-guest.sh`, and fixture command/harness files.

**Interfaces:**

- `bash guest.sh apply <request-file>` takes protected JSON and returns 0 only
  on local success; 1 means an operational failure, 64 an invalid request, 130
  cancellation. Emit a bounded JSON outcome with `result`, `reason`,
  `version`, `fingerprint`, `rollback`, and `transaction_id`.
- Request schema: `schema=1`, `action` (`install|update|uninstall`),
  `transaction_id` (32 lowercase hex), `machine_id`, `expected_fingerprint`,
  `adopt` (boolean), `version`, `asset_sha256`, `staged_binary`, and for fresh
  installation only `core_url`, `server_name`, `onboarding_key`. Derive installed
  paths from inspection, never arbitrary request-provided replacement targets.
- `bash guest.sh recover <transaction-id>` resolves only the validated durable
  transaction matching the current machine-id. Recovery never accepts arbitrary
  restore paths from command arguments.
- Guest records live under root-owned mode-0700
  `/var/lib/pve-toolbox/komodo-periphery/`; locks remain stable inodes. Keep a
  protected ownership record, pending transaction, prior successful rollback
  copy, and separate original pre-adoption backup. Bound ordinary rollback
  storage to one previous successful version; never discard a pending recovery.

- [ ] Extend `kp_fixture` with `fresh-install-request`, `update-request`,
  `stopped-update-request`, `failed-start`, `failed-rollback`, and
  `uninstall-request`; populate complete request JSON and protected staged files.
  Add observable fault injection through command doubles at each transaction
  phase, not production environment bypasses.
- [ ] Write the failing lifecycle checks, then run the guest suite:

  ```bash
  kp_fixture update-request
  old_config=$(sha256sum "$KP_TEST_CONFIG")
  kp_guest apply "$KP_TEST_REQUEST" || fail 'update failed'
  [[ $(sha256sum "$KP_TEST_CONFIG") == "$old_config" ]] || fail 'config changed'
  kp_fixture failed-start
  old_binary=$(sha256sum "$KP_TEST_BINARY")
  if kp_guest apply "$KP_TEST_REQUEST"; then fail 'failed start reported success'; fi
  [[ $(sha256sum "$KP_TEST_BINARY") == "$old_binary" ]] || fail 'binary not restored'
  ```

- [ ] Validate the request, lock the guest, re-inspect machine-id/ownership,
  verify the staged checksum and requested version, and reject downgrades.
  Compare supported stable versions using the shared version semantics; do not
  rely on lexical comparison. A same-version adoption can record ownership
  after confirmation without replacing the binary or restarting the service.
- [ ] Implement a journaled sequence with explicitly checked return statuses:

  ```text
  inspected -> backed_up -> stopping -> replacing -> starting -> committed
       failure after backed_up -> restoring -> restored | recovery_failed
  ```

  Write each next-action marker atomically before that action; fsync backup and
  journal files/directories before destructive steps. Never rely on `set -e`
  alone inside functions invoked from conditionals. Capture enabled and active
  state independently; preserve ordinary enabled/disabled policies and reject
  unhandled linked/runtime/masked unit states before modification.
- [ ] Create fresh config with a safe TOML string encoder: reject input control
  bytes and encode backslash/quote characters without shell evaluation. Write
  `core_address`, `connect_as`, `onboarding_key`, `server_enabled = false`, and
  `root_directory = "/etc/komodo"`. Use mode 0600 config, mode 0700 key directory,
  mode 0755 binary and mode 0644 service. Set `UMask=0077` in the new unit.
  Refuse existing conflicting fresh-install paths instead of truncating them.
- [ ] Back up before replacement; stage the binary on the destination filesystem
  and rename it atomically. For fresh units use a direct ExecStart with the
  explicit config path, network-online ordering and `Restart=on-failure`.
  Existing units, drop-ins, config and keys remain byte-for-byte unchanged.
- [ ] For previously active services, poll active state, MainPID and executable
  identity for ten seconds; reject repeated restarts or a wrong executable.
  Restore previous enabled/active state on failure and verify the restore.
  A previously inactive service stays inactive and is reported as such; do not
  claim its startup or Core connectivity was tested.
- [ ] Test all four enabled/active combinations, changed fingerprint, same
  version, candidate version mismatch, SIGTERM, process death at every marked
  phase, and a restart loop. Verify journal recovery is idempotent and a
  committed guest result survives host bookkeeping failure.
- [ ] Implement ownership-checked uninstall. Remove only owned service/binary
  files, preserve config/keys/workloads/drop-ins and the adoption backup, and
  verify stop/disable/removal. Failed uninstall retains records for recovery.
  Reinstallation recognizes retained owned config/keys and asks before reuse;
  it never generates a replacement identity simply because the binary is absent.
- [ ] Run the guest suite; inspect fixture logs to ensure no Docker commands,
  package upgrades, or recursive deletion of agent data occurred.

## Task 5: Orchestrate host selection, transport, and records

**Files:** Create `modules/komodo-periphery/module.sh`,
`modules/komodo-periphery/host.sh`, `tests/komodo-periphery.sh`, and extend the
fixture harness/command files; modify `Makefile`.

**Interfaces:**

- `kp_host_change <install|update|uninstall>` implements the interactive flow.
- `kp_host_check`, `kp_host_status`, `kp_host_doctor` are read-only health paths.
- `kp_host_inspect <ctid>` sets `KP_INSPECTION_JSON` and `KP_TARGET_IDENTITY`;
  return 0/1. Identity hashes node, CTID, rootfs volume identity and machine-id.
- `kp_host_apply <ctid> <protected-request-file> <verified-binary-file>` stages
  and executes the helper after confirmation, returning the validated outcome
  in `KP_OUTCOME_JSON`; uninstall has no binary to transfer.
- Host operator config is `komodo-periphery-CTID`; derived per-guest state uses
  the same module key. `komodo-periphery` config stores the managed ID list.
  Pending host intent is root-readable config, never public state. Successful
  guest records allow reconstruction when host persistence fails.
- Harness adds `kp_launch <launcher-args...>` and terminal-driven
  `kp_confirm <fixture-answer-file> <launcher-args...>`; both run the real launcher
  with isolated toolbox directories and fixture PATH.

- [ ] Write a discovery test that sources metadata with `pct`, `pvesh`, curl
  and systemctl doubles configured to fail on any call. Declare only metadata
  and functions at source time; defer sourcing `host.sh` until a lifecycle hook.
- [ ] Write and run failing install/update tests under a driven terminal, plus
  assertions that `-y`, `--force`, nonterminal input and declined confirmation
  produce no guest mutation. Use the existing ask/secret/confirm helpers after
  rejecting those bypass modes explicitly.
- [ ] Implement local PVE 9/root eligibility, one-CTID prompts and inspection.
  Present standard, custom or unsupported installation details. Select an
  explicit stable `v2.X.Y`; validate the release repo, tag, asset name, URL host
  and digest through Task 1. Require operator confirmation of compatibility with
  their Core release; do not pretend a major-version match proves compatibility.
- [ ] Stage and verify the binary on the host before confirmation. Do not invoke
  `install_release_binary`, which targets the host's executable directory.
  After confirmation acquire the existing `lxc-update.lock` exclusively to
  avoid concurrent toolbox package maintenance, then a per-CTID host lock, then
  the guest lock. Use that fixed order and nonblocking failure with an actionable
  busy message. Recheck all target/ownership data under the locks.
- [ ] Create a random root-owned guest staging directory under `/run` using a
  narrowly validated nonce. Copy the helper, binary and mode-0600 JSON request
  with `pct push`, validating exact target locality before every transfer/action.
  Use `pct exec CTID -- bash ABSOLUTE_HELPER_PATH apply ABSOLUTE_REQUEST_PATH`;
  no secret values in argv. Host temp directory and files are mode 0700/0600.
  Record staging paths in the protected intent record for cleanup after a lost
  connection. Never blindly remove an old path after CTID reuse.
- [ ] For read-only inspection stream `guest.sh` to `pct exec CTID -- bash -s --
  inspect`; this creates no guest files. Capture bounded output, require exactly
  one schema-valid JSON result and sanitize it before display. Do not forward
  raw guest journal or raw request data to host logs; explicitly redact the
  current secret in addition to shared generic credential filtering.
- [ ] Persist desired settings with `conf_set`; persist non-secret outcomes with
  `state_set` only after guest commit. Validate all module-derived filenames,
  records and parent paths before calling the helpers. After a host-state write
  failure, report guest success plus host-record failure, retain intent, and
  reconcile using the matching committed guest journal on the next run.
- [ ] Implement cancellation and cleanup without killing an in-flight guest
  transaction indiscriminately. Signal/wait for controlled recovery where
  reachable; otherwise report incomplete with recovery instructions. Guest
  request/temp files are removed in traps; unreachable cleanup is recorded for
  the next identity-checked run. Never leave a failed rollback labeled healthy.
- [ ] Add test cases for two independent managed guests, cloned/reused machine-id
  plus changed rootfs, migration mid-transfer, secret quote/backslash/control
  input, failed `pct push`, unreachable cleanup, output truncation, redacted
  status/JSON, saved unit drift and identity-key rotation. Example assertions:

  ```bash
  kp_fixture moved-during-transfer
  if kp_confirm "$KP_TEST_ANSWERS" install komodo-periphery; then
      fail 'moved guest installation succeeded'
  fi
  ! grep -q 'apply' "$KP_TEST_LOG" || fail 'applied after target moved'
  ! grep -RFq -- "$KP_TEST_SECRET" "$TOOLBOX_STATE_DIR" || fail 'secret in state'
  ```

  Define `KP_TEST_ANSWERS` and `KP_TEST_SECRET` in these new harness scenarios;
  the literal test secret must never resemble a real credential.
- [ ] Run guest and host suites. Assert host `/usr/local/bin/periphery` and
  host `periphery.service` are never changed and discovery remains read-only.

## Task 6: Wire explicit lifecycle actions, menus, and completions

**Files:** Modify `pve-toolbox`, `modules/_template/module.sh`,
`tests/komodo-periphery.sh`, `tests/smoke.sh`, `tests/completion-zsh.sh`,
both completion files and `docs/writing-a-module.md`; create
`tests/komodo-periphery-ui.sh` and `tests/fixtures/komodo-periphery/drive.exp`.

**Interfaces:**

- Launcher initializes `TOOLBOX_UPDATE_EXPLICIT=0` regardless of an inherited
  environment value. `cmd_each` sets a local scoped value to 1 only when the
  caller supplied module arguments for `module_update` (before expanding the
  implicit installed list). The plain update-all path always supplies 0.
- Add optional metadata `MODULE_EXPLICIT_UPDATE=1` for this module. In the
  full-screen Update checklist, such modules default off even though ordinary
  modules default on. Explicitly selected entries receive context 1.
- Public check command is `pve-toolbox check komodo-periphery`, which already
  dispatches `module_update --check`. No new global `--check` flag is added.

- [ ] Add regression tests before implementing the dispatch changes:

  ```bash
  kp_fixture installed
  TOOLBOX_UPDATE_EXPLICIT=1 kp_launch update
  kp_assert_no_guest_mutation
  kp_launch check komodo-periphery
  kp_assert_no_guest_mutation
  kp_launch --json check komodo-periphery > "$KP_TEST_ROOT/check.json"
  jq -e . "$KP_TEST_ROOT/check.json" >/dev/null || fail 'invalid check JSON'
  ```

- [ ] Implement module hooks with this ordered update guard:

  ```bash
  module_update() {
      source "${TOOLBOX_ROOT}/modules/komodo-periphery/host.sh"
      if [[ ${1:-} == --check ]]; then kp_host_check; return; fi
      if [[ ${TOOLBOX_UPDATE_EXPLICIT:-0} != 1 ]]; then
          info 'Periphery updates require explicit selection: pve-toolbox update komodo-periphery'
          return 0
      fi
      kp_host_change update
  }
  ```

  Install and uninstall delegate to `kp_host_change`; short status consults
  local records only, prints exactly `not installed` and returns 1 when absent.
  Detailed status and doctor inspect selected managed guests read-only and
  preserve aggregate failure when one guest is degraded.
- [ ] Keep the plain menu's existing `u` update-all behavior safe and its
  install/reconfigure path capable of updating a detected existing agent.
  Full-screen install/reconfigure likewise supports adoption before the module
  has any managed records; no discovery-time guest scan is needed.
- [ ] Make check compare observed installed versions with saved desired versions
  and optionally report a newer stable v2 candidate as informational. No prompts
  or guest changes; absent desired configuration produces a clear not-configured
  report, not automatic latest selection. Preserve the reporter's existing
  `update available:` wording where an update is actually available.
- [ ] Return doctor results per CTID for service, version, ownership, incomplete
  transaction and Core verification. Label connectivity unverified unless there
  is positive evidence; do not equate `active` with authenticated enrollment.
- [ ] Add Expect flows for fresh installation, supported adoption/update,
  decline, cancellation, unreadable target, and update-all. Assert the full-screen
  checklist defaults Periphery off; selection still needs the guest-specific
  confirmation. Resolve menu rows through module discovery, not hardcoded indexes.
- [ ] Verify dynamic completion offers `komodo-periphery` and tags for install,
  update, check and status, and uninstall only after managed records exist.
  Keep Bash and Zsh behavior consistent and document the module/update contract
  in their discovery comments without adding static module name lists.
- [ ] Run `bash tests/komodo-periphery.sh`,
  `TUI_TEST_REQUIRED=1 bash tests/komodo-periphery-ui.sh`,
  `bash tests/smoke.sh`, `ZSH_TEST_REQUIRED=1 bash tests/completion-zsh.sh`, and
  `TUI_TEST_REQUIRED=1 bash tests/tui.sh`. Register every new test in `Makefile`.

## Task 7: Document operations and verify packaged behavior

**Files:** Create `docs/modules/komodo-periphery.md`; modify `README.md`,
`docs/modules/index.md`, `mkdocs.yml`, `tests/package.sh`, and relevant package
lifecycle fixtures in `tests/repository.sh`. Review `debian/changelog` without
manually bumping released versions or padding it with a planning entry.

- [ ] Write the operator guide with a root-on-PVE requirement and these supported
  commands (all interactive mutations select a guest inside the flow):

  ```bash
  pve-toolbox install komodo-periphery
  pve-toolbox update komodo-periphery
  pve-toolbox check komodo-periphery
  pve-toolbox status komodo-periphery
  pve-toolbox doctor
  pve-toolbox uninstall komodo-periphery
  ```

  Document guest prerequisites including `jq`; setup is Periphery-only and does
  not install packages. Explain Core v2 onboarding, pinned versions, no Docker
  requirement for installing the agent, and Docker as an independently managed
  requirement for Docker workloads. Link official upstream sources from the spec.
- [ ] Document standard/custom adoption support, explicit root-service authority,
  rejected layouts and v1 migration limits; update-all semantics; stopped-service
  preservation; rollout interruption; unverified Core connectivity; retained
  config/keys/data and drop-ins after uninstall; and transaction recovery.
  Recovery uses the next explicit module flow, which shows the pending operation
  before invoking the matching guest helper. Do not tell operators to delete locks,
  remove journals, or force another install over incomplete state.
- [ ] Add README/module-index rows and a navigation entry. Add tested command
  examples to docs; don't expose internal transport fields in the normal UI.
- [ ] Extend the packaged-runtime test to source metadata and perform simulated
  install/update inspection using the extracted `/usr/lib/pve-toolbox` modules.
  Assertions must prove helper files are included and no source-checkout path is
  referenced. Keep `debian/rules` unchanged if automatic module copying suffices.
- [ ] Add lifecycle command doubles that fail if package configure/upgrade/remove
  invokes `pct` or applies guest changes. Reuse disposable package-test roots;
  never configure the test package on the developer's actual host.
- [ ] Run `PACKAGING_TEST_REQUIRED=1 PACKAGING_INSTALL_TEST_REQUIRED=1 bash
  tests/package.sh`, `REPOSITORY_TEST_REQUIRED=1 bash tests/repository.sh`, and
  `mkdocs build --strict` in the supported Debian 13 runner.

## Task 8: Complete validation and review the full change

**Files:** All files changed above; no unrelated production files or CI workflow
changes. Retain terminal screenshots/GIF as review artifacts, not runtime assets.

- [ ] Run the focused suites once more only if changes since their last pass
  justify it, then run the complete required checks:

  ```bash
  make lint
  TUI_TEST_REQUIRED=1 \
  ZSH_TEST_REQUIRED=1 \
  CB_GATE_TESTS_REQUIRED=1 \
  PACKAGING_TEST_REQUIRED=1 \
  PACKAGING_INSTALL_TEST_REQUIRED=1 \
  REPOSITORY_TEST_REQUIRED=1 \
  make test
  mkdocs build --strict
  git diff --check
  ```

  Install declared runner dependencies in a disposable Debian 13 validation
  environment; a skipped required gate is a failure. Include nested fixture
  scripts in ShellCheck if the repository's current file glob misses them.
- [ ] On an explicitly designated disposable PVE 9 LXC, record guest OS/arch,
  privilege mode, Core version and exact before/after agent versions. Test fresh
  install, a separately prepared upstream systemd v2 installation's adoption,
  an older-to-newer v2 update, configured custom paths/drop-ins, and service
  persistence after a manually controlled container reboot. Never choose an
  arbitrary production CTID to obtain this evidence.
- [ ] Confirm Core shows the agent online, keep the same Core server identity
  through update and reboot, and compare pre/post configuration and private-key
  fingerprints locally without exporting the private key. Trigger a startup
  failure in the disposable guest, verify the old binary is restored, then test
  uninstall retention. Test a guest without Docker to separate agent startup
  from optional workload capabilities.
- [ ] Capture a short terminal flow and screenshots for install/adoption/update
  and failed-update recovery. Attach them if a PR is subsequently requested;
  otherwise retain local artifact paths in the handoff.
- [ ] Review the whole diff for target confusion, secret exposure, unmatched
  interfaces, ownership drift, incomplete rollback, changes outside the scope,
  and missing docs. If a PVE host/Core is unavailable, explicitly list the
  missing integration cases and do not claim full acceptance.
- [ ] Report actual commands and results, skipped checks, integration evidence,
  and remaining limitations. If the user later requests a PR, rebase on current
  master, make focused Conventional Commits, push without force, review the
  complete pushed diff, and verify required checks before handoff. Do not merge.

## Planning validation and execution handoff

This is an implementation plan, not completed code. No planned feature tests
have run. At planning time the current environment has no `mkdocs` command;
documentation build validation requires a prepared runner. No live PVE/Core
target has been supplied or verified for integration acceptance.

Recommended execution method: native implementation in this session, followed
by independent whole-branch review. The tasks share a transaction protocol and
ownership model, so keeping that context together is useful. The alternative
is task-by-task subagent implementation and review at greater context cost.
Wait for the user's plan review and execution-method selection before coding.
