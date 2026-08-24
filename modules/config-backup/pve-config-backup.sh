#!/usr/bin/env bash
#
# pve-config-backup - snapshot the Proxmox VE host configuration into a
# timestamped tar.gz archive, and report the result to a Discord webhook.
#
#   pve-config-backup run [--dry-run] [--force]
#         Collect, classify, hash and archive the configuration. An unchanged
#         content hash writes nothing, so two runs over an unchanged host
#         produce one archive rather than two.
#
#   pve-config-backup list
#         Archives newest first, with size, date and content hash.
#
#   pve-config-backup log
#         Commit history, when the git backend is enabled.
#
#   pve-config-backup inspect <source>
#         What a source holds: node, file count, restore classes.
#
#   pve-config-backup diff <source> [selector]
#         What restoring it would change, per path.
#
#   pve-config-backup restore <source> [selector] [--confirm] [--force]
#         Restore onto this host. Dry run unless --confirm. A full snapshot is
#         taken first, and rollback replays it.
#
#   pve-config-backup rollback [--confirm]
#         Undo the last restore. Dry run unless --confirm.
#
#   pve-config-backup --test
#         Send a test notification to the configured webhook, capture nothing.
#
#   pve-config-backup --help
#
set -Eeuo pipefail

# Installed by the pve-toolbox 'config-backup' module as
# /usr/local/bin/pve-config-backup and driven by a single systemd timer.
#
# Config, written by the module. Root-only, because the webhook URL is the
# only credential Discord checks:
#
#   /etc/pve-toolbox/config-backup.conf
#     DISCORD_WEBHOOK='https://discord.com/api/webhooks/<id>/<token>'
#     CB_ARCHIVE_DIR='/var/lib/pve-toolbox/config-backup'
#     CB_RETENTION_COUNT=30
#     CB_RETENTION_DAYS=90
#     CB_NOTIFY_ON_CHANGE=0
#
# This release captures. It does not restore: every collected path already
# carries a restore class in the manifest, and the writer that reads them back
# lands in a later release.

# ---------------------------------------------------------------- config --

CB_CONF="${CB_CONF:-/etc/pve-toolbox/config-backup.conf}"
CB_STATE_FILE="${CB_STATE_FILE:-/var/lib/pve-toolbox/config-backup.state}"
# Not /run/lock: it is world-writable (drwxrwxrwt), so any local user could
# create the lock file and hold an flock - and every capture would then exit 0
# with "already running", write no archive and no state, and never report it.
CB_LOCK_DIR="${CB_LOCK_DIR:-/run/pve-toolbox}"

# Every collected path is routed through one of these two prefixes, so the
# collector can be pointed at a fixture tree and exercised off a PVE host -
# the same trick lib/common.sh plays with its five TOOLBOX_* directories.
CB_PVE_DIR="${CB_PVE_DIR:-/etc/pve}"
CB_ROOT_DIR="${CB_ROOT_DIR:-/}"

# Defaults for everything the conf may set, declared before it is sourced so
# set -u is safe when a key is missing, and re-validated afterwards. Each one
# defers to the environment, so a manual run or a test can point the whole
# runner somewhere harmless; the conf is sourced after this and still wins.
CB_ARCHIVE_DIR="${CB_ARCHIVE_DIR:-/var/lib/pve-toolbox/config-backup}"
CB_RETENTION_COUNT="${CB_RETENTION_COUNT:-30}"
CB_RETENTION_DAYS="${CB_RETENTION_DAYS:-90}"
CB_NOTIFY_ON_CHANGE="${CB_NOTIFY_ON_CHANGE:-0}"
CB_INCLUDE_SECRETS="${CB_INCLUDE_SECRETS:-0}"
CB_AGE_RECIPIENT="${CB_AGE_RECIPIENT:-}"
CB_VOLATILE_SECTIONS="${CB_VOLATILE_SECTIONS:-firewall-live/}"
CB_LOCAL_ENABLED="${CB_LOCAL_ENABLED:-1}"
CB_GIT_ENABLED="${CB_GIT_ENABLED:-0}"
CB_GIT_DIR="${CB_GIT_DIR:-/var/lib/pve-toolbox/config-backup.git}"
CB_GIT_REMOTE="${CB_GIT_REMOTE:-}"
CB_GIT_BRANCH="${CB_GIT_BRANCH:-master}"
CB_GIT_PUSH="${CB_GIT_PUSH:-0}"
CB_GIT_SSH_KEY="${CB_GIT_SSH_KEY:-}"
CB_GIT_TOKEN_FILE="${CB_GIT_TOKEN_FILE:-}"
CB_GIT_AUTHOR_NAME="${CB_GIT_AUTHOR_NAME:-pve-toolbox}"
CB_GIT_AUTHOR_EMAIL="${CB_GIT_AUTHOR_EMAIL:-}"
# Two machine-generated files whose format we know, both of which the broad
# credential pattern legitimately matches:
#
#   pve/user.cfg              PVE records API tokens as `token:root@pam!name:`.
#                             A record type, not a credential - the secret
#                             lives in priv/token.cfg, dropped before the scan.
#   derived/dpkg-selections   multiarch dpkg emits `passwd:arm64  install`, so
#                             the package named passwd reads as `passwd:<value>`.
#
# Allow-listing two known files is the right trade against narrowing the
# pattern, which cost `password:secret` and every value under eight characters.
CB_SECRET_ALLOW="${CB_SECRET_ALLOW:-pve/user.cfg:credential derived/dpkg-selections.txt:credential}"
DISCORD_WEBHOOK="${DISCORD_WEBHOOK:-}"

CB_STAGE=""
CB_MANIFEST=""
CB_IN_CAPTURE=0
CB_DRY_RUN=0
CB_FORCE=0
CB_STARTED=$SECONDS
HOST_SHORT=$(hostname -s 2>/dev/null || hostname)

