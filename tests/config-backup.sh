#!/usr/bin/env bash
#
# Tests for the config-backup collector: classification, the secret gate and
# the content hash.
#
# Only the pure helpers in the runner are called, never module_install - that
# wants root, systemd and a real PVE host. The runner is sourced rather than
# executed, which is what the guard on its last line is for, and the fixture
# stands in for /etc/pve and / through CB_PVE_DIR and CB_ROOT_DIR.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

WORK=$(mktemp -d)
RUNNER="$ROOT/modules/config-backup/pve-config-backup.sh"
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# Nothing may reach the host: these are every path the runner writes to.
export CB_ARCHIVE_DIR="$WORK/archives"
export CB_STATE_FILE="$WORK/state"
export CB_LOCK_DIR="$WORK/lock"
export CB_CONF=/dev/null

# The runner sources discord.sh only from main, so this needs no lib at all.
# shellcheck source=modules/config-backup/pve-config-backup.sh
source "$ROOT/modules/config-backup/pve-config-backup.sh"

# --- the fixture ------------------------------------------------------------

FIX=$(mktemp -d "$WORK/fixXXXXXX")
mkdir -p "$FIX/pve"/{qemu-server,lxc,firewall,priv,sdn,ha,mapping,nodes/pve1}
mkdir -p "$FIX/root/etc"/{network/interfaces.d,iptables,apt/sources.list.d} \
         "$FIX/root/etc"/{modprobe.d,ssh/sshd_config.d,cron.d,default,systemd/system}

printf 'name: test\nmemory: 2048\n'          > "$FIX/pve/qemu-server/100.conf"
printf 'arch: amd64\nhostname: ct1\n'        > "$FIX/pve/lxc/200.conf"
printf 'dir: local\n\tpath /var/lib/vz\n'    > "$FIX/pve/storage.cfg"
printf 'keyboard: en-us\n'                   > "$FIX/pve/datacenter.cfg"
# A realistic user.cfg: PVE records API tokens here as a `token:` record.
# The old fixture had only a user line, which is why the scan's false positive
# on this file went unnoticed until it aborted every run on a real host.
printf 'user:root@pam:1:0:::::\ntoken:root@pam!grafana:0:0::monitoring:\ngroup:admins:root@pam::\n' > "$FIX/pve/user.cfg"
printf '[OPTIONS]\nenable: 1\n'              > "$FIX/pve/firewall/cluster.fw"
printf 'totem { cluster_name: cl }\n'        > "$FIX/pve/corosync.conf"
printf 'auto vmbr0\niface vmbr0 inet static\n' > "$FIX/root/etc/network/interfaces"
printf '*filter\n:INPUT ACCEPT\nCOMMIT\n'    > "$FIX/root/etc/iptables/rules.v4"
printf 'deb https://deb.debian.org/debian trixie main\n' > "$FIX/root/etc/apt/sources.list"
printf 'options vfio-pci ids=10de:1234\n'    > "$FIX/root/etc/modprobe.d/vfio.conf"
printf 'UUID=abc / ext4 defaults 0 1\n'      > "$FIX/root/etc/fstab"
printf 'pve1\n'                              > "$FIX/root/etc/hostname"
printf 'GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on"\n' > "$FIX/root/etc/default/grub"
printf 'PermitRootLogin yes\n'               > "$FIX/root/etc/ssh/sshd_config"
printf '[Unit]\nDescription=mine\n'          > "$FIX/root/etc/systemd/system/mine.service"

export CB_PVE_DIR="$FIX/pve" CB_ROOT_DIR="$FIX/root"

# Stage the fixture without the derived dumps: those read the machine the test
# runs on, so a hash over them would assert on the host rather than the code.
# Sets CB_STAGE rather than printing it: the collectors write into $CB_STAGE,
# so a command substitution would stage into a subshell the caller cannot see.
stage_fixture() {
    CB_STAGE=$(mktemp -d "$WORK/stageXXXXXX")
    _cb_collect_pmxcfs
    _cb_collect_host
    _cb_collect_meta
}

