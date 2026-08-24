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

# ------------------------------------------------------------------ run --

_cb_lock() {
    local dir=$CB_LOCK_DIR
    mkdir -p "$dir" 2>/dev/null || dir=/tmp
    chmod 0700 "$dir" 2>/dev/null || true
    exec 9>"$dir/pve-config-backup.lock"
    if ! flock -n 9; then
        log "a capture is already running - leaving it alone"
        exit 0
    fi
}

_cb_run() {
    # Reset, not just initialise: the counter is a global, and a second capture
    # in one process would otherwise inherit the first one's failures and
    # refuse a perfectly clean tree.
    CB_TAKE_ERRORS=0
    _cb_lock

    CB_STAGE=$(mktemp -d)
    CB_MANIFEST=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -rf '$CB_STAGE' '$CB_MANIFEST'" EXIT

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

    if [[ $CB_NOTIFY_ON_CHANGE -eq 1 ]]; then
        discord_notify "$DISCORD_WEBHOOK" "$DISCORD_OK" \
            "PVE config changed - $HOST_SHORT" \
            "The configuration changed since the last run and a new snapshot was written." \
            Host     "$HOST_SHORT" \
            Archive  "$name" \
            Files    "$files" \
            Size     "$bytes bytes" \
            Hash     "${hash:0:12}" \
            Took     "$took" || true
    fi
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
}

main() {
    local mode=""
    case ${1:-} in
        -h|--help)    usage; exit 0 ;;
        --test)       mode='test'; shift ;;
        run)          mode='run';  shift ;;
        list)         mode='list'; shift ;;
        "")           usage >&2; exit 2 ;;
        *)            printf 'error: unknown command: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac

    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run|--force)
                [[ $mode == run ]] \
                    || { printf 'error: %s only applies to run\n' "$1" >&2; exit 2; }
                [[ $1 == --dry-run ]] && CB_DRY_RUN=1 || CB_FORCE=1 ;;
            *) printf 'error: unknown flag: %s\n' "$1" >&2; exit 2 ;;
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
        run)  _cb_run ;;
    esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