log()  { printf '%s\n' "$*"; }
usage() { awk 'NR < 3 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

_hms() { printf '%02d:%02d:%02d' $(($1 / 3600)) $((($1 % 3600) / 60)) $(($1 % 60)); }

# Reporting comes from the shared lib installed alongside this script. Loaded
# from main rather than at top level, so --help still works on a machine where
# the lib was never installed - and so the tests can source this file for its
# pure helpers without needing any lib at all.
_cb_load_lib() {
    local dir="${PVE_TOOLBOX_LIB:-/usr/local/lib/pve-toolbox}"
    # shellcheck source=../../lib/discord.sh
    source "$dir/discord.sh" 2>/dev/null \
        || { printf 'error: cannot source %s/discord.sh\n' "$dir" >&2
             _cb_state_set LAST_RUN "$(date -Is)" 2>/dev/null || true
             [[ ${CB_IN_CAPTURE:-0} -eq 1 ]] \
                 && { _cb_state_set LAST_RESULT failed 2>/dev/null || true; }
             exit 1; }
}

# Both of these report before they exit, so a failed capture is never silent.
fail() {
    printf 'error: %s\n' "$*" >&2
    _cb_notify_failure "$*"
    exit 1
}

_cb_unexpected() { # _cb_unexpected <status> <line>
    printf 'error: unexpected failure (exit %s at line %s)\n' "$1" "$2" >&2
    _cb_notify_failure "unexpected failure (exit $1 at line $2)"
    exit "$1"
}

# discord.sh is loaded from main, so anything that notifies has to cope with
# not having it - the colour constants are unset until then, and under set -u
# naming one is fatal. Reporting is best effort; capturing is not.
_cb_notify() { # _cb_notify <colour-name> <title> <desc> [name value ...]
    declare -F discord_notify >/dev/null || return 0
    [[ -n $DISCORD_WEBHOOK ]] || return 0
    local colour=${!1:-0}
    shift
    discord_notify "$DISCORD_WEBHOOK" "$colour" "$@" || true
    return 0
}

_cb_notify_failure() {
    # State first: the record has to survive a webhook outage, and it is what
    # module_status reads. Without it a failed capture keeps reporting the
    # last success and the status line never says anything went wrong.
    #
    # Only for a capture, though. --test and the argument checks go through
    # fail() too, and stamping LAST_RESULT there left a module whose webhook
    # had a typo reporting a failed *backup* from installation onward - for a
    # capture that was never attempted.
    if [[ ${CB_IN_CAPTURE:-0} -eq 1 ]]; then
        _cb_state_set LAST_RUN "$(date -Is)" 2>/dev/null || true
        _cb_state_set LAST_RESULT failed 2>/dev/null || true
    fi

    declare -F discord_notify >/dev/null || return 0
    [[ -n $DISCORD_WEBHOOK ]] || return 0
    discord_notify "$DISCORD_WEBHOOK" "$DISCORD_ERR" \
        "PVE config backup failed - $HOST_SHORT" \
        "The configuration snapshot did not complete. Nothing was written." \
        Host   "$HOST_SHORT" \
        Reason "$1" \
        Ran    "$(_hms $((SECONDS - CB_STARTED)))" || true
    return 0
}

# ----------------------------------------------------------------- state --
#
# The module reads LAST_RUN, LAST_HASH and ARCHIVE_COUNT back out of this file
# for its one-line status, so it never has to stat the archive directory on a
# menu draw. This is deliberately the same awk-upsert as state_set in
# lib/common.sh; the two have to stay in the same format. It is copied rather
# than sourced because this runner takes only discord.sh, and pulling in
# lib/common.sh would bring ask/confirm into a script whose usual caller is a
# systemd unit with no stdin.

_cb_state_set() { # _cb_state_set <key> <value>
    local tmp
    mkdir -p "$(dirname "$CB_STATE_FILE")"
    [[ -f $CB_STATE_FILE ]] || : > "$CB_STATE_FILE"
    tmp=$(mktemp)
    _STATE_V=$2 awk -v k="$1" '
        $0 ~ "^" k "=" { print k "=" ENVIRON["_STATE_V"]; found = 1; next }
        { print }
        END { if (!found) print k "=" ENVIRON["_STATE_V"] }
    ' "$CB_STATE_FILE" > "$tmp"
    cat "$tmp" > "$CB_STATE_FILE"
    rm -f "$tmp"
    chmod 0644 "$CB_STATE_FILE"
}

_cb_state_get() { # _cb_state_get <key>
    [[ -f $CB_STATE_FILE ]] || return 0
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$CB_STATE_FILE"
}

# -------------------------------------------------------- restore classes --
#
# <glob>:<class>, first match wins. never-restore entries lead, so nothing
# below can claim a key or a cluster identity file. Capture writes the class
# into the manifest and restore will read it back out of the same table, so
# the two cannot drift apart.
#
#   never      hard-blocked, even with --force: cluster identity and keys
#   guest      qemu-server / lxc configs, restorable after a pre-flight
#   pmxcfs     written through the fuse mount, then re-read to confirm
#   dropin     a plain file copy; never auto-reloaded, never auto-applied
#   reference  regenerated dumps, printed as guidance and never written back

CB_CLASSES=(
    "pve/corosync.conf:never"
    "pve/priv/*:never"
    "pve/*.pem:never"
    "pve/*.key:never"
    "pve/*.pub:never"
    "pve/nodes/*/pve-ssl.*:never"
    "pve/nodes/*/pveproxy-ssl.*:never"
    "host/etc/ssh/ssh_host_*:never"
    "secrets/*:never"

    "pve/qemu-server/*.conf:guest"
    "pve/lxc/*.conf:guest"
    "pve/nodes/*/qemu-server/*.conf:guest"
    "pve/nodes/*/lxc/*.conf:guest"

    # Written by pve-ha-lrm and pve-ha-crm on their watchdog interval, with a
    # timestamp inside. They are state, not configuration, and being
    # pmxcfs-class would put them in the hash - which means a new archive on
    # every single run on any host with HA enabled.
    "pve/ha/manager_status:reference"
    "pve/nodes/*/lrm_status:reference"

    "pve/storage.cfg:pmxcfs"
    "pve/datacenter.cfg:pmxcfs"
    "pve/user.cfg:pmxcfs"
    "pve/jobs.cfg:pmxcfs"
    "pve/vzdump.cron:pmxcfs"
    "pve/vzdump.conf:pmxcfs"
    "pve/firewall/*:pmxcfs"
    "pve/ha/*:pmxcfs"
    "pve/sdn/*:pmxcfs"
    "pve/mapping/*:pmxcfs"
    "pve/nodes/*:pmxcfs"
    "pve/*.cfg:pmxcfs"

    "host/etc/network/*:dropin"
    "host/etc/iptables/*:dropin"
    "host/etc/nftables.conf:dropin"
    "host/etc/nftables.d/*:dropin"
    "host/etc/ufw/*:dropin"
    "host/etc/hosts:dropin"
    "host/etc/hostname:dropin"
    "host/etc/resolv.conf:dropin"
    "host/etc/timezone:dropin"
    "host/etc/fstab:dropin"
    "host/etc/crypttab:dropin"
    "host/etc/apt/*:dropin"
    "host/etc/modprobe.d/*:dropin"
    "host/etc/modules-load.d/*:dropin"
    "host/etc/modules:dropin"
    "host/etc/default/grub*:dropin"
    "host/etc/kernel/*:dropin"
    "host/etc/systemd/system/*:dropin"
    "host/etc/ssh/sshd_config:dropin"
    "host/etc/ssh/sshd_config.d/*:dropin"
    "host/etc/cron.d/*:dropin"
    "host/var/spool/cron/crontabs/*:dropin"

    "resolved/*:reference"
    "derived/*:reference"
    "firewall-live/*:reference"
    "meta/*:reference"
)

_cb_classify() { # _cb_classify <path-relative-to-stage> -> class, 1 if unmatched
    local entry glob class
    for entry in "${CB_CLASSES[@]}"; do
        glob=${entry%:*}; class=${entry##*:}
        # The right side has to glob, which is exactly what SC2053 warns about.
        # shellcheck disable=SC2053
        if [[ $1 == $glob ]]; then
            printf '%s' "$class"
            return 0
        fi
    done
    printf 'unclassified'
    return 1
}

# Paths dropped before anything is scanned or hashed. Secrets never reach the
# archive unless CB_INCLUDE_SECRETS is on and an age recipient is configured,
# in which case they are encrypted per file and the cleartext removed.
CB_SECRET_PATHS=(
    "pve/priv"
    "host/etc/apt/auth.conf"
    "host/etc/apt/auth.conf.d"
)

# ------------------------------------------------------------ collection --

# A backup tool must never report success over a source it could not read.
# Swallowing the failure here is what let an unreadable file vanish from the
# archive silently - and every later phase restores from this.
CB_TAKE_ERRORS=0

_cb_take() { # _cb_take <absolute-source> <relative-destination>
    local src=$1 dest="$CB_STAGE/$2"
    [[ -e $src ]] || return 0
    if [[ -d $src ]]; then
        mkdir -p "$dest"
        if ! cp -a "$src/." "$dest/" 2>/dev/null; then
            log "warning: could not fully capture $src"
            CB_TAKE_ERRORS=$((CB_TAKE_ERRORS + 1))
        fi
    else
        mkdir -p "$(dirname "$dest")"
        if ! cp -a "$src" "$dest" 2>/dev/null; then
            log "warning: could not capture $src"
            CB_TAKE_ERRORS=$((CB_TAKE_ERRORS + 1))
        fi
    fi
    return 0
}

_cb_dump() { # _cb_dump <relative-destination> <command> [args...]
    local dest="$CB_STAGE/$1"; shift
    command -v "$1" >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$dest")"
    if ! "$@" > "$dest" 2>/dev/null; then
        rm -f "$dest"
    fi
    return 0
}

_cb_host() { printf '%s/%s' "${CB_ROOT_DIR%/}" "$1"; }

_cb_collect_pmxcfs() {
    local p
    for p in storage.cfg datacenter.cfg user.cfg jobs.cfg vzdump.cron vzdump.conf \
             corosync.conf authkey.pub ; do
        _cb_take "$CB_PVE_DIR/$p" "pve/$p"
    done
    # Raw copies, not `qm config`: the files carry the snapshot stanzas the
    # resolved view omits, and they are what a restore writes back.
    for p in firewall ha sdn mapping nodes; do
        _cb_take "$CB_PVE_DIR/$p" "pve/$p"
    done
    # Only stage the cluster's key material when it is actually going to be
    # encrypted. Otherwise the root CA key and authkey are copied in cleartext
    # to $TMPDIR - usually the root filesystem on a PVE host - and unlinked
    # again, daily, for no benefit at all.
    [[ $CB_INCLUDE_SECRETS -eq 1 ]] && _cb_take "$CB_PVE_DIR/priv" "pve/priv"
    # On a real pmxcfs these two are symlinks into nodes/<local>/, which the
    # loop above already took whole. Following them would archive, digest and
    # tar every guest config a second time.
    for p in qemu-server lxc; do
        [[ -L "$CB_PVE_DIR/$p" ]] && continue
        _cb_take "$CB_PVE_DIR/$p" "pve/$p"
    done
}

_cb_collect_resolved() {
    local id
    # qm and pct talk to the live /etc/pve no matter what CB_PVE_DIR is set to,
    # so pointing the collector at a fixture and running them anyway would ask
    # this host about vmids read out of the fixture - and answer from its own
    # real guests. The resolved view is only collected against the real thing.
    [[ $CB_PVE_DIR == /etc/pve ]] || return 0
    if command -v qm >/dev/null 2>&1; then
        while read -r id; do
            [[ -n $id ]] || continue
            _cb_dump "resolved/qemu-$id.conf" qm config "$id" --current
        done < <(_cb_vmids "$CB_PVE_DIR/qemu-server")
    fi
    if command -v pct >/dev/null 2>&1; then
        while read -r id; do
            [[ -n $id ]] || continue
            _cb_dump "resolved/lxc-$id.conf" pct config "$id"
        done < <(_cb_vmids "$CB_PVE_DIR/lxc")
    fi
}

_cb_vmids() { # _cb_vmids <dir> -> one numeric id per line, sorted
    local f b
    for f in "$1"/*.conf; do
        [[ -f $f ]] || continue
        b=$(basename "$f" .conf)
        [[ $b =~ ^[0-9]+$ ]] && printf '%s\n' "$b"
    done | LC_ALL=C sort -n
    return 0
}

_cb_collect_host() {
    local p
    for p in \
        etc/network/interfaces etc/network/interfaces.d \
        etc/network/if-pre-up.d etc/network/if-up.d etc/network/if-down.d \
        etc/iptables etc/nftables.conf etc/nftables.d etc/ufw \
        etc/hosts etc/hostname etc/resolv.conf etc/timezone \
        etc/fstab etc/crypttab \
        etc/apt/sources.list etc/apt/sources.list.d etc/apt/preferences.d \
        etc/modprobe.d etc/modules-load.d etc/modules \
        etc/kernel/cmdline \
        etc/ssh/sshd_config etc/ssh/sshd_config.d \
        etc/cron.d
    do
        _cb_take "$(_cb_host "$p")" "host/$p"
    done
    _cb_take "$(_cb_host var/spool/cron/crontabs)" "host/var/spool/cron/crontabs"

    # GRUB: the file, not the generated grub.cfg - IOMMU and vfio are
    # reconstructed from the command line, not from the generated menu.
    _cb_take "$(_cb_host etc/default/grub)" "host/etc/default/grub"
    _cb_take "$(_cb_host etc/default/grub.d)" "host/etc/default/grub.d"

    _cb_collect_custom_units
}

# /etc/systemd/system is mostly symlinks into /lib/systemd created by
# `systemctl enable`. Only the real files are somebody's configuration.
_cb_collect_custom_units() {
    local src f rel
    src=$(_cb_host etc/systemd/system)
    [[ -d $src ]] || return 0
    while IFS= read -r f; do
        rel=${f#"$src"/}
        mkdir -p "$(dirname "$CB_STAGE/host/etc/systemd/system/$rel")"
        if ! cp -a "$f" "$CB_STAGE/host/etc/systemd/system/$rel" 2>/dev/null; then
            log "warning: could not capture $f"
            CB_TAKE_ERRORS=$((CB_TAKE_ERRORS + 1))
        fi
    done < <(find "$src" -type f 2>/dev/null | LC_ALL=C sort)
    return 0
}

_cb_collect_derived() {
    _cb_dump "derived/pveversion.txt"   pveversion -v
    _cb_dump "derived/dpkg-selections.txt" dpkg --get-selections
    _cb_dump "derived/lsblk.txt"        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
    _cb_dump "derived/blkid.txt"        blkid
    _cb_dump "derived/lspci.txt"        lspci -nnk
    _cb_dump "derived/ip-addr.json"     ip -j addr
    _cb_dump "derived/ip-route.json"    ip -j route
    _cb_dump "derived/pvesm-status.txt" pvesm status
    _cb_dump "derived/cluster-resources.json" \
        pvesh get /cluster/resources --output-format json

    if command -v zpool >/dev/null 2>&1; then
        _cb_dump "derived/zfs/zpool-status.txt" zpool status
        _cb_dump "derived/zfs/zpool-get-all.txt" zpool get all
        _cb_dump "derived/zfs/zfs-list.txt" \
            zfs list -o name,used,avail,mountpoint,quota,recordsize,compression
        _cb_dump "derived/zfs/zfs-local.txt" zfs get -s local all
    fi

    # Diagnostic only, and noisy: every container start rewrites per-container
    # rules with addresses assigned by allocation order. Kept in the archive,
    # kept out of anything that diffs (see CB_VOLATILE_SECTIONS).
    _cb_dump "firewall-live/iptables.rules"   iptables-save
    _cb_dump "firewall-live/ip6tables.rules"  ip6tables-save
    _cb_dump "firewall-live/nft.ruleset"      nft list ruleset
    _cb_dump "firewall-live/ipset.txt"        ipset save
    _cb_dump "firewall-live/pve-firewall.txt" pve-firewall status
}

_cb_collect_meta() {
    mkdir -p "$CB_STAGE/meta"
    {
        printf 'node=%s\n' "$HOST_SHORT"
        printf 'captured_by=pve-config-backup\n'
        printf 'pve_dir=%s\n' "$CB_PVE_DIR"
    } > "$CB_STAGE/meta/capture.txt"
}

# ------------------------------------------------------------ normalising --
#
# Everything that would otherwise differ between two runs over an unchanged
# host is flattened here. Without this the content hash never repeats and the
# whole change-detection story collapses.

_cb_normalise() {
    local f
    # iptables-save stamps the time it ran into a comment on every dump.
    for f in "$CB_STAGE"/firewall-live/*.rules; do
        [[ -f $f ]] || continue
        sed -i '/^# Generated by .* on /d;/^# Completed on /d' "$f"
    done
    # jq -S puts object keys in a stable order; without it the same state can
    # serialise two ways. The deletions matter more: `ip -j addr` reports DHCP
    # lease lifetimes that count down every second, so without stripping them
    # no two captures ever agree and the whole change-detection story - "two
    # runs over an unchanged host write one archive" - quietly never holds.
    if command -v jq >/dev/null 2>&1; then
        while IFS= read -r f; do
            jq -S 'walk(if type == "object"
                        then del(.valid_life_time, .preferred_life_time)
                        else . end)' "$f" > "$f.sorted" 2>/dev/null \
                && mv -f "$f.sorted" "$f" || rm -f "$f.sorted"
        done < <(find "$CB_STAGE" -name '*.json' -type f 2>/dev/null | LC_ALL=C sort)
    fi
    return 0
}

# --------------------------------------------------------------- secrets --

_cb_drop_secrets() {
    local p
    for p in "${CB_SECRET_PATHS[@]}"; do
        rm -rf "${CB_STAGE:?}/$p"
    done
    # Anything key-shaped anywhere in the tree, whatever produced it.
    find "$CB_STAGE" \( -name '*.key' -o -name '*.pem' \) -type f -delete 2>/dev/null || true
    # Our own pre-restore sidecars. Left in, they are archived, restored onto
    # the host, and then backed up again on the next restore - unbounded growth
    # in /etc and in every archive.
    find "$CB_STAGE" -name '*.bak.[0-9]*' -type f -delete 2>/dev/null || true
    find "$CB_STAGE" -name '*.pve-toolbox.*' -type f -delete 2>/dev/null || true
    return 0
}

_cb_encrypt_secrets() {
    command -v age >/dev/null 2>&1 || fail "CB_INCLUDE_SECRETS is on but age is not installed"
    [[ -n $CB_AGE_RECIPIENT ]] || fail "CB_INCLUDE_SECRETS is on but CB_AGE_RECIPIENT is empty"
    local f rel
    while IFS= read -r f; do
        rel=${f#"$CB_STAGE"/}
        mkdir -p "$(dirname "$CB_STAGE/secrets/$rel")"
        age -r "$CB_AGE_RECIPIENT" -o "$CB_STAGE/secrets/$rel.age" "$f" \
            || fail "age failed on $rel"
        rm -f "$f"
    done < <(find "$CB_STAGE/pve/priv" -type f 2>/dev/null | LC_ALL=C sort)
    return 0
}

# Every pattern is passed with -e. The private-key pattern starts with a dash,
# so without it grep reads the pattern as an option bundle, exits 2, and the
# most important check in the list silently never runs.
CB_SECRET_PATTERNS=(
    "private-key:-----BEGIN [A-Z ]*PRIVATE KEY-----"
    "credential:(^|[^A-Za-z])(password|passwd|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]"
    "bearer:Bearer [A-Za-z0-9._~+/-]{20,}"
    "webhook:https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{20,}"
)

# <glob> exempts every pattern; <glob>:<pattern> exempts only that one. The
# shipped defaults are per-pattern, because exempting a file wholesale for the
# one record shape it is known to contain also switched off the private-key,
# bearer and webhook checks on a file carrying operator free text.
_cb_allowed() { # _cb_allowed <relative-path> <pattern-name>
    local glob want
    # set -f: the word splitting is wanted, the pathname expansion is not - an
    # entry like `pve/*.cfg` would otherwise expand against whatever directory
    # the runner was started from, allowing different files each time.
    set -f
    for glob in $CB_SECRET_ALLOW; do
        want=""
        [[ $glob == *:* ]] && { want=${glob##*:}; glob=${glob%:*}; }
        # shellcheck disable=SC2053
        if [[ $1 == $glob ]] && [[ -z $want || $want == "$2" ]]; then
            set +f; return 0
        fi
    done
    set +f
    return 1
}

# Prints every unallowed hit as "<path> <pattern-name>". Exit 1 if any.
_cb_secret_scan() {
    local entry name pat f rel hits=0 rc hitfile
    local -a found=()
    hitfile=$(mktemp)
    for entry in "${CB_SECRET_PATTERNS[@]}"; do
        name=${entry%%:*}; pat=${entry#*:}
        # grep runs into a file rather than a process substitution, because
        # $? after `mapfile < <(pipeline)` is mapfile's own status and never
        # the pipeline's - which made the check below unreachable, so a scan
        # that broke outright read as a scan that found nothing.
        set +e
        # -a, not -I: -I skips any file containing a NUL byte, so a key
        # hidden in one was never scanned at all. A gate that declines to open
        # a file cannot be said to have checked it.
        # -i, and anchored on a non-letter: unanchored and case-sensitive it
        # matched cloud-init's `cipassword:` - refusing the entire capture on a
        # very ordinary guest - while missing every RESTIC_PASSWORD= and
        # API_TOKEN=, which is the form these two trees actually contain. The
        # anchor still treats _ as a separator so RESTIC_PASSWORD is caught.
        grep -raiEl -e "$pat" "$CB_STAGE" >"$hitfile" 2>/dev/null
        rc=$?
        set -e
        # 0 matched, 1 matched nothing; anything else is a broken scan and must
        # not be mistaken for a clean one.
        [[ $rc -le 1 ]] || { printf 'scan-error %s (grep exit %s)\n' "$name" "$rc"; rm -f "$hitfile"; return 1; }
        mapfile -t found < "$hitfile"
        for f in "${found[@]:-}"; do
            [[ -n $f ]] || continue
            rel=${f#"$CB_STAGE"/}
            _cb_allowed "$rel" "$name" && continue
            printf '%s %s\n' "$rel" "$name"
            hits=$((hits + 1))
        done
    done
    rm -f "$hitfile"
    [[ $hits -eq 0 ]]
}

# ------------------------------------------------------- hash + manifest --

# The change-detection primitive, taken straight off the manifest: one sorted
# line per path carrying its class, size and digest. A rename moves the path, a
# byte change moves the digest, a new or deleted file adds or drops a line -
# while an mtime, an owner and directory order move none of them.
#
# Reference-class paths are excluded, and that exclusion is the whole reason
# two runs over an unchanged host agree. `pvesh get /cluster/resources` reports
# live per-guest cpu, memory and uptime; `iptables-save` on a host running
# Docker is rewritten by every container start with addresses handed out in
# allocation order. Neither is configuration, and hashing either means every
# scheduled run writes an archive and - once CB_NOTIFY_ON_CHANGE is on - pings
# Discord about a change that never happened.
_cb_hash_of() { # _cb_hash_of <manifest>
    local vol pat
    vol=$(_cb_volatile_regex)
    awk -F'\t' -v vol="$vol" '
        $2 == "reference" { next }
        vol != "" && $1 ~ vol { next }
        { print }
    ' "$1" | sha256sum | awk '{print $1}'
}

# CB_VOLATILE_SECTIONS is a space-separated list of path prefixes kept in the
# archive but out of anything that decides whether something changed.
_cb_volatile_regex() {
    local p out=""
    # set -f for the same reason as _cb_allowed: the split is wanted, the
    # pathname expansion is not - and without it the escaping below is dead
    # code, because the shell eats the glob first.
    set -f
    for p in $CB_VOLATILE_SECTIONS; do
        [[ -n $p ]] || continue
        # Doubled, because a dynamic regex is a string first: awk consumes
        # one backslash reading it and warns `escape sequence \. treated as
        # plain .` on every single run.
        out+="${out:+|}^$(printf '%s' "$p" | sed 's/[.[\*^$(){}?+|]/\\\\&/g')"
    done
    set +f
    printf '%s' "$out"
}

# path<TAB>class<TAB>size<TAB>sha256, sorted. Fails the run on anything the
# class table does not cover: "capture and restore share one table" is only
# true if something checks it.
_cb_manifest() { # _cb_manifest <dir> <out>
    local rel class sum size target unclassified=0
    : > "$2"
    # Symlinks are walked too. tar archives them, so leaving them out of the
    # manifest would mean "every captured path has exactly one restore class"
    # held only because nothing but regular files was ever looked at.
    while IFS= read -r rel; do
        rel=${rel#./}
        class=$(_cb_classify "$rel") || unclassified=$((unclassified + 1))
        if [[ -L "$1/$rel" ]]; then
            target=$(readlink "$1/$rel")
            sum=$(printf 'symlink:%s' "$target" | sha256sum | awk '{print $1}')
            size=${#target}
        else
            sum=$(sha256sum "$1/$rel" | awk '{print $1}')
            size=$(wc -c < "$1/$rel" | tr -d ' ')
        fi
        printf '%s\t%s\t%s\t%s\n' "$rel" "$class" "$size" "$sum" >> "$2"
    done < <(cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort)
    [[ $unclassified -eq 0 ]] || {
        printf 'unclassified paths:\n' >&2
        awk -F'\t' '$2 == "unclassified" { print "  " $1 }' "$2" >&2
        return 1
    }
    return 0
}

# ------------------------------------------------------------- retention --
#
# Count is a floor, not a cap: the newest COUNT archives are kept whatever
# their age, and only beyond that does DAYS prune. That is what makes the
# guarantee statable in one sentence - you always have the last COUNT runs,
# and anything older than DAYS beyond that is gone. Either knob at 0 means
# unlimited on that axis. Age-only would throw away exactly the pre-outage
# configuration a host that was off for four months comes back wanting.

_cb_prune_list() { # _cb_prune_list <count> <days> <now> <name:epoch>... (newest first)
    local count=$1 days=$2 now=$3; shift 3
    local i=0 entry name ts
    for entry in "$@"; do
        name=${entry%:*}; ts=${entry##*:}
        i=$((i + 1))
        [[ $count -gt 0 && $i -le $count ]] && continue
        [[ $days -eq 0 ]] && continue
        (( now - ts > days * 86400 )) && printf '%s\n' "$name"
    done
    return 0
}

_cb_prune() {
    local -a entries=() doomed=()
    local f name ts
    while IFS= read -r f; do
        [[ -f $f ]] || continue
        name=$(basename "$f")
        ts=$(_cb_mtime "$f")
        entries+=("$name:$ts")
    done < <(_cb_archives_newest_first)
    [[ ${#entries[@]} -eq 0 ]] && return 0

    mapfile -t doomed < <(_cb_prune_list "$CB_RETENTION_COUNT" "$CB_RETENTION_DAYS" \
                                         "$(date +%s)" "${entries[@]}")
    for name in "${doomed[@]:-}"; do
        [[ -n $name ]] || continue
        rm -f "$CB_ARCHIVE_DIR/$name" "$CB_ARCHIVE_DIR/$name.sha256" \
              "$CB_ARCHIVE_DIR/$name.manifest"
        log "pruned $name"
    done
    return 0
}

_cb_mtime() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1"; }

# Sub-second mtime, because two archives can share a whole second: the stamp
# in the name is second-granular, so a --force in the same second as the last
# run gets a -N suffix - and that suffix sorts *below* the plain name, which
# would make the newest archive look like the oldest to both the retention
# floor and the latest symlink.
_cb_mtime_ns() { stat -c '%.9Y' "$1" 2>/dev/null || _cb_mtime "$1"; }

# Newest first.
_cb_archives_newest_first() {
    local f
    while IFS= read -r f; do
        [[ -f $f ]] || continue
        printf '%s\t%s\n' "$(_cb_mtime_ns "$f")" "$f"
    done < <(find "$CB_ARCHIVE_DIR" -maxdepth 1 -name "pve-config_${HOST_SHORT}_*.tar.gz" -type f \
             2>/dev/null | LC_ALL=C sort -r) | LC_ALL=C sort -rn -k1,1 | cut -f2-
    return 0
}

_cb_archive_count() {
    find "$CB_ARCHIVE_DIR" -maxdepth 1 -name "pve-config_${HOST_SHORT}_*.tar.gz" -type f 2>/dev/null \
        | wc -l | tr -d ' '
}

_cb_archive_bytes() {
    local total=0 f
    while IFS= read -r f; do
        total=$((total + $(wc -c < "$f")))
    done < <(find "$CB_ARCHIVE_DIR" -maxdepth 1 -name "pve-config_${HOST_SHORT}_*.tar.gz" -type f 2>/dev/null)
    printf '%s' "$total"
}

# --------------------------------------------------------- git backend --
#
# A working clone whose history is the configuration's history. Commits only
# when the content hash moved, so `git log` is a list of real changes rather
# than a list of times the timer fired.
#
# Every call goes through _cb_git, which fixes an environment that cannot
# block. BatchMode is the actual guarantee that a passphrase-protected deploy
# key fails instead of hanging - "there is probably no tty" is not, because an
# operator debugging this by hand over SSH has one. The timeout is a backstop
# for stalls no ssh or http option bounds, well inside TimeoutStartSec=900.
#
# Nothing here forwards raw git stderr into fail() or a Discord embed: git
# prints remote URLs on error, and a URL can carry an embedded credential.

_cb_git() { # _cb_git <args...>
    # umask here, not only UMask= on the unit: a manual run inherits the
    # caller's, and root's default 022 leaves .git objects world-readable -
    # so containment would rest entirely on two directory modes.
    umask 077
    local -a ssh=(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new
                  -o ConnectTimeout=10)
    [[ -n $CB_GIT_SSH_KEY ]] && ssh+=(-i "$CB_GIT_SSH_KEY" -o IdentitiesOnly=yes)
    # %q per word: ${ssh[*]} loses quoting, and a key path containing a space
    # would split into two arguments - with IdentitiesOnly=yes there is no
    # fallback identity, so pushes fail permanently.
    local sshcmd="" w
    for w in "${ssh[@]}"; do sshcmd+="${sshcmd:+ }$(printf '%q' "$w")"; done
    local -a pre=(env "GIT_TERMINAL_PROMPT=0" "GIT_SSH_COMMAND=$sshcmd")
    local -a cred=()
    if [[ -n $CB_GIT_TOKEN_FILE && -n $CB_GIT_REMOTE ]]; then
        # Scoped to this remote, and the inherited chain reset first: `-c
        # credential.helper=X` appends rather than replaces, so a root with
        # `store` configured would have git persist this token in cleartext
        # under ~/.git-credentials - keyed to whichever host it just spoke to,
        # including a redirect target. followRedirects=false because git's
        # default follows exactly the request that carries the credential.
        cred=(-c "credential.helper="
              -c "credential.${CB_GIT_REMOTE}.helper=$(_cb_git_credential_helper)"
              -c "http.followRedirects=false")
    fi
    timeout 300 "${pre[@]}" git -C "$CB_GIT_DIR" "${cred[@]}" "$@"
}

# The git-credential protocol, not a bare cat: git needs username= and
# password= lines back, and a helper that prints raw bytes either fails auth
# or falls through to prompting for a username. The token's *path* is what
# ends up in the process table; the value is read when the helper runs.
_cb_git_credential_helper() {
    local host=${CB_GIT_REMOTE#*://}; host=${host%%/*}; host=${host#*@}
    # Reads its input and answers only for the configured host. A helper that
    # ignores stdin hands the token to whatever git asks about - which after a
    # redirect is the redirect target.
    #
    # %q on the path, because this is interpolated into a string git runs with
    # sh -c: unquoted, a path with a space breaks auth while install's
    # readability check still passes, and a crafted path executes.
    printf '!f() { local h=""; while IFS== read -r k v; do [ "$k" = host ] && h=$v; done; [ "$h" = %q ] || exit 0; echo username=x-access-token; echo "password=$(cat %q)"; }; f' \
        "$host" "$CB_GIT_TOKEN_FILE"
}

# A remote that already carries a credential defeats CB_GIT_TOKEN_FILE: git
# writes it verbatim into .git/config and puts it in every argv.
_cb_git_remote_has_credential() { # _cb_git_remote_has_credential <url>
    # Any userinfo at all, not just a colon-separated pair. `https://<token>@host`
    # is how GitHub and GitLab document embedding a PAT, and the colon-requiring
    # form let exactly that through - the one case the docs claimed it refused.
    # ssh URLs legitimately carry a bare user, so they are exempt.
    case $1 in ssh://*|git+ssh://*) return 1 ;; esac
    [[ $1 =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@]+@ ]]
}

_cb_git_init() {
    if [[ ! -d $CB_GIT_DIR/.git ]]; then
        # install -d before git init, and umask around it, so there is no
        # window where objects are created under the inherited umask.
        install -d -m 0700 "$CB_GIT_DIR"
        ( umask 077
          git init -q -b "$CB_GIT_BRANCH" "$CB_GIT_DIR" ) \
            || fail "could not create the git repository at $CB_GIT_DIR"
        log "initialised $CB_GIT_DIR on $CB_GIT_BRANCH"
    fi
    chmod 0700 "$CB_GIT_DIR"
    git -C "$CB_GIT_DIR" config user.name  "$CB_GIT_AUTHOR_NAME"
    git -C "$CB_GIT_DIR" config user.email "$CB_GIT_AUTHOR_EMAIL"

    # .git/info/attributes rather than a tracked .gitattributes: the latter is
    # not in the staged tree, so the --delete sync would remove it on the very
    # first run and the rule would silently stop applying.
    install -d -m 0700 "$CB_GIT_DIR/.git/info"
    printf 'secrets/** -diff\n*.age -diff\n' > "$CB_GIT_DIR/.git/info/attributes"

    if [[ -n $CB_GIT_REMOTE ]]; then
        if git -C "$CB_GIT_DIR" remote get-url origin >/dev/null 2>&1; then
            git -C "$CB_GIT_DIR" remote set-url origin "$CB_GIT_REMOTE"
        else
            git -C "$CB_GIT_DIR" remote add origin "$CB_GIT_REMOTE"
        fi
    fi
    return 0
}

# What goes into git: everything the manifest lists that is not reference-only,
# not a secret and not operator-declared volatile. Reference paths are the
# regenerated dumps - a recomputed `qm config --current` moves on a PVE upgrade
# with no operator edit behind it, and committing that makes the history a
# worse answer to "what changed" than it should be. Taking the set off the
# manifest means one filter, not a second glob list to keep in sync.
_cb_git_include() { # _cb_git_include <manifest>
    local vol; vol=$(_cb_volatile_regex)
    awk -F'\t' -v vol="$vol" '
        $2 == "reference" { next }
        $1 ~ /^secrets\// { next }
        vol != "" && $1 ~ vol { next }
        { print $1 }
    ' "$1"
}

_cb_git_sync() { # _cb_git_sync <stage> <manifest> <hash>
    local stage=$1 manifest=$2 hash=$3 include subject
    _cb_git_init

    include=$(mktemp)
    # Newline-separated, because rsync --files-from reads it that way unless
    # given --from0. git wants NUL, so the list is converted for git alone
    # below - one format change here silently broke the other consumer.
    _cb_git_include "$manifest" > "$include"

    # --delete against a live work tree has none of the staging the tar path
    # gets, so a transfer that dies half way through would be committed as a
    # permanent, corrupt point in history. rsync's exit status is the only
    # thing standing between that and `git add -A`.
    if ! rsync -a --delete --chmod=D700,F600 \
              --exclude='.git/' \
              --files-from="$include" "$stage/" "$CB_GIT_DIR/"; then
        rm -f "$include"
        fail "rsync into the git work tree failed - nothing was committed"
    fi

    # --files-from does not delete what is no longer listed, so prune anything
    # tracked that the include list no longer covers.
    _cb_git_prune_removed "$manifest"

    # Scoped to the include list, not -A. `git add -A` stages the whole work
    # tree, so anything that already lived in CB_GIT_DIR - never seen by the
    # secret scan, which only ever walks the stage - was committed on the
    # first sync and is permanent once pushed.
    # Staged from the include list, never from the tree. `git add -A` - with or
    # without `-- .`, which is a no-op because _cb_git runs -C at the work-tree
    # root - stages whatever already lives in CB_GIT_DIR. That content never
    # passed the secret scan, which only ever walks $CB_STAGE, and a pushed
    # blob is permanent. Unpacking an archive there to look at it was enough.
    # Only paths that actually landed: git add errors on a pathspec matching
    # nothing, and rsync skips a source file that vanished mid-run. Removals
    # are staged by _cb_git_prune_removed with git rm, not here.
    local present; present=$(mktemp)
    while IFS= read -r rel; do
        [[ -n $rel ]] || continue
        [[ -e $CB_GIT_DIR/$rel ]] && printf '%s\0' "$rel"
    done < "$include" > "$present"
    rm -f "$include"

    local add_err
    if [[ -s $present ]]; then
        if ! add_err=$(_cb_git add -A --pathspec-from-file="$present" --pathspec-file-nul 2>&1); then
            rm -f "$present"
            fail "git add failed: $add_err"
        fi
    fi
    rm -f "$present"
    # Exits 1 exactly when there is something to commit, which is the common
    # case here - a bare call would take the ERR trap every real change.
    if _cb_git diff --cached --quiet; then
        log "git: nothing to commit"
        _cb_git_state
        return 0
    fi
    subject="config ${hash:0:12}"
    if ! _cb_git commit -q -m "$subject" -m "content hash: $hash"; then
        fail "git commit failed"
    fi
    log "git: committed $subject"

    [[ $CB_GIT_PUSH -eq 1 && -n $CB_GIT_REMOTE ]] && _cb_git_push
    _cb_git_state
    return 0
}

# Files that were tracked and are no longer collected.
_cb_git_prune_removed() { # _cb_git_prune_removed <manifest>
    local tracked keep f
    _cb_git rev-parse --verify HEAD >/dev/null 2>&1 || return 0
    keep=$(mktemp); tracked=$(mktemp)
    _cb_git_include "$1" | LC_ALL=C sort > "$keep"
    # -c core.quotePath=false and -z: ls-files otherwise quotes a non-ASCII
    # path, so comm saw a string that never matches and the rm below targeted
    # a file that does not exist - leaving it tracked and committed forever.
    _cb_git -c core.quotePath=false ls-files | LC_ALL=C sort > "$tracked"
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        rm -f "$CB_GIT_DIR/$f"
        # --cached and --ignore-unmatch: the file is already gone from the work
        # tree, and git add no longer stages removals for us.
        _cb_git rm -q --cached --ignore-unmatch -- "$f" >/dev/null 2>&1 || true
    done < <(comm -23 "$tracked" "$keep")
    rm -f "$keep" "$tracked"
    return 0
}

# Never force. A rejected push is the correct outcome when someone else wrote
# to the branch: the remote is left exactly as it was and the local history is
# still intact for an operator to reconcile by hand.
_cb_git_push() {
    local remote_refs
    # ls-remote first, and separately from fetch, because the two failures mean
    # opposite things: an empty remote has no branch to fetch and fetch says so
    # with the same "fatal" it uses for an unreachable host. Treating both as
    # "do not push" means the very first push can never happen.
    if ! remote_refs=$(_cb_git ls-remote --heads origin "$CB_GIT_BRANCH" 2>/dev/null); then
        log "warning: the git remote is unreachable - not pushing"
        _cb_state_set GIT_PUSH_STATE unreachable
        return 0
    fi
    if [[ -z $remote_refs ]]; then
        log "git: origin has no $CB_GIT_BRANCH yet - first push"
    elif ! _cb_git fetch -q origin "$CB_GIT_BRANCH"; then
        log "warning: git fetch failed - not pushing"
        _cb_state_set GIT_PUSH_STATE unreachable
        return 0
    fi
    if _cb_git rev-parse --verify "origin/$CB_GIT_BRANCH" >/dev/null 2>&1; then
        if ! _cb_git merge-base --is-ancestor "origin/$CB_GIT_BRANCH" HEAD; then
            log "warning: $CB_GIT_BRANCH has diverged from origin - refusing to push"
            _cb_notify DISCORD_WARN \
                "PVE config backup: git remote diverged - $HOST_SHORT" \
                "The remote branch has commits this host does not. The snapshot was committed locally and the remote was left untouched; reconcile by hand." \
                Host   "$HOST_SHORT" \
                Branch "$CB_GIT_BRANCH"
            _cb_state_set GIT_PUSH_STATE diverged
            return 0
        fi
    fi
    # An explicit, fully-qualified refspec. `git push origin "$CB_GIT_BRANCH"`
    # passes the branch as a *refspec*, so a name of `+master` is a force
    # push - every guard above is skipped (ls-remote matches nothing, so it
    # takes the first-push path and never fetches) and the remote's history is
    # destroyed. The grep-guard in the tests cannot see that, because
    # `--force` never appears in the source.
    if _cb_git push -q origin "refs/heads/$CB_GIT_BRANCH:refs/heads/$CB_GIT_BRANCH"; then
        log "git: pushed to origin/$CB_GIT_BRANCH"
        _cb_state_set GIT_PUSH_STATE ok
        _cb_state_set GIT_LAST_PUSH "$(date -Is)"
    else
        log "warning: git push was rejected - the remote is unchanged"
        _cb_state_set GIT_PUSH_STATE rejected
    fi
    return 0
}

# module_status reads these and never touches CB_GIT_DIR itself: it runs for
# every module on every menu draw, so one hung mount under the repo would
# freeze the whole launcher, and a git call that fails quietly would make the
# module read as "not installed" and vanish from update and uninstall.
_cb_git_state() {
    local commits="0" head="" dirty=0 ahead=0
    if _cb_git rev-parse --verify HEAD >/dev/null 2>&1; then
        commits=$(_cb_git rev-list --count HEAD 2>/dev/null || printf '0')
        head=$(_cb_git rev-parse --short HEAD 2>/dev/null || printf '')
        if ! _cb_git diff --quiet 2>/dev/null; then dirty=1; fi
        if _cb_git rev-parse --verify "origin/$CB_GIT_BRANCH" >/dev/null 2>&1; then
            ahead=$(_cb_git rev-list --count "origin/$CB_GIT_BRANCH..HEAD" 2>/dev/null || printf '0')
        fi
    fi
    _cb_state_set GIT_COMMITS "$commits"
    _cb_state_set GIT_COMMIT  "$head"
    _cb_state_set GIT_DIRTY   "$dirty"
    _cb_state_set GIT_AHEAD   "$ahead"
    return 0
}

# -------------------------------------------------------------- restore --
#
# Four stages: inspect, diff, dry-run, apply. --dry-run is what you get unless
# you say --confirm, and every check runs before the first byte is written -
# a restore that fails half way through is worse than one that never started.
#
# The class of a path is re-derived here with the current table, never read out
# of the archive's manifest column. An archive written before a path was
# reclassified must not be able to resurrect it.

CB_CONFIRM=0
CB_RESTORE_STAMP=""
CB_ROLLBACK_INCOMPLETE=0
CB_SRC_DIR=""
CB_SRC_HASH=""
CB_SRC_NODE=""
CB_SELECTOR=""

_cb_restore_log() { printf '%s/restore.log' "$CB_ARCHIVE_DIR"; }

# Unpack a source into a directory and verify it. Accepts an absolute path, a
# name inside CB_ARCHIVE_DIR, `latest`, or a git ref when the git backend is on.
_cb_source_prepare() { # _cb_source_prepare <source>
    local src=$1 path=""
    CB_SRC_DIR=$(mktemp -d)
    _cb_cleanup_add "$CB_SRC_DIR"

    if [[ $CB_GIT_ENABLED -eq 1 && -d $CB_GIT_DIR/.git ]] \
       && _cb_git rev-parse --verify "$src^{commit}" >/dev/null 2>&1; then
        _cb_git archive --format=tar "$src" | tar -C "$CB_SRC_DIR" -xf - \
            || fail "could not extract the git ref $src"
        CB_SRC_HASH=$(_cb_git log -1 --format=%H "$src" 2>/dev/null || printf 'unknown')
        # Not $HOST_SHORT. meta/capture.txt is reference-class, so the git
        # backend never commits it and there is nothing here to read a node
        # from - claiming this host made the same-node gate structurally inert,
        # and with a shared remote another node's branch restored with no check
        # at all. Left empty, the unknown-node BLOCK catches it and
        # --target-node is how you say what you mean.
        CB_SRC_NODE=""
        log "source: git $src"
        return 0
    fi

    if [[ -f $src ]]; then path=$src
    elif [[ -f $CB_ARCHIVE_DIR/$src ]]; then path="$CB_ARCHIVE_DIR/$src"
    else fail "no such source: $src"
    fi
    path=$(readlink -f "$path")

    # A source that does not verify is refused, not warned about. Restoring
    # from a corrupt archive is how a bad day becomes a worse one.
    if [[ -f $path.sha256 ]]; then
        ( cd "$(dirname "$path")" && sha256sum -c --quiet "$(basename "$path").sha256" ) \
            || fail "$path does not match its .sha256 - refusing to restore from it"
    else
        fail "$path has no .sha256 sidecar - refusing to restore from an unverified source"
    fi

    tar -C "$CB_SRC_DIR" -xzf "$path" || fail "could not extract $path"
    # || true on both: sed and awk exit 2 on a missing file, 2>/dev/null hides
    # the message but not the status, and pipefail carries it out of the
    # substitution into the ERR trap - on exactly the hand-copied archive the
    # node guard exists to catch.
    CB_SRC_NODE=$(sed -n 's/^node=//p' "$CB_SRC_DIR/meta/capture.txt" 2>/dev/null | head -n1) || true
    CB_SRC_HASH=$(awk -F'\t' '{print $4}' "$path.manifest" 2>/dev/null | sha256sum | awk '{print $1}') || true
    log "source: $path"
    return 0
}

_cb_selected() { # _cb_selected <relpath>
    [[ -z $CB_SELECTOR ]] && return 0
    # shellcheck disable=SC2053
    # Exact, or a path component below it. A bare `$CB_SELECTOR*` made a
    # truncated selector match far more than intended - `pve/f` selected all of
    # pve/firewall/ - widening what is written *and* what rollback deletes.
    [[ $1 == "$CB_SELECTOR" || $1 == "$CB_SELECTOR"/* ]]
}

# The live path a staged path maps back onto.
_cb_live_path() { # _cb_live_path <relpath>
    case $1 in
        pve/*)  printf '%s/%s' "${CB_PVE_DIR%/}" "${1#pve/}" ;;
        host/*) printf '%s/%s' "${CB_ROOT_DIR%/}" "${1#host/}" ;;
        *)      return 1 ;;
    esac
}

# action <TAB> relpath <TAB> class <TAB> reason, one line per considered path.
# Both the dry run and the apply read this same plan, so what you are shown is
# exactly what would be done.
_cb_restore_plan() { # _cb_restore_plan <out>
    local rel class live action reason
    : > "$1"
    while IFS= read -r rel; do
        rel=${rel#./}
        _cb_selected "$rel" || continue
        class=$(_cb_classify "$rel") || class=unclassified
        action=""; reason=""
        case $class in
            never)       action='skip'; reason="never restored: cluster identity or key material" ;;
            reference)   action='skip'; reason="reference only: regenerated, never written back" ;;
            unclassified) action='skip'; reason="no restore class" ;;
        esac
        if [[ -z $action ]]; then
            live=$(_cb_live_path "$rel") || { printf 'skip\t%s\t%s\tnot a restorable prefix\n' "$rel" "$class" >> "$1"; continue; }
            if [[ -L $CB_SRC_DIR/$rel ]]; then
                # Archived as a symlink. Restoring it as a regular file would
                # sever whatever it pointed at, so say so rather than guess.
                action='skip'; reason="symlink in the source: restore it by hand"
            elif [[ ! -e $live && ! -L $live ]]; then
                action='create'; reason="absent on this host"
            elif cmp -s "$CB_SRC_DIR/$rel" "$live"; then
                action='same'; reason="identical"
            else
                action='write'; reason='differs'
            fi
        fi
        printf '%s\t%s\t%s\t%s\n' "$action" "$rel" "$class" "$reason" >> "$1"
    done < <(cd "$CB_SRC_DIR" && find . \( -type f -o -type l \) | LC_ALL=C sort)
    return 0
}

# Every check runs before anything is written. Hard failures abort.
# <allow-in-progress> is set by rollback, which is the sanctioned consumer of
# an unfinished restore: blocking it there deadlocked the host in exactly the
# state the marker exists to flag, with the tool's own error message pointing
# at the command it had just forbidden.
_cb_restore_preflight() { # _cb_restore_preflight <plan> [allow-in-progress]
    local plan=$1 allow_in_progress=${2:-0} hard=0 rel class live parent
    step_log "Pre-flight"

    if [[ $allow_in_progress -eq 0 && -n $(_cb_state_get RESTORE_IN_PROGRESS) ]]; then
        log "  BLOCK  a previous restore did not finish (started $(_cb_state_get RESTORE_IN_PROGRESS))"
        log "         inspect it, then clear it with: pve-config-backup rollback --confirm"
        hard=1
    fi

    # An unknown source node is a BLOCK, not a skipped check. Treating it as
    # "nothing to compare, carry on" let an archive with no node= line restore
    # onto any host at all.
    if [[ -z $CB_SRC_NODE ]]; then
        log "  BLOCK  this source does not record which node it came from"
        hard=1
    fi
    if [[ -n $CB_SRC_NODE && $CB_SRC_NODE != "$HOST_SHORT" ]]; then
        log "  BLOCK  this archive is from node '$CB_SRC_NODE', this host is '$HOST_SHORT'"
        log "         restoring onto a different node needs --target-node (not in this release)"
        hard=1
    fi

    # pmxcfs has to be there before anything addressed to it is attempted.
    # No pipe. `awk ... | grep -q` returns awk's status under pipefail, and
    # grep -q exits on the first match, so awk takes SIGPIPE once its output
    # outgrows a pipe buffer - and the guard then reads as "no pmxcfs paths in
    # the plan", skipping the mount and writability check entirely.
    if awk -F'\t' '$1 != "skip" && ($3 == "pmxcfs" || $3 == "guest") { found = 1; exit }
                   END { exit !found }' "$plan"; then
        if [[ ! -d $CB_PVE_DIR ]]; then
            log "  BLOCK  $CB_PVE_DIR does not exist - pmxcfs is not mounted"
            hard=1
        elif [[ ! -w $CB_PVE_DIR ]]; then
            log "  BLOCK  $CB_PVE_DIR is not writable - no quorum, or not root"
            hard=1
        fi
    fi

    while IFS=$'\t' read -r _ rel class _; do
        live=$(_cb_live_path "$rel") || continue
        parent=$(dirname "$live")
        # Hard, not --force-able: a missing parent usually means the subsystem
        # is no longer installed, and creating a path nothing reads gives false
        # confidence that something was restored.
        if [[ $class == dropin && ! -d $parent ]]; then
            log "  BLOCK  $rel: $parent does not exist on this host"
            hard=1
        fi
        if [[ -L $live ]]; then
            log "  WARN   $rel is a symlink to $(readlink "$live") - it would be replaced by a regular file"
        fi
    done < <(awk -F'\t' '$1 == "write" || $1 == "create"' "$plan")

    # A running guest keeps its live device set in the QEMU process, not the
    # file; rewriting the file can reintroduce a stale lock stanza or desync
    # the two until the next start.
    local vmid
    while IFS= read -r vmid; do
        [[ -n $vmid ]] || continue
        if _cb_guest_running "$vmid"; then
            log "  WARN   guest $vmid is running - its config will not match the live process until it stops"
        fi
    done < <(awk -F'\t' '$3 == "guest" && ($1 == "write" || $1 == "create") {print $2}' "$plan" \
             | sed 's|.*/||; s|\.conf$||' | LC_ALL=C sort -u)

    [[ $hard -eq 0 ]] || fail "pre-flight refused the restore - nothing was written"
    log "  ok     all checks passed"
    return 0
}

_cb_guest_running() { # _cb_guest_running <vmid>
    command -v qm  >/dev/null 2>&1 && qm  status "$1" 2>/dev/null | grep -q running && return 0
    command -v pct >/dev/null 2>&1 && pct status "$1" 2>/dev/null | grep -q running && return 0
    return 1
}

step_log() { printf '\n%s\n' "$*"; }

# Records whether the path existed, which is the one fact rollback needs and
# backup_file's `[[ -f $1 ]] || return 0` throws away. pmxcfs paths get no
# sidecar at all: those files replicate to every node and count against the
# cluster's own database quota, so a per-file backup there is a cluster-wide
# leak with no benefit - the pre-restore snapshot is their rollback.
_cb_backup_file() { # _cb_backup_file <live-path> <class>
    [[ -e $1 ]] || { printf 'absent'; return 0; }
    if [[ $2 == pmxcfs || $2 == guest ]]; then
        printf 'existed'
        return 0
    fi
    # Beside the archive, not beside the target: /etc/network/interfaces
    # sources interfaces.d/* with a glob, so a sidecar written there is parsed
    # as a second interfaces file, and its duplicate iface stanza breaks
    # ifreload - on the host you reach over that network. The pre-restore
    # snapshot is the real rollback; these are a convenience.
    local bakdir="$CB_ARCHIVE_DIR/pre-restore/${CB_RESTORE_STAMP:-manual}"
    mkdir -p "$bakdir$(dirname "$1")" 2>/dev/null || { printf 'existed'; return 0; }
    cp -a "$1" "$bakdir$1" 2>/dev/null || true
    chmod -R go-rwx "$CB_ARCHIVE_DIR/pre-restore" 2>/dev/null || true
    printf 'existed'
    return 0
}

# The temp file in flight, so a signal mid-write does not leave it behind to be
# captured into the next archive - and, being classifiable, restored later as
# though it were a real config file.
CB_WRITE_TMP=""
CB_ABORT=0
declare -a CB_CLEANUP=()

# trap is process-global, so a second `trap ... EXIT` silently replaces the
# first. Everything registers here and one handler removes the lot.
_cb_cleanup_add() { CB_CLEANUP+=("$1"); }
_cb_cleanup_run() {
    [[ -n ${CB_WRITE_TMP:-} ]] && rm -f "$CB_WRITE_TMP"
    local pth
    for pth in "${CB_CLEANUP[@]:-}"; do
        [[ -n $pth ]] && rm -rf "$pth"
    done
    return 0
}

# A handler that only cleans up and returns lets bash resume what it
# interrupted: a Ctrl-C, a systemctl stop or the unit's own TimeoutStartSec
# kill part way through a restore would write every remaining file and then
# report success. Raise the flag the apply loop checks, then re-raise so the
# exit status is honest.
_cb_on_signal() { # _cb_on_signal <signal>
    CB_ABORT=1
    _cb_cleanup_run
    trap - "$1"
    kill -s "$1" $$
}
trap '_cb_cleanup_run' EXIT
trap '_cb_on_signal INT' INT
trap '_cb_on_signal TERM' TERM

_cb_apply() { # _cb_apply <plan> -> writes, prints a summary
    local action rel class reason live wrote=0 created=0 skipped=0 failed=0
    local -a reload=() reboot=()
    while IFS=$'\t' read -r action rel class reason; do
        case $action in
            write|create) ;;
            *) skipped=$((skipped + 1)); continue ;;
        esac
        if [[ $CB_ABORT -eq 1 ]]; then
            log "  aborted after $((wrote + created)) file(s) - the host is part-restored"
            failed=$((failed + 1))
            break
        fi
        live=$(_cb_live_path "$rel") || continue
        _cb_backup_file "$live" "$class" >/dev/null
        # Written to a sibling temp file and renamed into place. `install` does
        # unlinkat() then openat(O_CREAT|O_EXCL), so every write opened a
        # window where the config file simply did not exist - and on pmxcfs
        # that removal replicates to every node in the cluster. Worse, pmxcfs
        # rejects the trailing chmod, so install reported failure and the
        # `|| cp -f` fallback then wrote the file a second time.
        if _cb_write_file "$CB_SRC_DIR/$rel" "$live" "$(_cb_src_mode "$rel")"; then
            [[ $action == create ]] && created=$((created + 1)) || wrote=$((wrote + 1))
            log "  wrote   $rel"
            _cb_needs_reload "$rel" && reload+=("$(_cb_needs_reload "$rel")")
            _cb_needs_reboot "$rel" && reboot+=("$rel")
        else
            failed=$((failed + 1))
            log "  FAILED  $rel"
        fi
    done < "$plan"

    # pmxcfs is the only place PVE parses on our behalf, so it is the only
    # place a write can be confirmed rather than assumed.
    _cb_verify_pmxcfs "$plan"
    failed=$((failed + CB_VERIFY_FAILED))

    step_log "Summary"
    printf '  written   %s\n  created   %s\n  skipped   %s\n  failed    %s\n' \
        "$wrote" "$created" "$skipped" "$failed"
    if [[ ${#reload[@]} -gt 0 ]]; then
        step_log "Nothing was reloaded. Run these yourself when you are ready:"
        printf '%s\n' "${reload[@]}" | LC_ALL=C sort -u | sed 's/^/  /'
    fi
    if [[ ${#reboot[@]} -gt 0 ]]; then
        step_log "A reboot is warranted - these only take effect at boot:"
        printf '%s\n' "${reboot[@]}" | LC_ALL=C sort -u | sed 's/^/  /'
    fi
    [[ $failed -eq 0 ]]
}

# rename(2) is atomic, and pmxcfs supports it: no reader ever sees a torn or
# missing file, and an interrupt leaves the old content rather than nothing.
_cb_write_file() { # _cb_write_file <source> <destination> <mode>
    # mktemp, not "$2.pve-toolbox.$$": the pid is predictable, and cp -f
    # *follows* a symlink already sitting at that name - so the restored
    # content went through the link into an unrelated file and the destination
    # was left pointing at the attacker's path. Directories the tool writes
    # into are not all root-exclusive (/var/spool/cron/crontabs is 1730).
    local tmp
    # A fixed infix, so one glob still finds an orphan left by a SIGKILL or a
    # power loss. Renaming the scheme without moving the cleanup meant an
    # orphan was captured, classified dropin, archived, and written back onto
    # the host by a later restore - worst of all into interfaces.d/.
    tmp=$(mktemp "$2.pve-toolbox.XXXXXX" 2>/dev/null) || return 1
    CB_WRITE_TMP=$tmp
    # > rather than cp, so an existing link at the target cannot be traversed:
    # mktemp just created this as a regular file we own.
    if ! cat "$1" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"; CB_WRITE_TMP=""; return 1
    fi
    # pmxcfs enforces its own mode and refuses chmod, so a failure here is
    # expected there and must not fail the write.
    chmod "$3" "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$2" 2>/dev/null; then
        rm -f "$tmp"; CB_WRITE_TMP=""; return 1
    fi
    CB_WRITE_TMP=""
    return 0
}

_cb_src_mode() { # _cb_src_mode <relpath>
    stat -c '%a' "$CB_SRC_DIR/$1" 2>/dev/null || printf '0644'
}

# Deliberately never reloads anything: writing a file is reversible, applying
# a bad network config to a host you reach over that network is not.
_cb_needs_reload() { # _cb_needs_reload <relpath> -> prints a command, or 1
    case $1 in
        host/etc/network/*)      printf 'ifreload -a   # or: systemctl restart networking' ;;
        host/etc/ssh/sshd_config*) printf 'systemctl reload ssh' ;;
        host/etc/iptables/*)     printf 'iptables-restore < %s' "$(_cb_live_path "$1")" ;;
        host/etc/nftables*)      printf 'systemctl reload nftables' ;;
        host/etc/apt/*)          printf 'apt-get update' ;;
        host/etc/cron.d/*)       printf 'systemctl restart cron' ;;
        pve/firewall/*)          printf 'pve-firewall compile   # then: pve-firewall restart' ;;
        host/etc/systemd/system/*) printf 'systemctl daemon-reload' ;;
        *) return 1 ;;
    esac
}

_cb_needs_reboot() { # _cb_needs_reboot <relpath>
    case $1 in
        host/etc/modprobe.d/*|host/etc/modules-load.d/*|host/etc/modules) return 0 ;;
        host/etc/default/grub*|host/etc/kernel/*) return 0 ;;
        host/etc/fstab|host/etc/crypttab) return 0 ;;
        *) return 1 ;;
    esac
}

CB_VERIFY_FAILED=0

_cb_verify_pmxcfs() { # _cb_verify_pmxcfs <plan>
    local rel live
    CB_VERIFY_FAILED=0
    while IFS=$'\t' read -r rel; do
        [[ -n $rel ]] || continue
        live=$(_cb_live_path "$rel") || continue
        if ! cmp -s "$CB_SRC_DIR/$rel" "$live"; then
            log "  FAILED  $rel did not read back as written - PVE rejected or rewrote it"
            CB_VERIFY_FAILED=$((CB_VERIFY_FAILED + 1))
        fi
    done < <(awk -F'\t' '($3 == "pmxcfs" || $3 == "guest") && ($1 == "write" || $1 == "create") {print $2}' "$1")
    return 0
}

_cb_show_plan() { # _cb_show_plan <plan>
    local action rel class reason
    step_log "Plan"
    while IFS=$'\t' read -r action rel class reason; do
        case $action in
            same) continue ;;
        esac
        printf '  %-7s %-10s %-46s %s\n' "$action" "$class" "$rel" "$reason"
    done < "$1"
    printf '\n'
    awk -F'\t' '{ c[$1]++ } END { for (k in c) printf "  %-8s %d\n", k, c[k] }' "$1" | LC_ALL=C sort
}

_cb_restore() { # _cb_restore <source> [selector]
    _cb_take_lock || fail "a capture or restore is already running - refusing to start another"
    [[ -n ${1:-} ]] || fail "restore needs a source (an archive name, 'latest', or a git ref)"
    CB_SELECTOR=${2:-}
    _cb_source_prepare "$1"

    local plan; plan=$(mktemp)
    _cb_restore_plan "$plan"
    _cb_restore_preflight "$plan"
    _cb_show_plan "$plan"

    if [[ $CB_CONFIRM -eq 0 ]]; then
        step_log "Dry run - nothing was written. Add --confirm to apply."
        rm -f "$plan"
        return 0
    fi

    step_log "Snapshot before restoring"
    # Forced, and never allowed a dry-run or git-only path: the dedup guard
    # would skip the write when nothing changed since the last capture, and a
    # git-only install writes no archive at all - both leaving a stale
    # LAST_ARCHIVE pointing at something else entirely.
    local prev_archive; prev_archive=$(_cb_state_get LAST_ARCHIVE)
    CB_FORCE=1 CB_DRY_RUN=0 CB_LOCAL_ENABLED=1 _cb_capture_once \
        || fail "the pre-restore snapshot failed - refusing to restore without a rollback"
    local rollback; rollback=$(_cb_state_get LAST_ARCHIVE)
    # A non-empty string is not a rollback point.
    [[ -n $rollback ]] || fail "no rollback archive was produced - refusing to restore"
    [[ -f $CB_ARCHIVE_DIR/$rollback ]] \
        || fail "the rollback archive $rollback is not on disk - refusing to restore"
    [[ $rollback != "$prev_archive" ]] \
        || fail "the pre-restore snapshot wrote nothing new - refusing to restore without a rollback"
    _cb_state_set ROLLBACK_ARCHIVE "$rollback"
    _cb_state_set ROLLBACK_SELECTOR "$CB_SELECTOR"
    ok_log "rollback point: $rollback"

    # Written before the first byte, so an interrupted restore leaves evidence
    # rather than looking like it never happened.
    CB_RESTORE_STAMP=$(date +%Y%m%dT%H%M%S)
    _cb_state_set RESTORE_IN_PROGRESS "$(date -Is)"
    # Exactly what this restore creates, recorded before the first byte. This
    # is what rollback deletes - inferring it from "absent from the snapshot"
    # meant an unreadable file that never made it into the snapshot looked
    # like something the restore had created, and got removed from a live host.
    local created_list="$CB_ARCHIVE_DIR/restore-created.list"
    awk -F'\t' '$1 == "create" { print $2 }' "$plan" > "$created_list"
    chmod 0600 "$created_list" 2>/dev/null || true
    _cb_restore_record started "$1" "$rollback" "$plan"

    step_log "Applying"
    if _cb_apply "$plan"; then
        _cb_state_set RESTORE_IN_PROGRESS ""
        _cb_restore_record ok "$1" "$rollback" "$plan"
        _cb_notify DISCORD_WARN "PVE config restored - $HOST_SHORT" \
            "Configuration was restored from a snapshot. Nothing was reloaded; check the summary." \
            Host "$HOST_SHORT" Source "$1" Rollback "$rollback"
    else
        # The marker stays set. Its entire purpose is to stop another restore
        # running on a host that is half-restored, and clearing it here made
        # the detected-failure path less safe than an outright crash.
        _cb_restore_record partial "$1" "$rollback" "$plan"
        rm -f "$plan"
        fail "some files could not be written - the host is part-restored, roll back with: pve-config-backup rollback --confirm"
    fi
    rm -f "$plan"
    return 0
}

ok_log() { printf '  %s\n' "$*"; }

_cb_restore_record() { # _cb_restore_record <outcome> <source> <rollback> <plan>
    local f; f=$(_cb_restore_log)
    mkdir -p "$CB_ARCHIVE_DIR"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(date -Is)" "$1" "$2" "${CB_SELECTOR:-ALL}" "${CB_SRC_HASH:0:12}" "$3" >> "$f"
    chmod 0600 "$f" 2>/dev/null || true
    return 0
}

# Rollback is a sync, not a replay. A path the restore created is by
# definition absent from the pre-restore archive, so restoring everything the
# archive holds would never visit it and never remove it. Live-only paths
# inside the same scope are deleted.
_cb_rollback() {
    CB_ROLLBACK_INCOMPLETE=0
    _cb_take_lock || fail "a capture or restore is already running - refusing to start another"
    local rollback; rollback=$(_cb_state_get ROLLBACK_ARCHIVE)
    [[ -n $rollback ]] || fail "there is no rollback point recorded"
    # The same scope the restore used, or a scoped restore would be undone by
    # reverting unrelated edits made since.
    CB_SELECTOR=$(_cb_state_get ROLLBACK_SELECTOR)
    _cb_source_prepare "$rollback"

    local plan; plan=$(mktemp)
    _cb_restore_plan "$plan"
    local extra; extra=$(mktemp)
    _cb_rollback_extras > "$extra"

    _cb_show_plan "$plan"
    if [[ -s $extra ]]; then
        step_log "These exist now and did not before - rollback deletes them:"
        sed 's/^/  /' "$extra"
    fi

    if [[ $CB_CONFIRM -eq 0 ]]; then
        step_log "Dry run - nothing was written. Add --confirm to roll back."
        rm -f "$plan" "$extra"
        return 0
    fi

    # Rollback writes to the same live host a restore does, so it runs the
    # same checks. Without them it would push through an unmounted pmxcfs,
    # report every write FAILED, delete the live-only paths anyway, and still
    # record the outcome as a successful rollback and exit 0.
    _cb_restore_preflight "$plan" 1

    _cb_state_set RESTORE_IN_PROGRESS "$(date -Is)"
    step_log "Rolling back"
    local rb_ok=1
    _cb_apply "$plan" || rb_ok=0
    # Only delete once every write landed. Deleting anyway left the host in a
    # third state - neither what it was before the restore nor what the restore
    # made it.
    local rel live
    if [[ $rb_ok -eq 1 ]]; then
        while IFS= read -r rel; do
            [[ -n $rel ]] || continue
            live=$(_cb_live_path "$rel") || continue
            if rm -f "$live"; then
                log "  deleted $rel"
            else
                log "  FAILED to delete $rel"
                CB_ROLLBACK_INCOMPLETE=1
            fi
        done < "$extra"
    else
        log "  writes failed - not deleting anything the restore created"
    fi
    # A rollback that knowingly skipped part of its work is not a success:
    # reporting one retired the rollback point and made a retry impossible.
    [[ $CB_ROLLBACK_INCOMPLETE -eq 1 ]] && rb_ok=0
    if [[ $rb_ok -eq 1 ]]; then
        _cb_state_set RESTORE_IN_PROGRESS ""
        # Retire the rollback point with the rollback. Leaving both set let a
        # second `rollback --confirm` run against a stale list and delete files
        # an operator had written by hand since.
        _cb_state_set ROLLBACK_ARCHIVE ""
        _cb_state_set ROLLBACK_SELECTOR ""
        rm -f "$CB_ARCHIVE_DIR/restore-created.list"
        _cb_restore_record rollback "$rollback" "$rollback" "$plan"
        rm -f "$plan" "$extra"
        return 0
    fi
    # Leave the marker set: a rollback that could not write everything has not
    # put the host back, and the next restore must stay blocked until someone
    # has looked.
    _cb_restore_record rollback-partial "$rollback" "$rollback" "$plan"
    rm -f "$plan" "$extra"
    fail "the rollback did not complete - the host is part-restored"
}

# Restorable paths that are live now and absent from the rollback source.
# What the restore actually created, read back from the list it wrote before
# it wrote anything. Walking the live filesystem and calling everything absent
# from the snapshot "created" was wrong twice over: a file the capture could
# not read looked created and was deleted, and the walk was an unbounded
# `find /` that traversed /proc, /sys and every NFS mount - in the default
# dry run, so a plain `rollback` appeared to hang.
_cb_rollback_extras() {
    local list="$CB_ARCHIVE_DIR/restore-created.list" rel class
    if [[ ! -r $list ]]; then
        # Say so. Silently rolling back everything except the created files is
        # not the faithful inverse this claims to be.
        log "warning: no record of what the restore created ($list) - nothing will be deleted"
        CB_ROLLBACK_INCOMPLETE=1
        return 0
    fi
    while IFS= read -r rel; do
        [[ -n $rel ]] || continue
        _cb_selected "$rel" || continue
        class=$(_cb_classify "$rel") || continue
        case $class in never|reference|unclassified) continue ;; esac
        [[ -e $(_cb_live_path "$rel") ]] || continue
        printf '%s\n' "$rel"
    done < "$list"
    return 0
}

_cb_inspect() { # _cb_inspect <source>
    [[ -n ${1:-} ]] || fail "inspect needs a source"
    _cb_source_prepare "$1"
    local man; man=$(mktemp)
    _cb_manifest "$CB_SRC_DIR" "$man" || true
    step_log "Source"
    printf '  node      %s%s\n' "${CB_SRC_NODE:-unknown}" \
        "$([[ -n $CB_SRC_NODE && $CB_SRC_NODE != "$HOST_SHORT" ]] && printf '  (this host is %s)' "$HOST_SHORT")"
    printf '  files     %s\n' "$(wc -l < "$man" | tr -d ' ')"
    step_log "By restore class"
    awk -F'\t' '{ c[$2]++ } END { for (k in c) printf "  %-12s %d\n", k, c[k] }' "$man" | LC_ALL=C sort
    rm -f "$man"
    return 0
}

_cb_diff() { # _cb_diff <source> [selector]
    [[ -n ${1:-} ]] || fail "diff needs a source"
    CB_SELECTOR=${2:-}
    _cb_source_prepare "$1"
    local plan; plan=$(mktemp)
    _cb_restore_plan "$plan"
    local action rel class reason mark
    while IFS=$'\t' read -r action rel class reason; do
        case $action in
            write)  mark='~' ;;
            create) mark='+' ;;
            same)   mark=' ' ;;
            *)      mark='!' ;;
        esac
        printf '%s %-10s %-46s %s\n' "$mark" "$class" "$rel" "$reason"
    done < "$plan" | LC_ALL=C sort -k1,1
    printf '\n  ~ differs   + only in the source   ! not restorable\n'
    rm -f "$plan"
    return 0
}

# ------------------------------------------------------------------ run --

# Returns 1 rather than exiting, so the caller decides what a held lock means.
# It means opposite things either side: a scheduled capture that finds one
# running should step aside quietly, while a restore that finds one must stop
# loudly - exiting 0 there would tell an operator who ran `restore --confirm`
# that it worked when nothing happened at all.
#
# Taken once per process. Re-running `exec 9>` on the same path opens a second
# file description, and flock locks descriptions rather than processes, so a
# second call would drop the first lock and silently re-take it.
_cb_take_lock() {
    local dir=$CB_LOCK_DIR
    mkdir -p "$dir" 2>/dev/null || dir=/tmp
    chmod 0700 "$dir" 2>/dev/null || true
    exec 9>"$dir/pve-config-backup.lock"
    flock -n 9
}

_cb_lock() {
    if ! _cb_take_lock; then
        log "a capture is already running - leaving it alone"
        exit 0
    fi
}

_cb_run() {
    _cb_lock
    _cb_capture_once
}

# Everything a capture does, minus the lock, so a restore can take its own
# pre-restore snapshot while already holding it.
_cb_capture_once() {
    # Not under --dry-run: a dry run must no more write state than it writes
    # an archive, and this flag is what lets a failure stamp LAST_RESULT.
    [[ $CB_DRY_RUN -eq 0 ]] && CB_IN_CAPTURE=1
    CB_TAKE_ERRORS=0
    CB_STAGE=$(mktemp -d)
    CB_MANIFEST=$(mktemp)
    _cb_cleanup_add "$CB_STAGE"
    _cb_cleanup_add "$CB_MANIFEST"

    _cb_collect_pmxcfs
    _cb_collect_resolved
    _cb_collect_host
    _cb_collect_derived
    _cb_collect_meta

    if [[ $CB_INCLUDE_SECRETS -eq 1 ]]; then
        _cb_encrypt_secrets
    fi
    _cb_drop_secrets

    local scan
    if ! scan=$(_cb_secret_scan); then
        fail "secret scan refused the capture:"$'\n'"$scan"
    fi

    # Everything above either read what it was asked for or said so. A
    # capture that quietly lost files, or one taken while pmxcfs was down,
    # must not be written, verified, symlinked as `latest` and then counted
    # toward the retention floor - thirty of those evict every good archive,
    # and the status line reads archives:30 the whole time.
    [[ $CB_TAKE_ERRORS -eq 0 ]] \
        || fail "$CB_TAKE_ERRORS path(s) could not be captured - refusing to write a partial archive"
    [[ -d $CB_STAGE/pve/nodes ]] \
        || fail "$CB_PVE_DIR has no nodes/ - pmxcfs does not look mounted (is pve-cluster running?)"

    _cb_normalise

    local manifest hash previous
    manifest=$CB_MANIFEST
    _cb_manifest "$CB_STAGE" "$manifest" || fail "some captured paths have no restore class"
    hash=$(_cb_hash_of "$manifest")
    previous=$(_cb_state_get LAST_HASH)

    local files
    files=$(wc -l < "$manifest" | tr -d ' ')

    if [[ $CB_DRY_RUN -eq 1 ]]; then
        log "would capture $files file(s), content hash $hash"
        awk -F'\t' '{ c[$2]++ } END { for (k in c) printf "  %-12s %d\n", k, c[k] }' \
            "$manifest" | LC_ALL=C sort
        [[ $hash == "$previous" ]] && log "unchanged since the last run - would write nothing"
        return 0
    fi

    # The archive the hash stands for has to still be there. Comparing hashes
    # alone meant an emptied archive directory - or a repointed CB_ARCHIVE_DIR,
    # or an NFS mount absent at boot - reported "unchanged", exited 0, and left
    # module_status showing a healthy archive count with nothing on disk.
    local last_archive; last_archive=$(_cb_state_get LAST_ARCHIVE)
    if [[ $hash == "$previous" && $CB_FORCE -eq 0 && -n $last_archive \
          && ! -r $CB_ARCHIVE_DIR/$last_archive ]]; then
        log "the last archive ($last_archive) is gone - writing a new one"
        previous=""
    fi
    if [[ $hash == "$previous" && $CB_FORCE -eq 0 ]]; then
        log "configuration unchanged ($hash) - no new archive"
        _cb_state_set LAST_RUN "$(date -Is)"
        _cb_state_set LAST_RESULT unchanged
        _cb_state_set LAST_DURATION "$(_hms $((SECONDS - CB_STARTED)))"
        return 0
    fi

    if [[ $CB_LOCAL_ENABLED -eq 1 ]]; then
        _cb_write_archive "$manifest" "$hash" "$files"
    else
        log "local backend disabled - no archive written"
        _cb_state_set LAST_RUN "$(date -Is)"
        _cb_state_set LAST_RESULT ok
        _cb_state_set LAST_HASH "$hash"
        _cb_state_set LAST_DURATION "$(_hms $((SECONDS - CB_STARTED)))"
    fi

    if [[ $CB_GIT_ENABLED -eq 1 ]]; then
        _cb_git_sync "$CB_STAGE" "$manifest" "$hash"
    fi

    # Out here rather than inside the archive step, so a git-only install
    # still reports a change.
    if [[ $CB_NOTIFY_ON_CHANGE -eq 1 ]]; then
        local backends=""
        [[ $CB_LOCAL_ENABLED -eq 1 ]] && backends="archive"
        [[ $CB_GIT_ENABLED   -eq 1 ]] && backends="${backends:+$backends + }git"
        _cb_notify DISCORD_OK \
            "PVE config changed - $HOST_SHORT" \
            "The configuration changed since the last run and a new snapshot was taken." \
            Host     "$HOST_SHORT" \
            Backends "$backends" \
            Archive  "$(_cb_state_get LAST_ARCHIVE)" \
            Files    "$files" \
            Hash     "${hash:0:12}" \
            Took     "$(_hms $((SECONDS - CB_STARTED)))"
    fi
    return 0
}

_cb_write_archive() { # _cb_write_archive <manifest> <hash> <filecount>
    local manifest=$1 hash=$2 files=$3
    mkdir -p "$CB_ARCHIVE_DIR"
    chmod 0700 "$CB_ARCHIVE_DIR"
    local name path tmp stamp n=1
    # Second granularity, so a --force run in the same second as the last one
    # would otherwise silently overwrite it.
    stamp=$(date +%Y%m%dT%H%M%S)
    name="pve-config_${HOST_SHORT}_${stamp}.tar.gz"
    while [[ -e "$CB_ARCHIVE_DIR/$name" ]]; do
        n=$((n + 1))
        name="pve-config_${HOST_SHORT}_${stamp}-${n}.tar.gz"
    done
    path="$CB_ARCHIVE_DIR/$name"
    tmp="$path.partial"

    # Reproducible: sorted members, no owner names, no mtimes, and gzip -n so
    # the original name and timestamp stay out of the gzip header too. The
    # same tree twice gives the same bytes.
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -C "$CB_STAGE" -cf - . | gzip -n -9 > "$tmp" \
        || { rm -f "$tmp"; fail "tar failed"; }
    mv -f "$tmp" "$path"
    chmod 0600 "$path"

    cp -f "$manifest" "$path.manifest"
    chmod 0600 "$path.manifest"
    ( cd "$CB_ARCHIVE_DIR" && sha256sum "$name" > "$name.sha256" )
    chmod 0600 "$path.sha256"

    ( cd "$CB_ARCHIVE_DIR" && sha256sum -c --quiet "$name.sha256" ) \
        || { rm -f "$path" "$path.sha256" "$path.manifest"; fail "checksum failed after write"; }
    tar -tzf "$path" >/dev/null 2>&1 \
        || { rm -f "$path" "$path.sha256" "$path.manifest"; fail "archive is not readable after write"; }

    ln -sfn "$name" "$CB_ARCHIVE_DIR/latest"
    _cb_prune
    # The symlink survives its own target being pruned only by luck; re-point
    # it at whatever is actually newest now.
    _cb_relink_latest

    local took bytes
    took=$(_hms $((SECONDS - CB_STARTED)))
    bytes=$(wc -c < "$path" | tr -d ' ')

    _cb_state_set LAST_RUN "$(date -Is)"
    _cb_state_set LAST_RESULT ok
    _cb_state_set LAST_HASH "$hash"
    _cb_state_set LAST_DURATION "$took"
    _cb_state_set LAST_ARCHIVE "$name"
    _cb_state_set ARCHIVE_COUNT "$(_cb_archive_count)"
    _cb_state_set ARCHIVE_BYTES "$(_cb_archive_bytes)"

    log "wrote $path ($bytes bytes, $files files, $took)"
    # The capture is over. Leaving this set meant every later restore-time
    # failure stamped LAST_RESULT=failed and sent "the configuration snapshot
    # did not complete" - reporting a healthy backup as broken.
    CB_IN_CAPTURE=0

    return 0
}

_cb_relink_latest() {
    local newest
    # Drain the pipe rather than truncating it: `| head -n1` closes the read
    # end, the upstream cut takes SIGPIPE, and pipefail turns that into 141 -
    # tripping the ERR trap, sending a false "nothing was written" alert, and
    # leaving LAST_HASH unset so every later run writes another archive.
    newest=$(_cb_archives_newest_first | awk 'NR == 1 { v = $0 } END { print v }')
    if [[ -n $newest ]]; then
        ln -sfn "$(basename "$newest")" "$CB_ARCHIVE_DIR/latest"
    else
        rm -f "$CB_ARCHIVE_DIR/latest"
    fi
    return 0
}

# Guarded on the repo existing, not merely on CB_GIT_ENABLED: the two diverge
# when the first init never got as far as creating it.
_cb_git_log() {
    [[ $CB_GIT_ENABLED -eq 1 ]] || fail "the git backend is not enabled"
    [[ -d $CB_GIT_DIR/.git ]]  || fail "no git repository at $CB_GIT_DIR"
    if ! _cb_git rev-parse --verify HEAD >/dev/null 2>&1; then
        log "no commits yet"
        return 0
    fi
    _cb_git --no-pager log --oneline --decorate -n "${CB_LOG_LINES:-20}" || true
    return 0
}

_cb_list() {
    local f name size when hash
    [[ -d $CB_ARCHIVE_DIR ]] || { log "no archives in $CB_ARCHIVE_DIR"; return 0; }
    printf '%-44s %10s  %-19s  %s\n' ARCHIVE SIZE WRITTEN HASH
    while IFS= read -r f; do
        name=$(basename "$f")
        size=$(wc -c < "$f" | tr -d ' ')
        when=$(date -d "@$(_cb_mtime "$f")" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '?')
        hash=$([[ -f $f.sha256 ]] && awk '{print substr($1,1,12)}' "$f.sha256" || printf '-')
        printf '%-44s %10s  %-19s  %s\n' "$name" "$size" "$when" "$hash"
    done < <(find "$CB_ARCHIVE_DIR" -maxdepth 1 -name "pve-config_${HOST_SHORT}_*.tar.gz" -type f \
             2>/dev/null | LC_ALL=C sort -r)
    return 0
}

# ----------------------------------------------------------------- main --

_cb_read_conf() {
    if [[ -r $CB_CONF ]]; then
        # shellcheck source=/dev/null
        source "$CB_CONF"
    else
        log "warning: cannot read $CB_CONF - falling back to defaults"
    fi
    [[ $CB_RETENTION_COUNT =~ ^[0-9]+$ ]] || CB_RETENTION_COUNT=30
    [[ $CB_RETENTION_DAYS  =~ ^[0-9]+$ ]] || CB_RETENTION_DAYS=90
    [[ $CB_NOTIFY_ON_CHANGE =~ ^[01]$  ]] || CB_NOTIFY_ON_CHANGE=0
    [[ $CB_INCLUDE_SECRETS  =~ ^[01]$  ]] || CB_INCLUDE_SECRETS=0
    [[ -n $CB_ARCHIVE_DIR ]] || CB_ARCHIVE_DIR=/var/lib/pve-toolbox/config-backup
    [[ $CB_LOCAL_ENABLED =~ ^[01]$ ]] || CB_LOCAL_ENABLED=1
    [[ $CB_GIT_ENABLED   =~ ^[01]$ ]] || CB_GIT_ENABLED=0
    [[ $CB_GIT_PUSH      =~ ^[01]$ ]] || CB_GIT_PUSH=0
    [[ -n $CB_GIT_BRANCH ]] || CB_GIT_BRANCH=master
    # Only when the git backend is on. Unguarded this ran on every install,
    # including local-archive-only ones that never pkg_ensure git - so on a
    # host without it every timer firing aborted before collecting anything,
    # wrote no archive, and alerted about a branch name nobody set.
    if [[ $CB_GIT_ENABLED -eq 1 ]]; then
        command -v git >/dev/null 2>&1 \
            || fail "git not found but the git backend is enabled"
        command -v rsync >/dev/null 2>&1 \
            || fail "rsync not found but the git backend is enabled"
        git check-ref-format --branch "$CB_GIT_BRANCH" >/dev/null 2>&1 \
            || fail "invalid git branch name: $CB_GIT_BRANCH"
    fi
    [[ -n $CB_GIT_AUTHOR_EMAIL ]] || CB_GIT_AUTHOR_EMAIL="pve-toolbox@$HOST_SHORT"
    # Refusing both leaves a timer that captures and then throws it away.
    [[ $CB_LOCAL_ENABLED -eq 1 || $CB_GIT_ENABLED -eq 1 ]] \
        || fail "both backends are disabled - set CB_LOCAL_ENABLED or CB_GIT_ENABLED"
}

main() {
    local mode=""
    case ${1:-} in
        -h|--help)    usage; exit 0 ;;
        --test)       mode='test'; shift ;;
        run)          mode='run';  shift ;;
        log)          mode='log'; shift ;;
        inspect)      mode='inspect'; shift ;;
        diff)         mode='diff'; shift ;;
        restore)      mode='restore'; shift ;;
        rollback)     mode='rollback'; shift ;;
        list)         mode='list'; shift ;;
        "")           usage >&2; exit 2 ;;
        *)            printf 'error: unknown command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac

    local -a operands=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                [[ $CB_CONFIRM -eq 1 ]] \
                    && { printf 'error: --dry-run and --confirm are contradictory\n' >&2; exit 2; }
                case $mode in
                    run|restore|rollback) CB_DRY_RUN=1; CB_CONFIRM=0 ;;
                    *) printf 'error: --dry-run does not apply to %s\n' "$mode" >&2; exit 2 ;;
                esac ;;
            --confirm)
                # Never alongside --dry-run. Last-flag-wins left both set, so
                # the restore applied while the pre-restore snapshot took its
                # own dry-run path and wrote nothing - making the rollback
                # point the archive being restored *from*.
                [[ $CB_DRY_RUN -eq 1 ]] \
                    && { printf 'error: --dry-run and --confirm are contradictory\n' >&2; exit 2; }
                case $mode in
                    restore|rollback) CB_CONFIRM=1 ;;
                    *) printf 'error: --confirm does not apply to %s\n' "$mode" >&2; exit 2 ;;
                esac ;;
            --force)
                case $mode in
                    run|restore) CB_FORCE=1 ;;
                    *) printf 'error: --force does not apply to %s\n' "$mode" >&2; exit 2 ;;
                esac ;;
            -*) printf 'error: unknown flag: %s\n' "$1" >&2; exit 2 ;;
            *)  operands+=("$1") ;;
        esac
        shift
    done

    # Before the dependency checks below, which call fail(): without this a
    # run that cannot find jq left LAST_RESULT=ok while every timer firing
    # failed. Not for --dry-run, which must no more write state than it writes
    # an archive.
    [[ $mode == run && $CB_DRY_RUN -eq 0 ]] && CB_IN_CAPTURE=1

    _cb_load_lib
    trap '_cb_unexpected $? $LINENO' ERR

    command -v curl >/dev/null 2>&1 || fail "curl not found"
    command -v jq   >/dev/null 2>&1 || fail "jq not found"
    command -v tar  >/dev/null 2>&1 || fail "tar not found"
    command -v gzip >/dev/null 2>&1 || fail "gzip not found"

    _cb_read_conf

    case $mode in
        test)
            discord_notify "$DISCORD_WEBHOOK" "$DISCORD_INFO" \
                "pve-toolbox test notification" \
                "config-backup is configured on *$HOST_SHORT*." \
                Host     "$HOST_SHORT" \
                Archives "$CB_ARCHIVE_DIR" \
                || fail "could not deliver the test notification - check DISCORD_WEBHOOK in $CB_CONF"
            exit 0 ;;
        list) _cb_list ;;
        log)  _cb_git_log ;;
        run)  _cb_run ;;
        inspect)  _cb_inspect  "${operands[0]:-}" ;;
        diff)     _cb_diff     "${operands[0]:-}" "${operands[1]:-}" ;;
        restore)  _cb_restore  "${operands[0]:-}" "${operands[1]:-}" ;;
        rollback) _cb_rollback ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