# --- 1. every path lands in exactly one restore class -----------------------

class_is() { # class_is <relative-path> <expected>
    local got
    got=$(_cb_classify "$1") || true
    [[ $got == "$2" ]] || fail "_cb_classify '$1' returned $got, wanted $2"
}

class_is "pve/qemu-server/100.conf"          guest
class_is "pve/lxc/200.conf"                  guest
class_is "pve/storage.cfg"                   pmxcfs
class_is "pve/datacenter.cfg"                pmxcfs
class_is "pve/user.cfg"                      pmxcfs
class_is "pve/firewall/cluster.fw"           pmxcfs
class_is "pve/sdn/zones.cfg"                 pmxcfs
class_is "host/etc/network/interfaces"       dropin
class_is "host/etc/iptables/rules.v4"        dropin
class_is "host/etc/apt/sources.list"         dropin
class_is "host/etc/modprobe.d/vfio.conf"     dropin
class_is "host/etc/fstab"                    dropin
class_is "host/etc/default/grub"             dropin
class_is "host/etc/systemd/system/mine.service" dropin
class_is "derived/lsblk.txt"                 reference
class_is "resolved/qemu-100.conf"            reference
class_is "firewall-live/iptables.rules"      reference

# Cluster identity and keys are hard-blocked, and the never-restore entries
# lead the table so a broader glob below cannot claim them back.
class_is "pve/corosync.conf"                 never
class_is "pve/priv/authkey.key"              never
class_is "pve/nodes/pve1/pve-ssl.pem"        never
class_is "pve/nodes/pve1/pve-ssl.key"        never
class_is "host/etc/ssh/ssh_host_rsa_key"     never
# CB_INCLUDE_SECRETS writes encrypted copies here; without a class of
# their own they would fail the manifest's own completeness check.
class_is "secrets/pve/priv/authkey.key.age"  never

# A path the table does not cover has to say so rather than guess.
if _cb_classify "nope/whatever" >/dev/null 2>&1; then
    fail "_cb_classify accepted an unknown path"
fi
[[ $(_cb_classify "nope/whatever" || true) == unclassified ]] \
    || fail "_cb_classify did not report unclassified"
pass "restore classes"

# The claim that capture and restore share one table is only true if something
# checks it, so assert it over the whole staged tree rather than a sample.
stage_fixture; stage=$CB_STAGE
_cb_drop_secrets
manifest="$WORK/manifest"
_cb_manifest "$stage" "$manifest" || fail "some staged paths have no restore class"
[[ -s $manifest ]] || fail "the manifest is empty"
awk -F'\t' 'NF != 4 { exit 1 }' "$manifest" || fail "the manifest is not four tab-separated columns"
[[ $(awk -F'\t' '$2 == "unclassified"' "$manifest" | wc -l) -eq 0 ]] \
    || fail "the manifest contains unclassified paths"
pass "every staged path is classified"

# --- 2. the secret gate --------------------------------------------------

# /etc/pve/priv is dropped before anything scans, so a key there never reaches
# the archive and never trips the scan either.
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n' > "$FIX/pve/priv/authkey.key"
stage_fixture; stage=$CB_STAGE
# With secrets disabled - the default, and the only mode most hosts use - the
# cluster's key material must never be staged at all. Copying it to $TMPDIR
# and unlinking it again is an unnecessary daily cleartext copy of the most
# sensitive thing on the host, outside pmxcfs, for no benefit.
[[ -e $stage/pve/priv ]] && fail "priv/ was staged even though CB_INCLUDE_SECRETS is off"
_cb_drop_secrets
_cb_secret_scan >/dev/null || fail "the scan flagged a tree with nothing left in it"
pass "priv/ is never staged when secrets are disabled"

