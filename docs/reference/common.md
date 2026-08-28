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

`ask <var> <prompt> <default>`
: Reads into `<var>`. If `<var>` is already set its value becomes the default,
  which is how env vars override prompts.

`ask_yn <var> <prompt> <y|n>`
: Loops until it gets a yes or no.

`ask_secret <var> <prompt>`
: No echo. Skipped entirely if `<var>` is already set.

`confirm <prompt> [y|n]`
: Exit status, for use in `if`.

!!! note "`-y` mode"

    With `ASSUME_YES=1` every prompt returns its default without reading. A
    module that requires a value must check for it and `die` rather than
    looping forever on an empty default.

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
: Sets `CHECKSUM_FILE`, empty when the release ships none.

`install_release_binary <asset-fragment> <arch-fragment> <target>`
: Downloads, verifies the checksum when there is one, keeps the old build as
  `<target>.prev`. Returns 1 when no asset matches.

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
