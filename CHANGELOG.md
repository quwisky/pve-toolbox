# Changelog

## [0.6.0](https://github.com/quwisky/pve-toolbox/compare/v0.5.1...v0.6.0) (2026-09-04)


### Features

* **lxc-update:** schedule automatic container updates ([#49](https://github.com/quwisky/pve-toolbox/issues/49)) ([45613e7](https://github.com/quwisky/pve-toolbox/commit/45613e77a845b7f20cf7e7a5d331ff711f34d0de))

## [0.5.1](https://github.com/quwisky/pve-toolbox/compare/v0.5.0...v0.5.1) (2026-09-03)


### Bug Fixes

* **release:** deploy Pages only after publication ([#43](https://github.com/quwisky/pve-toolbox/issues/43)) ([37c2f4d](https://github.com/quwisky/pve-toolbox/commit/37c2f4dabb05c31cf2aed490818fd7051b0f93ec))
* **release:** verify signed APT repository metadata ([#46](https://github.com/quwisky/pve-toolbox/issues/46)) ([1d9bf60](https://github.com/quwisky/pve-toolbox/commit/1d9bf608bb7174e4b1f32e63ecc7f6f7d8359bb9))

## [0.5.0](https://github.com/quwisky/pve-toolbox/compare/v0.4.2...v0.5.0) (2026-09-03)


### Features

* **lxc-update:** add guarded container package updates ([#40](https://github.com/quwisky/pve-toolbox/issues/40)) ([38da29b](https://github.com/quwisky/pve-toolbox/commit/38da29b580aa53c2e944456eb1eaaf988e46046d))


### Bug Fixes

* **release:** restore Release Please version ownership ([#42](https://github.com/quwisky/pve-toolbox/issues/42)) ([7503d56](https://github.com/quwisky/pve-toolbox/commit/7503d56be5437be8c54c3a4aaaa5f385a4655aad))

## [0.4.2](https://github.com/quwisky/pve-toolbox/compare/v0.4.1...v0.4.2) (2026-08-30)


### Bug Fixes

* **release:** automate verified publishing ([#38](https://github.com/quwisky/pve-toolbox/issues/38)) ([50e9472](https://github.com/quwisky/pve-toolbox/commit/50e9472a35466af20a50818c9f773bf9f4a5c1cb))


### Documentation

* **agents:** configure engineering skills ([#36](https://github.com/quwisky/pve-toolbox/issues/36)) ([628826e](https://github.com/quwisky/pve-toolbox/commit/628826ef1fc1f629379a69e32ecf0f191923cbfe))

## [0.4.1](https://github.com/quwisky/pve-toolbox/compare/v0.4.0...v0.4.1) (2026-08-29)

- Query filtered task history through supported per-node PVE 9 endpoints.
- Reject partial or malformed task history in doctor and task-aware modules.

## [0.4.0](https://github.com/quwisky/pve-toolbox/compare/v0.3.0...v0.4.0) (2026-08-28)

- Add guarded, isolated VM and container backup restore drills.
- Default to a plan, require explicit mutation consent, retain recoverable state,
  and delete only ownership-marked temporary guests.
- Add a read-only, policy-driven PVE 9 upgrade readiness preflight.
- Report repository, package, reboot, space, cluster, storage, service, and
  recent-backup blockers with remediation context.
- Add read-only cluster certificate expiry, hostname, and chain checks.
- Report node reachability and failed or stale native ACME tasks.
- Add read-only storage hygiene checks for snapshots, content, definitions,
  ZFS objects, capacity, inodes, and LVM thin pools.
- Distinguish orphan candidates from volumes with ambiguous ownership.
- Add idempotent native PVE webhook, Discord, Gotify, and SMTP targets.
- Provision owned matchers with delivery tests, protected credentials, and
  rollback on failure.
- Add a shared helper for custom events through Proxmox notification matchers.
- Add read-only guest backup coverage and freshness auditing.
- Report weak retention, excluded volumes, failed jobs, and backup storage
  health through doctor and JSON output.

## [0.3.0](https://github.com/quwisky/pve-toolbox/compare/v0.2.1...v0.3.0) (2026-08-29)

- Add versioned JSON and quiet output for status, check, and doctor.
- Standardize automation exit codes and redact sensitive result text.

## [0.2.1](https://github.com/quwisky/pve-toolbox/compare/v0.2.0...v0.2.1) (2026-08-29)

- Query supported per-node task history endpoints on PVE 9.
- Treat explicitly disabled storage as informational in capacity checks.
- Install fio when the Scrutiny performance collector is selected.

## [0.2.0](https://github.com/quwisky/pve-toolbox/compare/v0.1.1...v0.2.0) (2026-08-28)

- Add a read-only doctor command for host, cluster, storage, and module health
  checks.
- Let installed modules contribute isolated, validated health results.

## [0.1.1](https://github.com/quwisky/pve-toolbox/compare/v0.1.0...v0.1.1) (2026-08-28)

- Propagate module failures to command-line callers.
- Require exact checksums for downloaded collector executables.
- Make collector installation and release publication transactional.
- Pin the APT repository key fingerprint during bootstrap.
- Enforce the complete validation matrix before publishing a release.

## [0.1.0](https://github.com/quwisky/pve-toolbox/releases/tag/v0.1.0) (2026-08-28)

- Initial native Debian package for PVE 9 / Debian 13.
- Add a guarded manual release path from master with generated notes.
- Publish the committed APT signing certificate in armored and binary formats.
- Document manual signing key and APT repository setup.