# _cb_drop_secrets stays as the belt-and-braces pass for anything key-shaped
# that reaches the stage by another route.
stage_fixture; stage=$CB_STAGE
mkdir -p "$stage/pve/priv"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n' > "$stage/pve/priv/authkey.key"
_cb_drop_secrets
[[ -e $stage/pve/priv/authkey.key ]] && fail "a key under priv/ survived _cb_drop_secrets"
pass "priv/ is dropped if it reaches the stage anyway"

# A key somewhere the drop list does not cover has to stop the run. The
# pattern starts with a dash, so a scan that passes it to grep without -e
# exits 2 and reads as clean - assert on the named path, not just on failure.
stage_fixture; stage=$CB_STAGE
_cb_drop_secrets
printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIabc\n' > "$stage/pve/sdn/leaked.conf"
if hits=$(_cb_secret_scan); then
    fail "the secret scan passed a tree with a private key in it"
fi
[[ $hits == *"pve/sdn/leaked.conf private-key"* ]] \
    || fail "the scan did not name the offending path and pattern: $hits"

printf 'Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz012345\n' > "$stage/host/etc/cron.d/leak"
hits=$(_cb_secret_scan) && fail "the secret scan passed a bearer token"
[[ $hits == *"host/etc/cron.d/leak bearer"* ]] || fail "the bearer pattern did not fire: $hits"

# An allow-listed path is the operator saying "I looked, it is fine".
CB_SECRET_ALLOW='pve/user.cfg pve/sdn/leaked.conf host/etc/cron.d/leak'
_cb_secret_scan >/dev/null || fail "the allow-list did not suppress a known hit"
CB_SECRET_ALLOW=''
pass "secret scan"

# --- 3. the content hash is stable --------------------------------------

# The hash is taken off the manifest, so that is how the test computes it too.
hash_of() { # hash_of <staged dir>
    local m; m=$(mktemp "$WORK/mfXXXXXX")
    _cb_manifest "$1" "$m"
    _cb_hash_of "$m"
}

stage_fixture; a=$CB_STAGE; _cb_drop_secrets; ha=$(hash_of "$a")
stage_fixture; b=$CB_STAGE; _cb_drop_secrets; hb=$(hash_of "$b")
[[ $ha == "$hb" ]] || fail "two captures of an unchanged fixture hashed differently"

# mtime is not content: touching a file must not look like a change, or a
# capture would write a new archive every run for no reason.
touch "$b/pve/storage.cfg"
[[ $(hash_of "$b") == "$ha" ]] || fail "an mtime change moved the content hash"

printf 'extra: 1\n' >> "$b/pve/storage.cfg"
[[ $(hash_of "$b") != "$ha" ]] || fail "a content change did not move the hash"

mv "$b/pve/storage.cfg" "$b/pve/renamed.cfg"
hc=$(hash_of "$b")
mv "$b/pve/renamed.cfg" "$b/pve/storage.cfg"
[[ $hc != $(hash_of "$b") ]] || fail "a rename did not move the hash"

# A symlink is archived by tar, so it has to be classified and hashed like
# anything else - otherwise "every captured path has exactly one class" holds
# only because nothing but regular files was ever looked at.
ln -s storage.cfg "$b/pve/link.cfg"
[[ $(hash_of "$b") != "$ha" ]] || fail "adding a symlink did not move the hash"
rm -f "$b/pve/link.cfg"

# The load-bearing exclusion. `pvesh get /cluster/resources` reports live cpu
# and memory per guest, and iptables-save on a Docker host is rewritten by
# every container start. Both are reference-class, both are kept in the
# archive, and neither may count as a configuration change - or a scheduled
# capture writes an archive every single run and never settles.
mkdir -p "$b/derived" "$b/firewall-live"
printf '[{"id":"qemu/100","cpu":0.01,"uptime":42}]\n' > "$b/derived/cluster-resources.json"
printf '*filter\n-A DOCKER -d 172.17.0.4/32\n' > "$b/firewall-live/iptables.rules"
hd=$(hash_of "$b")
printf '[{"id":"qemu/100","cpu":0.97,"uptime":98765}]\n' > "$b/derived/cluster-resources.json"
printf '*filter\n-A DOCKER -d 172.17.0.9/32\n' > "$b/firewall-live/iptables.rules"
[[ $(hash_of "$b") == "$hd" ]] || fail "live reference data moved the content hash"

