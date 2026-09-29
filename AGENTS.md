# Repository guidance

These instructions apply to the entire repository.

## Project shape

- This is a Bash-first Proxmox VE host toolkit. Keep runtime code compatible
  with the Bash version shipped by Debian 13 / PVE 9.
- `pve-toolbox` is the launcher. Shared behavior belongs in `lib/`; individual
  features belong in self-contained directories under `modules/`.
- `modules/_template/` is the reference module contract. A module must remain
  side-effect free when sourced because discovery loads every module just to
  inspect its metadata.
- The Debian package installs immutable application code under `/usr` and keeps
  operator configuration in `/etc/pve-toolbox` and state in
  `/var/lib/pve-toolbox`.

## Implementation rules

- Use the helpers in `lib/common.sh`, `lib/discord.sh`, and `lib/tui.sh` instead
  of duplicating configuration, state, notification, or terminal behavior.
- Store secrets and operator input with the config helpers. Store derived,
  non-secret facts with the state helpers. Preserve their existing permissions.
- Keep install, update, status, and uninstall behavior idempotent. Partial
  failures must be visible and must not silently leave a service reported as
  healthy.
- Treat filesystem replacement, restore, deletion, systemd changes, package
  publishing, and remote Git operations as high-risk paths. Validate exact
  targets and fail closed before mutating them.
- Do not weaken dry-run, rollback, locking, credential filtering, or
  no-force-push guarantees to make a test pass.
- Keep shell scripts readable by ShellCheck at warning severity. Quote
  expansions unless intentional splitting or pattern matching is documented.
- Update Bash and Zsh completions when commands, flags, modules, or completion
  semantics change.

## Packaging and releases

- `.release-please-manifest.json`, `VERSION`, and the version in
  `debian/changelog` must match before a release. Release Please owns version
  changes; its workflow synchronizes the Debian changelog on the release PR.
- The APT repository supports Debian 13 (`trixie`) / PVE 9 on `amd64`. Do not
  broaden that claim without adding and running matching validation.
- Never commit a private signing key, signing subkey, passphrase, token, or
  revocation certificate. The only committed signing material is the public
  certificate at `keys/pve-toolbox.asc`.
- The `APT_SIGNING_KEY` secret in the `release` environment must match the
  committed public certificate. Keep repository trust scoped through
  `Signed-By`; do not add instructions using the deprecated system-wide
  `apt-key` trust model.
- `RELEASE_PLEASE_TOKEN` is a repository secret with narrowly scoped repository
  access so release pull-request updates trigger required workflows.
- Preserve the guarded manual-release behavior: manual requests run only from
  `master`, require a newer stable version, and an existing version tag or
  release must cause a clear failure.
- Keep GitHub Releases draft until the exact tested package is attested, the
  signed APT repository and Pages are published, and release assets verify.
- Changes to package contents, lifecycle scripts, repository metadata, signing,
  or release automation require the package and repository tests, not only the
  lightweight local suite.

## Documentation and changelog

- Update user documentation whenever commands, configuration, supported hosts,
  installation, migration, module behavior, or operational risks change.
- Check `README.md` and the relevant page under `docs/` before validation and
  update each one that is affected.
- Do not hand-edit `CHANGELOG.md` or `debian/changelog`. Release Please
  generates them from Conventional Commit pull-request titles, so the title is
  the changelog entry.
- Documentation commands must be safe to copy, must identify when root is
  required, and must use the same paths and URLs as the implementation.
- Keep design specs and implementation plans out of the repository and the
  published site; put them in the GitHub issue or an untracked location.

## Validation

Run the narrowest relevant test while iterating, then run the complete applicable
set before handing off a change:

```bash
make lint
make test
mkdocs build --strict   # warnings are failures
```

The complete Debian 13 validation runs as root (CI uses a `debian:13`
container) with the runner dependencies from `.github/workflows/ci.yml`
installed, plus `actionlint` and `pip install -r docs/requirements.txt`.
Without `jq`, `shellcheck`, `expect`, `zsh`, `whiptail` or `sshd`, many suites
skip or stop early:

```bash
QGA_TEST_REQUIRED=1 \
TUI_TEST_REQUIRED=1 \
ZSH_TEST_REQUIRED=1 \
CB_GATE_TESTS_REQUIRED=1 \
PACKAGING_TEST_REQUIRED=1 \
PACKAGING_INSTALL_TEST_REQUIRED=1 \
REPOSITORY_TEST_REQUIRED=1 \
CLI_ROOT_TEST_REQUIRED=1 \
make test
```

- A skipped required gate is a validation failure, not a pass.
- For TUI changes, run the driven terminal tests and attach screenshots and a
  short GIF demonstrating the changed flow to the pull request.
- Report exactly what ran, including skipped checks and missing dependencies.
  Never describe a change as tested when only syntax or a partial suite ran.

## Completion and review

- Complete issue work in this order: documentation review,
  validation, push, then a final review of the complete diff.
- Keep each pull request focused on one concern. Its title and description must
  describe the actual diff, actual tests, secrets or infrastructure touched,
  known gaps, and migration steps.
- Before handoff, run `git diff --check`, confirm the working tree contains no
  unrelated files or secrets, and verify required pull-request checks pass.

## Agent skills

### Issue tracker

Issues and specifications are tracked in GitHub Issues for
`quwisky/pve-toolbox`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default five-role triage vocabulary. See
`docs/agents/triage-labels.md`.

### Domain docs

This repository uses a single-context domain-documentation layout. See
`docs/agents/domain.md`.
