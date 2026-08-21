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
| `module_status` | Print one short line; exit 1 when not installed |
| `module_status_long` | Detailed status. Optional, falls back to `module_status` |
| `module_uninstall` | Remove what install created |

`module_status` is called for every module on every menu draw, so keep it
cheap and make its first word meaningful — the menu shows only that word in
the `STATUS` column.

## Two rules

!!! danger "Keep the file side-effect free at source time"

    The launcher sources **every** module just to read its metadata for the
    menu. Definitions only at top level: no work, no prompts, no `mkdir`.
    Compute paths lazily inside a function instead:

    ```bash
    _my_dir() { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/opt/pve-toolbox}" "$MODULE_NAME"; }
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
`is_newer` · `state_*` `conf_*` · `systemd_oneshot` `systemd_remove`
`wait_for_idle` `run_unit` · `backup_file` `install_toolbox_lib` ·
[`discord_notify`](reference/discord.md)

See the [`lib/common.sh` reference](reference/common.md).

## Checks

```bash
make syntax
make lint
make test
```

`make lint` runs `shellcheck -x -S warning` over the launcher, `lib/*.sh` and
every `modules/*/*.sh`, so a helper script is linted too.