# ...but they are still in the manifest, so they are still in the archive.
m=$(mktemp "$WORK/mfXXXXXX"); _cb_manifest "$b" "$m"
grep -q '^derived/cluster-resources.json' "$m" \
    || fail "reference data was excluded from the archive, not just from the hash"
pass "content hash"

# --- 3b. the defects the first review round found -------------------------

# A real user.cfg records API tokens as `token:root@pam!name:...`. That is a
# record type, not a credential - the secret lives in priv/token.cfg, which is
# dropped before the scan runs. Matching it aborted every run on any host with
# a Grafana, Terraform or PBS integration: the module wrote no backups at all.
stage_fixture; _cb_drop_secrets
CB_SECRET_ALLOW='pve/user.cfg derived/dpkg-selections.txt'   # the shipped default
_cb_secret_scan >/dev/null \
    || fail "a user.cfg with an API token aborted the scan"
pass "an API token in user.cfg is not a credential"

# Multiarch dpkg emits `passwd:arm64  install`, so the package named passwd
# reads as `passwd:<value>` to the credential pattern. This is a file the
# capture deliberately archives, and it broke every CI run on debian.
stage_fixture; _cb_drop_secrets
mkdir -p "$CB_STAGE/derived"
printf 'passwd:arm64\t\tinstall\nlibc6:arm64\t\tinstall\n' > "$CB_STAGE/derived/dpkg-selections.txt"
CB_SECRET_ALLOW='pve/user.cfg derived/dpkg-selections.txt'
_cb_secret_scan >/dev/null || fail "a multiarch dpkg selections list aborted the scan"
pass "a multiarch package list is not a credential"

# ...but a real credential in the same file still has to be caught.
printf 'password: hunter2trustno1\n' >> "$CB_STAGE/pve/datacenter.cfg"
_cb_secret_scan >/dev/null && fail "a real password was not caught"
pass "a real credential is still caught"

# -I skips any file containing a NUL byte, so a key hidden in one was never
# scanned. A gate that declines to open a file has not checked it.
stage_fixture; _cb_drop_secrets
printf -- '-----BEGIN RSA PRIVATE KEY-----\nAAAA\0BBBB\n' > "$CB_STAGE/pve/sdn/binary.bin"
hits=$(_cb_secret_scan) && fail "a key inside a binary file was not scanned"
[[ $hits == *"binary.bin private-key"* ]] || fail "the binary file was not named: $hits"
pass "the scan reads binary files too"

# pve-ha-lrm and pve-ha-crm rewrite these with a timestamp on their watchdog
# interval. Classified pmxcfs they sат inside the hash, so any host running HA
# wrote a fresh archive every single run and the retention floor filled with
# identical snapshots.
class_is "pve/ha/manager_status"      reference
class_is "pve/nodes/pve1/lrm_status"  reference
stage_fixture; _cb_drop_secrets
mkdir -p "$CB_STAGE/pve/ha" "$CB_STAGE/pve/nodes/pve1"
printf '{"timestamp":1}\n'   > "$CB_STAGE/pve/ha/manager_status"
printf '{"timestamp":1}\n'   > "$CB_STAGE/pve/nodes/pve1/lrm_status"
h1=$(hash_of "$CB_STAGE")
printf '{"timestamp":999}\n' > "$CB_STAGE/pve/ha/manager_status"
printf '{"timestamp":999}\n' > "$CB_STAGE/pve/nodes/pve1/lrm_status"
[[ $(hash_of "$CB_STAGE") == "$h1" ]] || fail "live HA status churn moved the content hash"
pass "HA status files are state, not configuration"

