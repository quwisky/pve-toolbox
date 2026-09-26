# lib/common.sh

Sourced by the launcher and by every module. Defines no side effects beyond
variables and functions, so it is safe to source when only module metadata is
wanted.

## Paths

Every path is overridable, which is what makes modules testable off a real
host:

| Variable | Default |
| --- | --- |
| `TOOLBOX_BIN_DIR` | `/usr/local/bin` |
| `TOOLBOX_LIB_DIR` | `/usr/local/lib/pve-toolbox` |
| `TOOLBOX_CONF_DIR` | `/etc/pve-toolbox` |
| `TOOLBOX_STATE_DIR` | `/var/lib/pve-toolbox` |
| `TOOLBOX_SYSTEMD_DIR` | `/etc/systemd/system` |
| `TOOLBOX_BASH_COMPLETION_DIR` | `/usr/share/bash-completion/completions` |
| `TOOLBOX_ZSH_COMPLETION_DIR` | `/usr/share/zsh/vendor-completions` |

`TOOLBOX_ROOT` points at the checkout for git installs and at
`/usr/lib/pve-toolbox` for Debian packages. Module files should use it when
locating files shipped beside `module.sh`; their fallback is the packaged
path. The launcher-only `PVE_TOOLBOX_ROOT` override exists for staging and
package tests.

## Output

`info` `ok` `warn` `die` `step` `dim`
: Coloured when stdout is a tty, plain otherwise. `die` writes to stderr and
  exits 1.

## Prompts

Every prompt follows the same rules:

- A value already in `<var>` (an environment preset, or a key loaded with
  `conf_load`) becomes the default. This is how `-y` installs are driven.
- With `ASSUME_YES=1` nothing is read. The default is validated, and an
  invalid one ends the module with `invalid value for <VAR>: <reason>`. A
  variable an operator cannot preset (anything not in upper case, such as a
  local) is not named; the error quotes the prompt instead:
  `invalid value for "<prompt>": <reason>`.
- Interactively, a rejected answer prints its reason and the prompt repeats.
- A read that fails, because stdin is closed or piped answers ran out, ends
  the module with `no answer for "<prompt>" (input closed)`. It never falls
  back to the default. Without a terminal the error adds
  `run it in a terminal, or use -y and set <VAR>`; after Ctrl-D at a terminal
  it adds only `use -y and set <VAR>`. Either hint names `<VAR>` only when it
  is upper case.

`ask <var> <prompt> <default>`
: Free text.

`ask_valid <var> <prompt> <default> <fn>`
: Free text checked by a validator: `fn <value>` returns 0 to accept,
  optionally setting `ASK_NORMALIZED` to the form to store, or sets
  `ASK_REASON` and returns 1. `valid_required` rejects a blank value with
  reason `a value is required`, for any prompt that must not be left empty.
  `valid_printable` accepts a blank value and any valid UTF-8 text without
  control characters. It rejects bytes that are not valid UTF-8 (reason
  `use valid UTF-8 text`) and every control character, meaning C0 (including
  tab), DEL and C1 (U+0080 to U+009F), with reason
  `use printable characters only (no tabs or other control characters)`. It
  checks in a UTF-8 locale local to the call, so the caller's `LC_ALL` is
  unchanged. Code points above U+10FFFF, surrogates, overlong forms and the
  old 5- and 6-byte forms count as invalid UTF-8. If the `C.UTF-8` locale is
  missing, C1 characters cannot be detected, so it refuses every non-blank
  value with reason `cannot check characters: the C.UTF-8 locale is unavailable`.
  Its reasons never repeat the value, so it can check secrets.

`ask_int <var> <prompt> <default> [min] [max]`
: A whole number without leading zeros, inside the bounds.

`ask_choice <var> <prompt> <default> <choice>...`
: One of the choices, matched case-insensitively and stored as spelled in the
  call. The prompt lists them.

`ask_schedule <var> <prompt> <default>`
: A systemd `OnCalendar` expression that `systemd-analyze calendar` accepts
  and that elapses in the future. `valid_schedule` is the same check as a
  validator.

`ask_yn <var> <prompt> <y|n>`
: Stores `y` or `n`. Presets of `1`, `0`, `true` and `false` are accepted.

