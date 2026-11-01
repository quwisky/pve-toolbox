# OpenBao secrets for Komodo stacks

Install, update, check and remove **`bao-run`**, a small compose wrapper that
fetches a stack's secrets from OpenBao at deploy time, in selected local LXCs.
Run the toolbox as **root on the PVE 9 host**. The supported guest is a
**Debian 13 amd64 LXC**. VMs are not supported.

The module puts the wrapper and its AppRole credentials into the container, and
records what it did on the host. It does not create or configure OpenBao (a
workstation script does that, see [Workflow](#workflow)), does not install
Komodo Periphery (see [komodo-periphery](komodo-periphery.md)), does not edit
Komodo stacks, and does not install packages in the container.

## What the container needs

The wrapper needs `bash`, `curl` and `jq` in the container. They are reported,
never installed. If any is missing, install fails with the exact command to run
**inside the container** (as root), for example:

```bash
apt install curl jq
```

The host needs the usual Proxmox tools plus `jq`, `flock`, `sha256sum` and
`openssl`, and must be a PVE 9 node (not a container). The container must be
running and local to this node.

## How the wrapper works

Komodo runs the stack's compose command through `compose_cmd_wrapper`. The
wrapper, `/usr/local/bin/bao-run`:

1. Logs in to OpenBao with an AppRole. Role ID and secret ID are sent on stdin
   and the token in a header read from stdin, so neither appears in a process
   list.
2. Reads each KV v2 path you give it, in order, from the `kv` mount (or the
   mount named in `/etc/bao-run/mount`).
3. Revokes its token, exports every key as an environment variable, and `exec`s
   the compose command.

```text
bao-run [-r <role>] <kv-path> [<kv-path> ...] -- <command ...>
bao-run --check [-r <role>]
```

`--check` logs in, revokes the token and prints one word (see
[Status and doctor](#status-and-doctor)).

### KV layout and conventions

| Path under `kv/` | Holds |
| --- | --- |
| `komodo/shared` | Secrets every stack on every host may read |
| `komodo/<host>/<stack>` | Secrets of one stack (a host-wide role also reads `komodo/<host>`) |

- A key name **is** the environment variable name. It must match
  `[A-Za-z_][A-Za-z0-9_]*`; a value must not contain a NUL byte.
- Later paths override earlier ones, and OpenBao values override Komodo's
  `.env` values, because compose prefers the process environment.
- A suggested convention is a `Q_` prefix for variables you define yourself, so
  they cannot collide with variables the image or compose already uses. The
  wrapper does not require it.
- A path with no usable secrets is an error, not an empty injection.

The wrapper **refuses** these key names, and stops the deploy with
`refused env var name`:

- `PATH`, `IFS`, `ENV`, `BASH_ENV`, `SHELLOPTS`, `BASHOPTS`, `PS4`, `HOME`,
  `GCONV_PATH`, `LOCPATH`, `BAO_RUN_CONF`
- Bash special variables: `RANDOM`, `SRANDOM`, `OPTIND`, `OPTARG`, `OPTERR`,
  `HISTCMD`, `LINENO`, `SECONDS`, `EPOCHSECONDS`, `EPOCHREALTIME`, `UID`,
  `EUID`, `PPID`, `GROUPS`, `FUNCNAME`, `DIRSTACK`, `PIPESTATUS`
- Any name starting with `BASH`, `LD_`, `DOCKER_` or `COMPOSE_`, and any name
  starting with `_BR_`

This list **reduces, and does not remove**, the trust you place in whoever can
write to KV. They can still set any other name the deployed command reads.

## Workflow

### 1. Create the AppRole on a workstation

`openbao-setup.sh` ships with the package. Copy it to a workstation that has the
OpenBao CLI (`bao`) and `jq`:

```bash
scp root@PVE_HOST:/usr/lib/pve-toolbox/modules/bao-run/openbao-setup.sh .
```

Then, with an admin token read without echo:

```bash
export BAO_ADDR=https://openbao.lan:8200
read -rs BAO_TOKEN; export BAO_TOKEN
chmod +x openbao-setup.sh

# host-wide role "komodo-<host>": reads kv/komodo/shared and kv/komodo/<host>
./openbao-setup.sh <host> <container-ip>

# per-stack role "komodo-<host>-<stack>": reads kv/komodo/shared and
# kv/komodo/<host>/<stack> only
./openbao-setup.sh <host> <container-ip> <stack>
```

The script checks everything before writing. It refuses a `kv/` mount that is
not KV v2, and refuses to overwrite a policy of the same name with different
rules. It enables `kv/` (v2) and `approle` if missing, writes a read-only
policy, and creates the role with a 2 minute token (5 minute maximum), a secret
ID that does not expire and is not use-limited, and both the secret ID and the
token **bound to `<container-ip>/32`**. It prints the role ID, the secret ID
(shown once) and the wrapper line. A re-run creates no new secret ID unless you
pass `--new-secret-id`.

A **per-stack role** limits a leaked credential to one stack and is the better
default. A **host-wide role** is simpler but lets every stack on that host read
every stack's secrets. A container can hold several roles; the wrapper selects
one with `-r <role>`. The role named `default` means the top-level
`role_id`/`secret_id` files and is used when `-r` is absent.

### 2. Store the secrets

Do not put secret values in command arguments, where they show in process lists
and shell history. The OpenBao documentation for `bao kv put` documents a value of
`-` as "read from stdin":

```bash
read -rs Q_DB_PASSWORD
printf '%s' "$Q_DB_PASSWORD" | bao kv put -mount=kv komodo/<host>/<stack> Q_DB_PASSWORD=-
unset Q_DB_PASSWORD
```

`bao kv put` writes a new version that holds only the keys you give it, and
stdin supplies one value. For several keys at one path, use the documented
`@file` form from a file readable only by you, on a memory-backed filesystem,
and delete it afterwards:

```bash
umask 077
install -d -m 0700 /dev/shm/bao-run-secrets
$EDITOR /dev/shm/bao-run-secrets/data.json   # {"Q_DB_PASSWORD": "...", "Q_API_KEY": "..."}
bao kv put -mount=kv komodo/<host>/<stack> @/dev/shm/bao-run-secrets/data.json
rm -rf /dev/shm/bao-run-secrets
```

A single `-` argument carrying a whole JSON body is not documented for
`bao kv put`, so this page does not use it. `BAO_TOKEN` in the environment
remains readable by your own user's processes; unset it when finished.

### 3. Install into the container

Run **as root on the PVE host**, in a terminal:

```bash
pve-toolbox install bao-run
```

Install needs a terminal and explicit confirmation. `--yes` and `--force` are
refused, for install, update and uninstall. The flow asks for:

- `Container ID`: one of the listed local containers.
- Whether Periphery runs as `systemd` or as a `container` (and the Docker
  container name).
- `OpenBao URL`: `https://host[:port]`, no path and no credentials.
- A CA file on this host (a root-owned PEM of at most 64 KiB; blank keeps the
  current one, `none` removes it).
- For each role, the AppRole name, role ID and secret ID. Secrets are read with
  hidden input, held only in protected files under `/run` on the host, and sent
  to the container in a root-only staging directory under its `/run`. They are
  at most 512 printable ASCII characters. An existing role can be kept,
  replaced or removed, and more roles can be added.

An existing unmanaged `/usr/local/bin/bao-run` is only replaced after you
confirm adopting it. The preview shows the node, container, current IPs and
payload hashes. It warns when the container uses DHCP, because AppRoles are
bound to one IP and a new lease stops logins.

Before changing anything the guest builds the resulting configuration, logs in
with every resulting role, and only then swaps files in. A failed login check,
or a failure while swapping, restores the previous files. The result is
recorded on the host in `/etc/pve-toolbox/bao-run-CTID.conf` (role names and
AppRole names, never the IDs) and
`/var/lib/pve-toolbox/bao-run-CTID.state`.

### 4. Configure the Komodo stack

In the stack's configuration set the wrapper (the setup script prints this line
for you):

```text
compose_cmd_wrapper: bao-run -r <stack> komodo/shared komodo/<host>/<stack> -- [[COMPOSE_COMMAND]]
compose_cmd_wrapper_include: (empty)
```

Leave `-r <stack>` out for the `default` role. An empty
`compose_cmd_wrapper_include` means `up` only, which is what you want: only
`docker compose up` needs the secrets.

!!! warning "Never wrap `config`"
    Do not add `config` to `compose_cmd_wrapper_include`. Komodo stores the
    output of `docker compose config` in its update logs, and with the wrapper
    in place that output contains the resolved secrets (see
    [moghtech/komodo#1636](https://github.com/moghtech/komodo/issues/1636)).

In the compose file reference variables with a default, `${Q_DB_PASSWORD:-}`.
Do not use the required form `${VAR:?}`: Komodo also runs compose commands
that are not wrapped (such as `config`), the variable is unset there, and `:?`
would fail them.

## Roles, rotation and revocation

- **Rotate a secret value.** Change it in OpenBao, then **redeploy the stack**.
  The wrapper reads values only at deploy time; running containers keep the
  old value.
- **Rotate a secret ID.** Run the setup script again with `--new-secret-id`
  (same host and stack arguments). Older secret IDs stay valid until destroyed;
  the script prints how to list them. Then run `pve-toolbox install bao-run`,
  choose `replace` for that role and enter the role ID and new secret ID.
- **Remove a role** with `remove` at the role prompt in install. Removing a role
  needs the remaining roles to pass the login check, so it fails while OpenBao
  is down. It also fails while the role's directory under `/etc/bao-run/roles/`
  contains files the module did not create; clean those up by hand first.
- **Revoke.** Whenever a role leaves management (a removed role, an uninstall, a
  forgotten container) the module prints what to run against OpenBao, for
  example:

```text
bao delete auth/approle/role/komodo-myhost-mystack
```

The module never revokes for you, and the credentials stay valid at OpenBao
until you do. You may also delete the policy of the same name
(`bao policy delete komodo-myhost-mystack`).

## Periphery in a container

If Periphery runs as a Docker container inside the CT, choose `container` at the
install prompt and give its Docker name. The container needs these **read-only**
bind mounts:

```yaml
volumes:
  - /usr/local/bin/bao-run:/usr/local/bin/bao-run:ro
  - /etc/bao-run:/etc/bao-run:ro
```

and an image that contains `bash`, `curl` and `jq`. Whether the official
Periphery image does is **unverified**; status reports `the Periphery container
lacks bash, curl or jq` if not. The user inside the container must be able to
read `/etc/bao-run`.

A single-file bind mount keeps the old file after the host file is replaced, so
**restart the Periphery container after every payload update**. Install and
update remind you, and status reports `restart the Periphery container to load
the new payload` while the container's copy differs.

## Status and doctor

```bash
pve-toolbox status bao-run         # as root on the host
pve-toolbox check bao-run          # is an update available? no login
pve-toolbox doctor                 # includes bao-run
```

Status prints one block per managed container: whether the payload is current,
whether `curl jq` are present, Periphery state, and per role `credentials ok`
or `credentials bad` plus a login word:

| Login | Meaning |
| --- | --- |
| `ok` | Login succeeded (the test token is revoked at once) |
| `rejected` | OpenBao answered 400, 401 or 403: check the role and secret ID, and that this CT's IP matches the AppRole's bound address (DHCP and a second NIC are the usual causes) |
| `unavailable` | OpenBao is reachable but not serving requests; it may be sealed |
| `tls` | The TLS handshake or certificate check failed: wrong or missing CA |
| `unreachable` | No connection: wrong URL, DNS, firewall, or OpenBao down |
| `not-checked` | No check ran, for example because the credential files are not intact |

!!! note "Scripts and monitoring"
    Plain `pve-toolbox status` exits 0 even when it reports a problem, for every
    module. For scripts use `pve-toolbox status --json bao-run` or
    `pve-toolbox doctor`; their exit status and JSON are described in
    [Automation output](../automation.md).

Status and doctor log in for every role, which **creates OpenBao audit entries**
and **would consume a limited-use secret ID** (the setup script creates
unlimited ones). `pve-toolbox check bao-run` never logs in.

Other things status reports, with what they mean:

- `pending: staging left by an incomplete operation; run install or uninstall
  bao-run to clean it up`. A container whose last install ended with an unknown
  outcome stays listed as pending and keeps failing until a later install or
  uninstall settles it.
- `identity mismatch`: the container was replaced or recreated.
- `service user cannot read credentials`: Periphery runs as a user other than
  root, which cannot read the root-only (`0700`/`0600`) credentials.
- `<role> (<approle>): missing from the CT`: the host remembers a role the
  container no longer has.

## Updating the wrapper

```bash
pve-toolbox update bao-run
```

Updates are **explicit**: a plain `pve-toolbox update` does not touch
containers and prints a reminder. The update replaces only the
`/usr/local/bin/bao-run` payload and leaves credentials, address and CA alone.
If the payload in the container matches neither the recorded nor the packaged
one, it is shown as edited and replaced only after you confirm. A payload-only
update runs no login check.

If the process is killed hard (`SIGKILL`, or power loss) mid-operation, the
staging directory `/run/pve-toolbox-bao-run-<id>` in the container can hold
credentials until it is cleaned. The next install, update or uninstall offers
`Clean up that protected staging before a new operation`; a reboot of the
container also clears `/run`.

## Adopting a manual install

If `/usr/local/bin/bao-run` already exists and was not installed by this module,
install shows its hash and asks `Adopt this existing payload for management`.
Roles found in `/etc/bao-run` that the host has no record of are asked about
(`keep`, `replace` or `remove`) and, for `keep`, you are asked for the AppRole
name so the host can record it. Anything else found in `/etc/bao-run` is left in
place and reported.

## Uninstall

```bash
pve-toolbox uninstall bao-run      # as root on the host
```

Inside the container it removes `/usr/local/bin/bao-run` (only if this module
installed it, unless you also agree to remove an unmatched one), the files
`addr`, `ca.pem`, `mount`, `role_id` and `secret_id` under `/etc/bao-run`
(including each `roles/<role>/` directory), the module's ownership record under
`/var/lib/pve-toolbox/bao-run`, and the host records for that container.

It does **not** remove other files in `/etc/bao-run` (the result is `partial`,
they are listed and the host records stay), running containers, or anything in
OpenBao. It then prints the `bao delete auth/approle/role/<name>` commands and a
reminder that **container backups and snapshots may still contain these
credentials**. Stacks that use the wrapper fail on their next deploy.

Removing the package with `apt purge` never reaches containers, so **uninstall
bao-run from every container first**.

If the container is no longer on this node, either destroyed or **migrated to
another node**, uninstall offers `Forget this container and clear its host
records` without touching the guest. A recreated container with a different
identity gets the same offer. Run the printed `bao delete` commands only if the
container was really destroyed: on a migrated container they break working
logins.

## Paths

| Where | Path | Purpose |
| --- | --- | --- |
| Container | `/usr/local/bin/bao-run` | The wrapper |
| Container | `/etc/bao-run/` (`0700`) | `addr`, `ca.pem`, optional `mount`, `role_id`, `secret_id`, `roles/<role>/` |
| Container | `/var/lib/pve-toolbox/bao-run/` | Ownership record |
| Host | `/etc/pve-toolbox/bao-run.conf` | List of managed container IDs |
| Host | `/etc/pve-toolbox/bao-run-CTID.conf` | Address, role and AppRole names, Periphery mode, identity |
| Host | `/var/lib/pve-toolbox/bao-run-CTID.state` | Payload hash and last result |

Role IDs and secret IDs are never stored on the host.
`pve-toolbox config show bao-run` (as root) shows the host records.

## Security model

The module protects against:

- Secrets in the compose file, Komodo's database or stack `.env` files: they
  live in OpenBao and exist in the deployed process environment only.
- Credential exposure in process lists and shell history on the host, in
  messages and in status output.
- A stolen credential being used from another address (the AppRole is bound to
  the container's IP), or for another stack (per-stack roles).
- Silent partial changes: a failed install restores the previous files.
- A non-root Periphery user reading credentials: it cannot, because they are
  root-only.

It does **not** protect against:

- Root in the container, which can read the credentials and every secret.
- Komodo users who can edit a stack: they can change what the wrapper runs.
- Secrets passing through the environment: `docker inspect` shows them.
- Rotation without a redeploy: running containers keep their old values.
- People who can write to KV influencing deployments. The deny-list reduces
  this and does not remove it.
- Container backups and snapshots, which hold the credentials.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| Login `rejected` | Wrong role ID or secret ID, or the container's IP is not the address the AppRole is bound to (a DHCP lease change or a second NIC). Fix the address or re-run the setup script with the correct IP and replace the role |
| Login `unavailable` | OpenBao is sealed or not yet serving. Unseal it |
| Login `tls` | Missing or wrong CA: install again with the correct CA file |
| Login `unreachable` | Check the URL, DNS and firewall from the container |
| `CT ... lacks curl jq. Run this in the CT ...` | Run the printed `apt install` inside the container |
| `bao-run changes require a terminal ...` | Run from an interactive terminal without `-y` or `--force` |
| `refused env var name 'X'` | The KV key is on the deny-list; rename it |
| `no usable secrets at kv/...` | The path is empty, has no keys, or the role cannot read it |
| `login check failed` during install | The new configuration did not log in; nothing was changed |
| `cannot remove role ...: unknown file` | Clean the role directory by hand, then retry |
| Removing a role fails | OpenBao is down, or a remaining role does not log in |
| `container identity changed` | The container was replaced; use uninstall to forget it |
| Updated payload not used by Periphery in a container | Restart the Periphery container |

## Validation limits

The automated tests exercise the real shell code against doubles for PVE
(`pct`, `pvesh`) and for OpenBao. This module has **not been run against a live
PVE 9 node or a real OpenBao**. Behaviour with a real AppRole, sealed instance,
TLS chain and Periphery is therefore unverified.

Also not covered by CI: the Komodo setting names `compose_cmd_wrapper` and
`compose_cmd_wrapper_include` and the `#1636` leak come from the operator's
guide and Komodo's source and issue tracker, checked by hand and not by tests;
and whether the official Periphery image contains `bash`, `curl` and `jq` is
unverified.
