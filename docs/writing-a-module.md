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
MODULE_CONFIG_PUBLIC="KEEP_DAYS JOB_*_SRC" # optional: config show may print these
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
| `module_config_files` | Optional. Print extra configuration names for `config show`, one per line. Read-only |

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

## Showing configuration

`pve-toolbox config show <module>` (root only) lists every key in
`/etc/pve-toolbox/<module>.conf`. It prints a value only for keys the module
declares in `MODULE_CONFIG_PUBLIC`: space-separated names, or shell glob
patterns such as `JOB_*_SRC`. Every other key shows only `(set, hidden)` or
`(not set)`, and `--json` leaves out its `value` field.

!!! danger "Keys are hidden by default: list only what can never hold a secret"

    A key matched by `MODULE_CONFIG_PUBLIC` is printed to the terminal and into
    JSON that may be pasted into a ticket. List numbers, schedules, dataset
    names and plain directories. Never list a token, a webhook URL, a
    password, a remote URL that can embed credentials, or the path of a key or
    token file. A pattern matches every key it can: `JOB_*` would also match
    `JOB_A_OPTS`. When in doubt, leave the key out; a module without
    `MODULE_CONFIG_PUBLIC` shows every key hidden.

    Public values are shown as the shell expands them when it reads the
    file. A hand-edited public line that refers to a hidden key, such as
    `E_DIR="/srv/$E_TOKEN"`, displays that secret. A public key must hold a
    literal, non-secret value.

A module that keeps more than one configuration file names the others in
`module_config_files`, one name per line, each matching `^[a-z0-9][a-z0-9-]*$`
and read from `/etc/pve-toolbox/<name>.conf`. It runs as root before those
files are shown, so keep it read-only: read with `conf_get`, validate what you
read, print names only, and return 0, because a non-zero exit makes `config show`
fail.

```bash
module_config_files() {
    local id
    for id in $(conf_get "$MODULE_NAME" MY_IDS); do
        if [[ $id =~ ^[0-9]+$ ]]; then printf '%s-%s\n' "$MODULE_NAME" "$id"; fi
    done
}
```

`config show` refuses the directory or any file that is a symbolic link, is
not owned by root, or is writable by group or others, and prints nothing from
any file when it does. Files written with `conf_set` already meet that.

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

`info` `ok` `warn` `die` `step` `dim` ·
`ask` `ask_valid` `ask_int` `ask_choice` `ask_schedule` `ask_yn` `ask_secret`
`confirm` ·
`require_root` `require_pve` `in_lxc` · `detect_arch` `pkg_ensure` `have_zfs`
`have_mdadm` · `gh_release` `install_release_binary` `rollback_binary`
`version_bare` `is_newer` · `state_*` `conf_*` · `systemd_oneshot` `systemd_remove`
`wait_for_idle` `run_unit` · `backup_file` `install_toolbox_lib` ·
`doctor_result` ·
[`discord_notify`](reference/discord.md)

Ask every question before the first write. See
[Prompts](reference/common.md#prompts).

A module keeps writing its own output with `info`/`ok`/`warn`/`step`/`dim`
(stdout, `c_*`) and reporting its own errors with `die` (stderr, `e_*`);
`toolbox_color_setup` already decided both before the module ran, so nothing
about writing a module changes here. See [Output](reference/common.md#output).

See the [`lib/common.sh` reference](reference/common.md).

## Migrating package configuration

When a release changes an existing on-disk format, add a numbered Bash fragment
under `migrations/`; do not put upgrade-only rewrites in a module's install
path. See [`migrations/README.md`](https://github.com/quwisky/pve-toolbox/blob/master/migrations/README.md)
for the fragment contract, backup behavior, retry guarantees, and test fixture.
Release Please owns package versions, so migrations use stable filename IDs
instead of editing `VERSION` or `debian/changelog` versions themselves.

## Checks

```bash
make syntax
make lint
make test
```

`make lint` runs `shellcheck -x -S warning` over the launcher, `lib/*.sh`,
every `modules/*/*.sh`, the bash completion and `tests/*.sh`, so a helper
script you add is linted too. It also runs `actionlint` over the GitHub Actions
workflows. The zsh completion and `tests/tui.exp` are left out — neither is
Bash.

`make test` runs `tests/smoke.sh`, which drives the launcher in place and
through a symlink against throwaway directories, then `tests/tui.sh`, which
drives `ui` through a pty. The ui test skips where `expect` or `whiptail` is
missing; `make test-tui` demands them instead. CI sets every required-test flag
in its Debian 13 job. That job builds one `.deb` and supplies its path and
SHA-256 digest to both the package and repository tests, including a real APT
update, selection, download, and install.
Those root-only lifecycle and APT consumer checks run only when their required
gate variables are set. Run them on a clean disposable Debian 13 environment;
they refuse existing toolbox package, binary, configuration, or state paths.

## Explicit guest updates

A module that modifies a guest can declare `MODULE_EXPLICIT_UPDATE=1` to default
to unchecked in the full-screen Update selection. Its update hook must check
`TOOLBOX_UPDATE_EXPLICIT=1` before mutations. The launcher sets this scoped value
for named CLI updates and confirmed full-screen selections; an inherited
environment value cannot authorize update-all. The plain update-all action does
not supply it. `module_update --check` remains read-only regardless of selection.
A module must still obtain its own target-specific confirmation before changing
a guest. Periphery uses the existing `check` command, not a new `--check` CLI flag.