`ask_secret <var> <prompt> [fn]`
: Never echoed and never shown. When `<var>` already holds a value, Enter
  keeps it and `none` clears it. A validator that rejects an empty value makes
  the secret required. `valid_webhook_url` (from `lib/discord.sh`) is the
  validator for Discord webhooks. A validator's reason must never include the
  value. After storing the value, `ask_secret` clears `ASK_LINE`, `ASK_VALUE`
  and `ASK_NORMALIZED`, so no copy of the secret is left in them.

`confirm <prompt> [y|n]`
: Exit status, for use in `if`. Closed input is an error, not the default.

!!! warning "Ask before you write"

    Prompt failures end the module through `die`. Ask every question before
    the first `conf_set`, `state_set` or file write, so a failed or
    interrupted prompt leaves nothing half-configured.

## Preflight

`require_root`
: Exits unless `EUID` is 0.

`require_pve`
: Reports the PVE version, warns and asks to continue if `pveversion` is
  missing or if it detects an LXC.

`in_lxc` · `have_zfs` · `have_mdadm`
: Exit status only.

`detect_arch`
: Prints `amd64`, `arm64` or `arm-7`; dies on anything else.

`pkg_ensure <command:package>...`
: Installs only the packages whose command is missing.

## State and config

See [State versus config](../writing-a-module.md#state-versus-config).

`state_get` `state_set` `state_clear` `state_exists`
: `0644`, `KEY=value`.

`conf_file` `conf_get` `conf_set` `conf_load` `conf_clear` `conf_exists`
: `0600`, `KEY='value'`, sourceable. `conf_load` sources every key into the
  caller.

## GitHub releases

`gh_release <repo> <tag|latest>`
: Sets `GH_JSON` and `GH_TAG`.

`gh_fetch_checksums`
: Sets `CHECKSUM_FILE`. Fails when the release has no checksum file or it cannot
  be downloaded intact.

`install_release_binary <asset-fragment> <arch-fragment> <target>`
: Downloads, requires an exact checksum entry, keeps the old build as
  `<target>.prev`, and refuses unverified assets. Returns 1 when no asset
  matches.

`rollback_binary <target>`
: Restores `<target>.prev`.

`version_bare <version>`
: Strips a leading `v` or `V`. A release tag carries one and `--version` output
  usually does not, so the same release arrives spelled two ways.

`is_newer <candidate> <current>`
: Version sort with both sides stripped, so a downgrade can be caught and
  confirmed. An exact tie is not newer. An empty or `unknown` *current* means
  anything is an upgrade; an empty or `unknown` *candidate* is never one.

    !!! note "Prereleases"

        `sort -V` on its own puts `1.70.0-rc1` *above* `1.70.0`, which would
        make a stable release read as a downgrade from its own candidate. It
        does sort `~` below everything, so `is_newer` maps `-` across before
        comparing and a prerelease sorts under the release it belongs to.

## systemd

`systemd_oneshot <unit> <description> <exec> <OnCalendar>`
: Writes a niced oneshot service plus timer and enables it.

    !!! warning
        Sets `TimeoutStartSec=900`. Work that can run longer — a scrub, a
        replication — needs its own unit file.

`systemd_remove <unit>` · `wait_for_idle <unit> [timeout]` · `run_unit <unit>`
: `run_unit` dumps the last 20 journal lines on failure. It blocks, so do not
  use it for long-running units — `systemctl start --no-block` instead.

## Misc

`backup_file <path>`
: Copies to `<path>.bak.<timestamp>` before you overwrite it.

`install_toolbox_lib <name>...`
: Copies `lib/<name>` into `TOOLBOX_LIB_DIR` at `0644`, so an installed helper
  script can source it.

### Exact release assets

`gh_exact_asset NAME` selects exactly one asset in `GH_JSON` and returns its
HTTPS URL and GitHub SHA-256 digest in `GH_ASSET_URL` and `GH_ASSET_SHA256`.
Missing or ambiguous metadata fails with empty outputs. `verify_sha256 FILE
DIGEST` verifies a regular file against a 64-digit hexadecimal digest. These
helpers do not install a binary. GitHub metadata provides integrity checking,
not an independent signature. Existing checksum-manifest verification remains
mandatory for callers using that interface.