# A capture that could not read a source used to report ok, and every later
# phase restores from that archive.
stage_fixture
CB_TAKE_ERRORS=0
_cb_take /nonexistent/definitely-not-here "pve/nope.cfg"
[[ $CB_TAKE_ERRORS -eq 0 ]] || fail "an absent source counted as a failure"
if [[ $EUID -ne 0 ]]; then
    unreadable="$WORK/unreadable.cfg"; printf 'x\n' > "$unreadable"; chmod 000 "$unreadable"
    _cb_take "$unreadable" "pve/unreadable.cfg"
    chmod 644 "$unreadable"
    [[ $CB_TAKE_ERRORS -eq 1 ]] || fail "an unreadable source was silently dropped"
    pass "an unreadable source is counted, not swallowed"
else
    printf 'skip unreadable-source case, running as root\n'
fi

# The three refusal gates, driven through the runner rather than its helpers.
# They fail closed - a mistake in one stops every host backing up - so they are
# the highest-value thing to pin, and none of them had a test.
gate_fixture() { # gate_fixture -> a live-ish tree in GDIR
    GDIR=$(mktemp -d "$WORK/gateXXXXXX")
    mkdir -p "$GDIR/pve"/{qemu-server,nodes/pve1} "$GDIR/root/etc"
    printf 'name: t\n' > "$GDIR/pve/qemu-server/100.conf"
    printf 'k: v\n'    > "$GDIR/pve/datacenter.cfg"
}
gate_run() { # gate_run <args...> -> runs the real runner against GDIR
    CB_PVE_DIR="$GDIR/pve" CB_ROOT_DIR="$GDIR/root" CB_ARCHIVE_DIR="$GDIR/ar" \
    CB_STATE_FILE="$GDIR/state" CB_CONF=/dev/null CB_LOCK_DIR="$GDIR" \
    PVE_TOOLBOX_LIB="$ROOT/lib" "$RUNNER" "$@"
}

# The runner hard-requires jq, so without it every gate below reads as a
# refusal rather than as the missing dependency it is.
if ! command -v jq >/dev/null 2>&1; then
    printf 'skip the end-to-end gate tests, no jq\n'
else
gate_fixture
# Capture the reason: "a healthy capture was refused" on its own told CI
# nothing, and the cause was a secret-scan false positive on a file the
# capture archives by design.
if ! gate_out=$(gate_run run 2>&1); then
    fail "a healthy capture was refused: $gate_out"
fi
[[ $(find "$GDIR/ar" -name '*.tar.gz' | wc -l) -eq 1 ]] || fail "no archive from a healthy capture"
pass "a healthy capture passes every gate"

# An empty /etc/pve means pmxcfs is down. Writing a successful empty archive
# let thirty of them evict every good one from the retention floor.
gate_fixture; rm -rf "${GDIR:?}/pve"; mkdir -p "$GDIR/pve"
gate_run run >/dev/null 2>&1 && fail "a capture with no nodes/ was accepted"
[[ $(find "$GDIR/ar" -name '*.tar.gz' 2>/dev/null | wc -l) -eq 0 ]] \
    || fail "an archive was written despite the nodes/ gate"
pass "an empty /etc/pve is refused"

if [[ $EUID -ne 0 ]]; then
    gate_fixture
    mkdir -p "$GDIR/root/etc/systemd/system"
    printf '[Unit]\n' > "$GDIR/root/etc/systemd/system/critical.service"
    chmod 000 "$GDIR/root/etc/systemd/system/critical.service"
    gate_run run >/dev/null 2>&1 && fail "a capture that could not read a custom unit succeeded"
    chmod 644 "$GDIR/root/etc/systemd/system/critical.service"
    pass "an unreadable custom unit fails the capture"
fi

