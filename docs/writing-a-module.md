# Writing a module

```bash
cp -r modules/_template modules/my-thing
$EDITOR modules/my-thing/module.sh
```

Set the metadata and implement the four required functions. `MODULE_NAME` must
match the directory name.

## Metadata

```bash
MODULE_NAME="my-thing"       # must equal the directory name
MODULE_TITLE="My thing"      # short name for the menu
MODULE_DESC="one line"       # shown by `pve-toolbox list`
MODULE_TAGS="storage notify" # space separated, filters `list <tag>`
MODULE_HOST_ONLY=1           # 1 if it must run on the host, not an LXC
```

The launcher reads these through indirect expansion in `meta()`, which is why
each module carries a `# shellcheck disable=SC2034` above the block.

## Functions

| Function | Contract |
| --- | --- |
| `module_install` | Interactive install or reconfigure |
| `module_update` | `[--check]` update in place; honours `$FORCE` |
| `module_status` | Print one short line; print exactly `not installed` and exit 1 when it is not |
| `module_status_long` | Detailed status. Optional, falls back to `module_status` |
| `module_doctor` | Emit additional read-only health results. Optional and called only when installed |
| `module_uninstall` | Remove what install created |

`module_status` is called for every module on every menu draw, on every
`ui` action, and by `uninstall` completion, so keep it cheap and make its first
word meaningful — the menu shows only that word in the `STATUS` column.

!!! warning "`not installed` is compared exactly"

    `update` and `check` given no module names, every list the `ui` builds,
    and `uninstall` completion all decide what to operate on by asking whether
    the status is the string `not installed`. Printing nothing and exiting
    non-zero means the same thing, and is the safe default if there is nothing
    useful to say.

    Anything else counts as installed, including a longer line that happens to
    contain the words — `1 of 3 pools not installed` reads as *installed*.
    Report a partial state through the wording of an installed status instead:

    ```bash
    module_status() {
        _my_scheduled
        [[ ${#MY_SCHEDULED[@]} -eq 0 ]] && { printf 'not installed'; return 1; }
        printf 'pools:%d' "${#MY_SCHEDULED[@]}"
    }
    ```

## Two rules

!!! danger "Keep the file side-effect free at source time"

    The launcher sources **every** module just to read its metadata for the
    menu. Definitions only at top level: no work, no prompts, no `mkdir`.
    Compute paths lazily inside a function instead:

    ```bash
    _my_dir() { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}" "$MODULE_NAME"; }
    ```

!!! danger "Persist through the helpers, not ad-hoc dotfiles"

    `state_set`/`state_get` and `conf_set`/`conf_get` are what `status` and
    `check` read back.

## State versus config

| | State | Config |
| --- | --- | --- |
| Path | `/var/lib/pve-toolbox/<module>.state` | `/etc/pve-toolbox/<module>.conf` |
| Mode | `0644` | `0600` |
| Holds | what the module knows | what the operator set |
| Format | `KEY=value` | `KEY='value'`, sourceable |
| API | `state_get` `state_set` `state_clear` `state_exists` | `conf_get` `conf_set` `conf_load` `conf_clear` `conf_exists` `conf_file` |

Anything secret — a token, a webhook URL, a password — belongs in config.

```bash
conf_set  "$MODULE_NAME" API_TOKEN "$token"          # 0600
state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"  # 0644
```

Config values are single-quoted with `'\''` escaping, so any value round-trips
and the file stays sourceable by a plain script:

```bash
source /etc/pve-toolbox/my-thing.conf
echo "$API_TOKEN"
```

## Module health checks

An installed module may contribute checks to `pve-toolbox doctor`:

```bash
module_doctor() {
    if systemctl is-active --quiet my-thing.timer; then
        doctor_result pass timer "timer is active"
    else
        doctor_result fail timer "timer is not active"
    fi
}
```

`module_doctor` must be read-only and emit only through `doctor_result`:

```text
doctor_result <pass|warn|fail|skipped|unsupported> <id> <summary> [detail]
```

The launcher runs the hook in the same isolated subshell as every other module
function. It validates the records and automatically prefixes IDs with
`module.<module-name>.`; the example above becomes `module.my-thing.timer`.
IDs contain lowercase letters, digits, dots, underscores, and hyphens. Summary
and detail values are single logical lines and must not contain secrets.

The shared reporting layer removes known credential shapes as a defensive
fallback before JSON rendering, but module functions must never deliberately
emit tokens, passwords, webhook URLs, private-key paths, or other secrets.

A hook that exits unsuccessfully, prints unrelated output, or produces no
results is reported as a module health failure. One broken module hook cannot
stop the remaining host and module checks.

## Long-running work

A module that installs a helper script should put it in the module directory
and install it into `TOOLBOX_BIN_DIR`, so the systemd unit does not depend on
the checkout staying where it is:

```bash
install -m 0755 "$(_my_dir)/my-runner.sh" "$TOOLBOX_BIN_DIR/my-runner"
install_toolbox_lib discord.sh
```

Point the unit at both:

```ini
[Service]
Type=oneshot
Environment=MY_CONF=/etc/pve-toolbox/my-thing.conf
Environment=PVE_TOOLBOX_LIB=/usr/local/lib/pve-toolbox
ExecStart=/usr/local/bin/my-runner %i
TimeoutStartSec=infinity
```

`systemd_oneshot` in `lib/common.sh` writes a service and timer pair for the
simple case, but it sets `TimeoutStartSec=900`. Work that can outlast that —
a scrub, a replication — needs its own unit file.

!!! warning "`systemctl start` on a long oneshot blocks"

    Use `systemctl start --no-block` from a module, or the launcher sits there
    for hours.

## Isolation

Modules run in a subshell, so their globals cannot leak into the launcher or
into each other. Prefix module-level variables and helpers anyway — `ZS_`,
`_zs_` for `zfs-scrub` — because `lib/common.sh` and the launcher share the
same shell.

## What you get for free

Everything in `lib/common.sh` is already sourced:

`info` `ok` `warn` `die` `step` `dim` · `ask` `ask_yn` `ask_secret` `confirm` ·
`require_root` `require_pve` `in_lxc` · `detect_arch` `pkg_ensure` `have_zfs`
`have_mdadm` · `gh_release` `install_release_binary` `rollback_binary`
`version_bare` `is_newer` · `state_*` `conf_*` · `systemd_oneshot` `systemd_remove`
`wait_for_idle` `run_unit` · `backup_file` `install_toolbox_lib` ·
`doctor_result` ·
[`discord_notify`](reference/discord.md)

See the [`lib/common.sh` reference](reference/common.md).

## Checks

```bash
make syntax
make lint
make test
```

`make lint` runs `shellcheck -x -S warning` over the launcher, `lib/*.sh`,
every `modules/*/*.sh`, the bash completion and `tests/*.sh`, so a helper
script you add is linted too. The zsh completion and `tests/tui.exp` are left
out — neither is bash.

`make test` runs `tests/smoke.sh`, which drives the launcher in place and
through a symlink against throwaway directories, then `tests/tui.sh`, which
drives `ui` through a pty. The ui test skips where `expect` or `whiptail` is
missing; `make test-tui` demands them instead. CI gets the same effect by
setting `TUI_TEST_REQUIRED=1` on `make test` in the Debian job, which is the
one that has them.