# A run that cannot find its dependencies has to record the failure, or the
# status line reports health while every timer firing fails. A PATH holding
# everything except jq, rather than an empty one, so the runner gets far enough
# to reach the check being tested.
gate_fixture
shimpath=$(mktemp -d "$WORK/pathXXXXXX")
for b in $(compgen -c 2>/dev/null | sort -u); do :; done
for d in /usr/bin /bin /usr/sbin /sbin; do
    [[ -d $d ]] || continue
    for f in "$d"/*; do
        [[ -x $f && ! -d $f ]] || continue
        [[ $(basename "$f") == jq ]] && continue
        ln -sf "$f" "$shimpath/$(basename "$f")" 2>/dev/null || true
    done
done
if [[ -x $shimpath/tar && ! -e $shimpath/jq ]]; then
    ( PATH="$shimpath" gate_run run ) >/dev/null 2>&1 || true
    grep -q '^LAST_RESULT=failed' "$GDIR/state" 2>/dev/null \
        || fail "a run that failed its dependency checks did not record it"
    pass "a failed run records the failure"
else
    printf 'skip dependency-failure case, could not build a jq-less PATH\n'
fi

# ...but --dry-run must no more write state than it writes an archive.
gate_fixture
gate_run run >/dev/null 2>&1
before=$(grep '^LAST_RESULT=' "$GDIR/state")
chmod 000 "$GDIR/pve/datacenter.cfg" 2>/dev/null || true
( gate_run run --dry-run ) >/dev/null 2>&1 || true
chmod 644 "$GDIR/pve/datacenter.cfg" 2>/dev/null || true
[[ $(grep '^LAST_RESULT=' "$GDIR/state") == "$before" ]] \
    || fail "--dry-run overwrote the recorded result of a real capture"
pass "--dry-run writes no state"
fi

# --- 4. retention: count is a floor, not a cap --------------------------

NOW=1000000000
at() { printf '%s' $(( NOW - $1 * 86400 )); }        # at <days ago> -> epoch
AGED=("a:$(at 1)" "b:$(at 40)" "c:$(at 100)" "d:$(at 200)" "e:$(at 300)")

prunes() { # prunes <count> <days> <expected space separated>
    local got
    got=$(_cb_prune_list "$1" "$2" "$NOW" "${AGED[@]}" | tr '\n' ' ')
    got=${got% }
    [[ $got == "$3" ]] || fail "_cb_prune_list $1 $2 deleted '$got', wanted '$3'"
}

prunes 2 90 "c d e"     # beyond the floor and older than 90d
prunes 5 90 ""          # the floor covers every archive there is
prunes 0 90 "c d e"     # no floor, pure age
prunes 2 0  ""          # 0 days means unlimited
prunes 0 0  ""          # both unlimited: nothing is ever pruned
# b is 40 days old and outside the newest 2, and still survives: count is a
# floor under the age rule, not a cap on how many archives may exist.
prunes 1 90 "c d e"
pass "retention"

# --- 5. the archive is reproducible -------------------------------------

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    stage_fixture; a=$CB_STAGE; _cb_drop_secrets
    one=$(tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
              -C "$a" -cf - . | gzip -n -9 | sha256sum | awk '{print $1}')
    touch "$a/pve/storage.cfg" "$a/host/etc/fstab"
    two=$(tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
              -C "$a" -cf - . | gzip -n -9 | sha256sum | awk '{print $1}')
    [[ $one == "$two" ]] || fail "the same tree produced two different archives"
    pass "reproducible archive"
else
    printf 'skip reproducible archive, not GNU tar\n'
fi

# --- 6. --help does not need the lib ------------------------------------

# Both existing runners source discord.sh at the top, so --help dies on a host
# where the lib was never installed. This one parses arguments first.
out=$(PVE_TOOLBOX_LIB=/nonexistent "$ROOT/modules/config-backup/pve-config-backup.sh" --help) \
    || fail "--help failed without the shared lib installed"
[[ $out == *"pve-config-backup run"* ]] || fail "--help printed no usage: $out"
[[ $out != *"#"* ]] || fail "--help leaked the comment markers"
pass "--help without the lib"
