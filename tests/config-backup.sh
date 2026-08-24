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
# GNU stat on the target, BSD stat on the machine this is often written on.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
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
CB_SECRET_ALLOW='pve/user.cfg'   # the shipped default
_cb_secret_scan >/dev/null \
    || fail "a user.cfg with an API token aborted the scan"
pass "an API token in user.cfg is not a credential"

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
gate_run run >/dev/null 2>&1 || fail "a healthy capture was refused"
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

# --- 7. the git backend --------------------------------------------------

# The one assertion that does not need git installed: no force-push, ever.
# A behavioural test proves nothing here - stock `git push` already refuses a
# non-fast-forward, so an outcome test passes with zero divergence logic in the
# runner, and keeps passing if someone later reaches for --force-with-lease to
# silence a complaint. Grepping the source fails on the code change itself.
RUNNER="$ROOT/modules/config-backup/pve-config-backup.sh"
if grep -nE 'git[^|]*push' "$RUNNER" | grep -qE '\-\-force|--force-with-lease|[[:space:]]-f[[:space:]]'; then
    fail "the runner force-pushes: a rejected push is the correct outcome when someone else wrote to the branch"
fi
pass "no force-push in the source"

if ! command -v git >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
    printf 'skip git backend tests, no git or rsync\n'
    exit 0
fi

export CB_GIT_ENABLED=1
export CB_GIT_BRANCH=master
export CB_GIT_AUTHOR_NAME=test
export CB_GIT_AUTHOR_EMAIL=test@example.invalid

# An embedded credential defeats the whole point of CB_GIT_TOKEN_FILE: git
# writes it into .git/config and puts it in every argv.
cred_is() { # cred_is <url> <yes|no>
    local got=no
    _cb_git_remote_has_credential "$1" && got=yes
    [[ $got == "$2" ]] || fail "_cb_git_remote_has_credential '$1' returned $got, wanted $2"
}
cred_is 'https://tok:x@github.com/a/b.git'  yes
cred_is 'https://user:pass@example.com/r'   yes
# The colon-requiring form missed these - and a bare token is how GitHub and
# GitLab document embedding a PAT, i.e. the exact case the docs claimed was
# refused. It lands verbatim in .git/config and is re-applied every run.
cred_is 'https://ghp_AAAABBBBCCCCDDDD@github.com/a/b.git' yes
cred_is 'https://glpat-XXXXXXXXXXXX@gitlab.com/a/b.git'   yes
cred_is 'https://github.com/a/b.git'        no
cred_is 'git@github.com:a/b.git'            no
cred_is 'ssh://git@host/repo.git'           no
pass "remote credential detection"

# The helper has to speak the git-credential protocol. One that merely cats the
# file is not a helper: git wants username= and password= lines back, and
# without them either fails auth or falls through to prompting - which on a
# timer with no stdin is a hang, not an error.
TOKFILE="$WORK/token"; printf 'ghp_TESTTOKENVALUE\n' > "$TOKFILE"; chmod 600 "$TOKFILE"
CB_GIT_TOKEN_FILE="$TOKFILE"
helper=$(_cb_git_credential_helper)
[[ $helper != *ghp_TESTTOKENVALUE* ]] \
    || fail "the token value is in the helper string, so it would show up in ps"
[[ $helper == *"$TOKFILE"* ]] || fail "the helper does not reference the token file"
out=$(eval "${helper#!}" <<<'protocol=https
host=github.com
' 2>/dev/null || true)
[[ $out == *"username="* ]] || fail "the helper emits no username= line: $out"
[[ $out == *"password=ghp_TESTTOKENVALUE"* ]] || fail "the helper emits no password= line: $out"
CB_GIT_TOKEN_FILE=""
pass "credential helper speaks the git protocol"

# What reaches git: not the regenerated dumps, not the secrets, not whatever
# the operator declared volatile.
stage_fixture; gstage=$CB_STAGE; _cb_drop_secrets
mkdir -p "$gstage/derived" "$gstage/firewall-live" "$gstage/secrets"
printf 'pve 9.2\n'  > "$gstage/derived/pveversion.txt"
printf 'live\n'     > "$gstage/firewall-live/iptables.rules"
printf 'enc\n'      > "$gstage/secrets/leaked.age"
gman="$WORK/gman"; _cb_manifest "$gstage" "$gman"
inc=$(_cb_git_include "$gman")
grep -q '^pve/storage.cfg$'  <<<"$inc" || fail "git include dropped a real config path"
grep -q 'derived/'           <<<"$inc" && fail "a reference dump reached the git tree"
grep -q 'firewall-live/'     <<<"$inc" && fail "live firewall state reached the git tree"
grep -q 'secrets/'           <<<"$inc" && fail "an encrypted secret reached the git tree"
grep -q 'resolved/'          <<<"$inc" && fail "a resolved guest view reached the git tree"
pass "git include set"

# Commit only on change, and a change confined to a reference path is not one.
export CB_GIT_DIR="$WORK/repo"
export CB_GIT_REMOTE="" CB_GIT_PUSH=0
_cb_git_sync "$gstage" "$gman" deadbeefcafe
[[ -d $CB_GIT_DIR/.git ]] || fail "no repository was created"
count_commits() { git -C "$CB_GIT_DIR" rev-list --count HEAD 2>/dev/null || printf '0'; }
[[ $(count_commits) == 1 ]] || fail "the first sync did not commit"

_cb_git_sync "$gstage" "$gman" deadbeefcafe
[[ $(count_commits) == 1 ]] || fail "an unchanged tree committed a second time"

# A reference path moving must not produce a commit - this is the case that
# distinguishes "excluded because reference" from "excluded because volatile",
# which the firewall-live case alone cannot.
printf 'pve 9.3\n' > "$gstage/derived/pveversion.txt"
_cb_manifest "$gstage" "$gman"
_cb_git_sync "$gstage" "$gman" deadbeefcafe
[[ $(count_commits) == 1 ]] || fail "a reference-only change produced a commit"

printf 'balloon: 0\n' >> "$gstage/pve/qemu-server/100.conf"
_cb_manifest "$gstage" "$gman"
_cb_git_sync "$gstage" "$gman" feedfacefeed
[[ $(count_commits) == 2 ]] || fail "a real config change did not commit"
pass "commit only on change"

# rsync --delete runs against a directory that holds the repository, and the
# attributes file is not in the staged tree - so if it were tracked rather than
# under .git/, the first sync would delete it and the -diff rule would quietly
# stop applying.
[[ -d $CB_GIT_DIR/.git ]] || fail ".git did not survive the syncs"
[[ -f $CB_GIT_DIR/.git/info/attributes ]] || fail ".git/info/attributes did not survive the syncs"
pass "repository survives --delete"

# The work tree holds the same configuration as the 0600 archives. rsync -a
# would otherwise carry the source's own modes straight through.
[[ $(mode_of "$CB_GIT_DIR") == 700 ]] || fail "the git dir is $(mode_of "$CB_GIT_DIR"), wanted 700"
while IFS= read -r f; do
    m=$(mode_of "$f")
    [[ $m == 600 ]] || fail "$f is mode $m, wanted 600"
done < <(find "$CB_GIT_DIR" -path "$CB_GIT_DIR/.git" -prune -o -type f -print)
pass "git work tree permissions"

# A repository with no commits is a real state, and every git call that reports
# it exits non-zero - which the ERR trap would turn into a spurious failure
# alert if any of them were called bare.
export CB_GIT_DIR="$WORK/empty"
install -d -m 0700 "$CB_GIT_DIR"
git init -q -b master "$CB_GIT_DIR"
( set -Eeuo pipefail; _cb_git_state ) || fail "_cb_git_state tripped on a zero-commit repo"
[[ $(_cb_state_get GIT_COMMITS) == 0 ]] || fail "a zero-commit repo did not report 0 commits"
pass "zero-commit repository"

# Divergence: commit locally, leave the remote exactly as it was.
export CB_GIT_DIR="$WORK/pushrepo"
REMOTE="$WORK/remote.git"; git init -q --bare "$REMOTE"
export CB_GIT_REMOTE="$REMOTE" CB_GIT_PUSH=1
_cb_manifest "$gstage" "$gman"
_cb_git_sync "$gstage" "$gman" aaaabbbbcccc
[[ $(git -C "$REMOTE" rev-list --count master) == 1 ]] || fail "the first push did not land"

git clone -q -b master "$REMOTE" "$WORK/other"
git -C "$WORK/other" -c user.name=o -c user.email=o@e commit -q --allow-empty -m "another writer"
git -C "$WORK/other" push -q origin master
before=$(git -C "$REMOTE" rev-parse master)

printf 'onboot: 1\n' >> "$gstage/pve/qemu-server/100.conf"
_cb_manifest "$gstage" "$gman"
_cb_git_sync "$gstage" "$gman" ddddeeeeffff
after=$(git -C "$REMOTE" rev-parse master)
[[ $before == "$after" ]] || fail "a diverged remote was overwritten"
[[ $(_cb_state_get GIT_PUSH_STATE) == diverged ]] \
    || fail "divergence was not recorded: $(_cb_state_get GIT_PUSH_STATE)"
[[ $(git -C "$CB_GIT_DIR" rev-list --count HEAD) == 2 ]] \
    || fail "the local commit was lost when the push was refused"
pass "diverged remote is left alone"

# A branch name is passed to git as a *refspec*, so `+master` is a force push:
# ls-remote matches nothing, the code takes the first-push path, never fetches,
# and the divergence check never runs. The source-grep guard cannot see this,
# because `--force` never appears in it. Assert on the remote's tip instead.
FORCEREPO="$WORK/forcerepo"; FORCEREMOTE="$WORK/forceremote.git"
git init -q --bare "$FORCEREMOTE"
export CB_GIT_DIR="$FORCEREPO" CB_GIT_REMOTE="$FORCEREMOTE" CB_GIT_PUSH=1 CB_GIT_BRANCH=master
_cb_manifest "$gstage" "$gman"
_cb_git_sync "$gstage" "$gman" 111122223333
git clone -q -b master "$FORCEREMOTE" "$WORK/forceother"
git -C "$WORK/forceother" -c user.name=o -c user.email=o@e commit -q --allow-empty -m "another writer"
git -C "$WORK/forceother" push -q origin master
tip_before=$(git -C "$FORCEREMOTE" rev-parse master)

CB_GIT_BRANCH='+master'
printf 'hotplug: disk\n' >> "$gstage/pve/qemu-server/100.conf"
_cb_manifest "$gstage" "$gman"
_cb_git_sync "$gstage" "$gman" 444455556666 2>/dev/null || true
[[ $(git -C "$FORCEREMOTE" rev-parse master) == "$tip_before" ]] \
    || fail "a '+branch' name force-pushed and destroyed the remote's history"
CB_GIT_BRANCH=master
pass "a branch name cannot smuggle in a force push"

# The token must not end up persisted anywhere in the repository.
grep -rq 'ghp_TESTTOKENVALUE' "$CB_GIT_DIR/.git/config" 2>/dev/null \
    && fail "a token was written into .git/config"
pass "no credential in .git/config"

# --- 8. restore ------------------------------------------------------------

# A live tree to restore onto, separate from the capture fixture so a mistake
# here cannot quietly pass by restoring a file onto itself.
LIVE=$(mktemp -d "$WORK/liveXXXXXX")
cp -a "$FIX/." "$LIVE/"
export CB_PVE_DIR="$LIVE/pve" CB_ROOT_DIR="$LIVE/root"
export CB_ARCHIVE_DIR="$WORK/rar" CB_STATE_FILE="$WORK/rstate"
export CB_GIT_ENABLED=0
CB_CONFIRM=0; CB_SELECTOR=""

tree_hash() { # tree_hash <dir> -> everything, including modes and absences
    ( cd "$1" && find . \( -type f -o -type l \) ! -name '*.bak.*' -printf '%m %p\n' \
        | LC_ALL=C sort
      cd "$1" && find . -type f ! -name '*.bak.*' -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) | sha256sum | awk '{print $1}'
}

_cb_capture_once >/dev/null
BASE=$(_cb_state_get LAST_ARCHIVE)
[[ -n $BASE ]] || fail "no baseline archive was produced"

# Mutate the live host so a restore has something to do.
printf 'MUTATED\n' >> "$LIVE/pve/qemu-server/100.conf"
rm -f "$LIVE/pve/datacenter.cfg"
MUTATED=$(tree_hash "$LIVE")

# A dry run is the default, and it has to write nothing at all.
CB_CONFIRM=0
_cb_restore "$BASE" >/dev/null
[[ $(tree_hash "$LIVE") == "$MUTATED" ]] || fail "a dry run modified the host"
pass "restore is dry-run by default"

# Apply, then check both directions of the change landed.
CB_CONFIRM=1
_cb_restore "$BASE" >/dev/null
grep -q MUTATED "$LIVE/pve/qemu-server/100.conf" && fail "a differing file was not restored"
[[ -f $LIVE/pve/datacenter.cfg ]] || fail "a missing file was not created"
[[ -n $(_cb_state_get ROLLBACK_ARCHIVE) ]] || fail "no rollback point was recorded"
[[ -z $(_cb_state_get RESTORE_IN_PROGRESS) ]] || fail "the in-progress marker was left set"
pass "restore applies"

# Non-pmxcfs writes leave a backup beside them; pmxcfs ones must not, because
# those replicate to every node and count against the cluster's own quota.
find "$LIVE/pve" -name '*.bak.*' | grep -q . && fail "a .bak file was written inside pmxcfs"
pass "no backup sidecars inside pmxcfs"

# Rollback is a sync: it has to undo the write AND delete what restore created.
CB_CONFIRM=0
_cb_rollback >/dev/null
[[ -f $LIVE/pve/datacenter.cfg ]] || fail "a rollback dry run deleted a file"
CB_CONFIRM=1
_cb_rollback >/dev/null
grep -q MUTATED "$LIVE/pve/qemu-server/100.conf" || fail "rollback did not restore the pre-restore content"
[[ -e $LIVE/pve/datacenter.cfg ]] && fail "rollback left behind a file the restore created"
[[ $(tree_hash "$LIVE") == "$MUTATED" ]] || fail "rollback did not reproduce the pre-restore tree exactly"
pass "rollback is a faithful inverse"

# These three replace tests that passed against the *unfixed* runner: one used
# a path already in the archive (so never the live-only case), one asserted on
# a file the fixture never created (so both asserts were vacuous), and one only
# exercised the happy path in a scratch directory.

# C1: a path genuinely absent from the snapshot, because the capture could not
# read it - which rollback used to read as "the restore created this".
if [[ $EUID -ne 0 ]]; then
    secretfile="$LIVE/root/etc/cron.d/unreadable-job"
    mkdir -p "$LIVE/root/etc/cron.d"
    printf '0 * * * * root /bin/true\n' > "$secretfile"; chmod 000 "$secretfile"
    # A subshell, because the runner's fail() calls exit - and this file
    # sources the runner, so an unguarded call would end the test run.
    ( _cb_capture_once ) >/dev/null 2>&1 && fail "a capture that could not read a file still succeeded"
    chmod 644 "$secretfile"
    ( _cb_capture_once ) >/dev/null 2>&1 || fail "a clean capture was refused"
    pass "an unreadable file fails the capture rather than vanishing"
fi

# C2: the archive must actually contain the path for this to mean anything -
# the previous version asserted on /etc/hosts, which the fixture never created.
printf '127.0.0.1 localhost\n' > "$LIVE/root/etc/hosts"
CB_TAKE_ERRORS=0; _cb_capture_once >/dev/null 2>&1
SYMBASE=$(_cb_state_get LAST_ARCHIVE)
[[ -n $SYMBASE ]] || fail "no archive for the symlink case"
rm -f "$LIVE/root/etc/hosts"
printf '127.0.0.1 localhost\n' > "$LIVE/root/etc/hosts.real"
ln -sfn hosts.real "$LIVE/root/etc/hosts"
CB_CONFIRM=1; CB_SELECTOR=""
_cb_restore "$SYMBASE" >/dev/null 2>&1 || true
[[ -L $LIVE/root/etc/hosts ]] \
    || fail "a live symlink was replaced by a regular file - /etc/resolv.conf is this case on a real host"
pass "a live symlink is not severed by a restore"

# The temp file must not be traversable: cp -f follows a symlink planted at a
# predictable name, writing the restored content through it.
wtmp=$(mktemp -d "$WORK/wXXXXXX"); mkdir -p "$wtmp/d"
printf 'ORIGINAL\n' > "$wtmp/sentinel"; printf 'NEW\n' > "$wtmp/src"
for n in "$wtmp/d/f.pve-toolbox.$$" "$wtmp/d/f.pve-toolbox.1"; do ln -sfn "$wtmp/sentinel" "$n"; done
_cb_write_file "$wtmp/src" "$wtmp/d/f" 0600 || fail "_cb_write_file failed"
[[ $(cat "$wtmp/sentinel") == ORIGINAL ]] \
    || fail "the write followed a planted symlink into an unrelated file"
[[ ! -L $wtmp/d/f ]] || fail "the destination was left as a symlink"
[[ $(cat "$wtmp/d/f") == NEW ]] || fail "the write did not land"
[[ $(mode_of "$wtmp/d/f") == 600 ]] || fail "the mode was not applied"
# The planted decoys are expected to remain; what must not remain is a temp
# file of our own making.
[[ -z $(find "$wtmp/d" -name 'f.??????' -type f) ]] || fail "a temp file was left behind"
pass "writes are atomic and not traversable"

# The selector must not match on a bare prefix: it scopes what rollback
# deletes as well as what a restore writes.
CB_SELECTOR="pve/f"
_cb_selected "pve/firewall/cluster.fw" && fail "a truncated selector matched a longer path"
CB_SELECTOR="pve/firewall"
_cb_selected "pve/firewall/cluster.fw" || fail "the selector did not match its own subtree"
_cb_selected "pve/firewall-extra.cfg" && fail "the selector matched a sibling by prefix"
CB_SELECTOR=""
pass "the selector matches path components, not prefixes"

[[ $(grep -c . "$CB_ARCHIVE_DIR/restore.log") -ge 3 ]] || fail "the restore log has no record"
grep -q 'rollback' "$CB_ARCHIVE_DIR/restore.log" || fail "the rollback was not logged"
pass "restore log"

# An unverifiable source is refused rather than warned about: restoring from a
# corrupt archive is how a bad day becomes a worse one.
CB_CONFIRM=1
BAD="$CB_ARCHIVE_DIR/pve-config_${HOST_SHORT}_19700101T000000.tar.gz"
cp "$CB_ARCHIVE_DIR/$BASE" "$BAD"
printf 'corrupt' >> "$BAD"
cp "$CB_ARCHIVE_DIR/$BASE.sha256" "$BAD.sha256"
sed -i "s|$BASE|$(basename "$BAD")|" "$BAD.sha256"
before=$(tree_hash "$LIVE")
( _cb_restore "$(basename "$BAD")" ) >/dev/null 2>&1 && fail "a corrupt archive was accepted"
[[ $(tree_hash "$LIVE") == "$before" ]] || fail "a refused restore still wrote something"
rm -f "$BAD" "$BAD.sha256"

NOSUM="$CB_ARCHIVE_DIR/pve-config_${HOST_SHORT}_19700102T000000.tar.gz"
cp "$CB_ARCHIVE_DIR/$BASE" "$NOSUM"
( _cb_restore "$(basename "$NOSUM")" ) >/dev/null 2>&1 && fail "an archive with no .sha256 was accepted"
rm -f "$NOSUM"
pass "unverifiable sources are refused"

# No partial application: a hard pre-flight failure leaves the tree untouched.
before=$(tree_hash "$LIVE")
_cb_state_set RESTORE_IN_PROGRESS "$(date -Is)"
( _cb_restore "$BASE" ) >/dev/null 2>&1 && fail "a restore started with one already in progress"
[[ $(tree_hash "$LIVE") == "$before" ]] || fail "a refused restore wrote to the host"
_cb_state_set RESTORE_IN_PROGRESS ""
pass "a stale in-progress marker blocks a restore"

# The node check is the stated safety gate for same-node restore.
before=$(tree_hash "$LIVE")
OTHER=$(mktemp -d "$WORK/otherXXXXXX")
tar -C "$OTHER" -xzf "$CB_ARCHIVE_DIR/$BASE"
printf 'node=some-other-host\n' > "$OTHER/meta/capture.txt"
( CB_SRC_DIR=$OTHER CB_SRC_NODE=some-other-host
  plan=$(mktemp); _cb_restore_plan "$plan"
  _cb_restore_preflight "$plan" ) >/dev/null 2>&1 \
    && fail "a restore from another node was allowed without --target-node"
[[ $(tree_hash "$LIVE") == "$before" ]] || fail "a refused cross-node restore wrote something"
pass "cross-node restore is blocked"

# never-class paths are hard-blocked, and --force does not lift it.
CB_FORCE=1
( CB_SRC_DIR=$(mktemp -d "$WORK/nevXXXXXX")
  mkdir -p "$CB_SRC_DIR/pve"
  printf 'tampered\n' > "$CB_SRC_DIR/pve/corosync.conf"
  plan=$(mktemp); _cb_restore_plan "$plan"
  grep -q '^skip	pve/corosync.conf' "$plan" || exit 1 ) \
    || fail "corosync.conf was not skipped, even with --force"
CB_FORCE=0
pass "never-class survives --force"

# The class comes from the current table, not from the archive's manifest, so
# a path reclassified since cannot be resurrected by an old archive.
( CB_SRC_DIR=$(mktemp -d "$WORK/oldXXXXXX")
  mkdir -p "$CB_SRC_DIR/pve/priv"
  printf 'key\n' > "$CB_SRC_DIR/pve/priv/authkey.key"
  plan=$(mktemp); _cb_restore_plan "$plan"
  grep -q '^skip	pve/priv/authkey.key	never' "$plan" || exit 1 ) \
    || fail "class was taken from the archive rather than re-derived"
pass "class is re-derived, not trusted"

# A held lock must stop a restore loudly. Exiting 0 there would tell an
# operator who ran --confirm that it worked when nothing happened.
flock -n "$CB_LOCK_DIR/pve-config-backup.lock" sleep 5 &
holder=$!
sleep 0.3
( _cb_take_lock ) && fail "the lock was handed out twice"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
pass "the lock is exclusive"

# --- 9. cross-node transform ----------------------------------------------

# A pmxcfs-shaped fixture: the real collector never produces the flat
# pve/qemu-server layout, because those are symlinks into nodes/<local>/.
xn_fixture() { # xn_fixture -> sets XSRC to a fresh staged tree
    XSRC=$(mktemp -d "$WORK/xnXXXXXX")
    mkdir -p "$XSRC/pve/nodes/pve1/qemu-server" "$XSRC/pve/nodes/pve1/lxc" \
             "$XSRC/meta" "$XSRC/host/etc/network"
    cat > "$XSRC/pve/nodes/pve1/qemu-server/100.conf" <<'CONF'
cores: 4
memory: 100
name: web01
net0: virtio=AA:BB:CC:11:22:33,bridge=vmbr0,firewall=1,tag=100
net1: e1000-82545em=AA:BB:CC:11:22:34,bridge=vmbr1,mtu=9000
scsi0: local-lvm:vm-100-disk-0,size=32G
scsi1: local:100/vm-100-disk-1.qcow2,size=100G
efidisk0: local-lvm:vm-100-disk-2,efitype=4m,size=1M
unused0: local-lvm:vm-100-disk-9
vmstate: local-lvm:vm-100-state-snap

[snap]
memory: 100
net0: virtio=AA:BB:CC:11:22:33,bridge=vmbr0
scsi0: local-lvm:vm-100-disk-0,size=32G
CONF
    # Real pct syntax. The old fixture wrote `net0: veth=<mac>,...`, which pct
    # never emits - so the MAC assertion was validating the implementation
    # against itself while --regenerate-macs did nothing to any container.
    cat > "$XSRC/pve/nodes/pve1/lxc/200.conf" <<'CONF'
arch: amd64
rootfs: local-lvm:subvol-200-disk-0,size=8G
mp0: local:200/vm-200-disk-1.raw,mp=/data
net0: name=eth0,bridge=vmbr0,firewall=1,hwaddr=BC:24:11:11:22:33,ip=dhcp,type=veth
net1: name=eth1,bridge=vmbr0,hwaddr=BC:24:11:44:55:66,ip=10.0.0.5/24,type=veth
CONF
    printf 'name: gpu\nhostpci0: 0000:01:00.0,pcie=1\n' > "$XSRC/pve/nodes/pve1/qemu-server/300.conf"
    printf 'dir: local\n\tnodes pve1,pve2\n' > "$XSRC/pve/storage.cfg"
    printf 'auto vmbr0\n' > "$XSRC/host/etc/network/interfaces"
    printf 'node=pve1\n' > "$XSRC/meta/capture.txt"
}

XLIVE=$(mktemp -d "$WORK/xliveXXXXXX"); mkdir -p "$XLIVE/pve/nodes/pve2"
# HOST_SHORT is what the guard compares --target-node against, so the fixture
# has to pretend to be pve2 rather than whatever machine runs the tests.
xn_run() {
    CB_SRC_DIR=$XSRC CB_SRC_NODE=pve1 CB_PVE_DIR="$XLIVE/pve" HOST_SHORT=pve2 \
    _cb_transform >/dev/null 2>&1
}

# --target-node has to name this host. Writing another node's sshd_config or
# cron.d through a shared /etc/pve would land on the wrong machine, and the
# rollback point would be recorded on the wrong machine too.
xn_fixture
( CB_TARGET_NODE=somewhere-else CB_XN_MODE=dr CB_XN_SOURCE_GONE=1
  CB_SRC_DIR=$XSRC CB_SRC_NODE=pve1 CB_PVE_DIR="$XLIVE/pve" HOST_SHORT=pve2
  _cb_transform ) >/dev/null 2>&1 && fail "--target-node accepted a node that is not this host"
pass "cross-node writes only to this host"

# dr mode reuses the source's identities, and the tool cannot tell a dead node
# from a partitioned one.
( CB_TARGET_NODE=pve2 CB_XN_MODE=dr CB_XN_SOURCE_GONE=0
  CB_SRC_DIR=$XSRC CB_SRC_NODE=pve1 CB_PVE_DIR="$XLIVE/pve" HOST_SHORT=pve2
  _cb_transform ) >/dev/null 2>&1 && fail "dr mode ran without acknowledging the source is gone"
( CB_TARGET_NODE=pve2 CB_XN_MODE=clone CB_XN_VMID_OFFSET=0
  CB_SRC_DIR=$XSRC CB_SRC_NODE=pve1 CB_PVE_DIR="$XLIVE/pve" HOST_SHORT=pve2
  _cb_transform ) >/dev/null 2>&1 && fail "clone mode ran without a VMID remap"
pass "the modes demand what they need"

# The whole transform, with every mapping on.
xn_fixture
( CB_TARGET_NODE=pve2 CB_XN_MODE=clone CB_XN_VMID_OFFSET=1000 CB_XN_REGEN_MACS=1
  CB_MAP_STORAGE=([local]=nas) CB_MAP_BRIDGE=([vmbr0]=vmbr9)
  xn_run )
Q="$XSRC/pve/nodes/pve2/qemu-server/1100.conf"
L="$XSRC/pve/nodes/pve2/lxc/1200.conf"
[[ -f $Q ]] || fail "the qemu config was not moved to the target node and renamed"
[[ -f $L ]] || fail "the lxc config was not moved to the target node and renamed"
[[ -d $XSRC/pve/nodes/pve1 ]] && fail "the source node directory survived"
pass "node path and VMID rename"

# A bare numeric substitution would have destroyed both of these.
grep -q '^memory: 100$' "$Q" || fail "memory: 100 was rewritten by the VMID remap"
grep -q 'tag=100' "$Q"      || fail "the VLAN tag 100 was rewritten by the VMID remap"
# Every volume-bearing key, including the ones that are easy to forget.
grep -q 'vm-1100-disk-0' "$Q"      || fail "scsi0 volume not rewritten"
grep -q 'nas:1100/vm-1100-disk-1' "$Q" || fail "the vmid in the directory prefix was not rewritten"
grep -q 'efidisk0: local-lvm:vm-1100-disk-2' "$Q" || fail "efidisk not rewritten"
grep -q 'unused0: local-lvm:vm-1100-disk-9'  "$Q" || fail "unused disk not rewritten"
grep -q 'vmstate: local-lvm:vm-1100-state'   "$Q" || fail "vmstate not rewritten"
grep -q 'subvol-1200-disk-0' "$L"  || fail "the lxc rootfs subvol was not rewritten"
grep -q 'nas:1200/vm-1200-disk-1' "$L" || fail "the lxc mount point was not rewritten"
# The snapshot stanza carries its own copy of every disk line.
awk '/^\[snap\]/{s=1} s' "$Q" | grep -q 'vm-1100-disk-0' \
    || fail "the snapshot section was not rewritten"
pass "volume tokens only"

# Anchored on the field, so a storage whose name merely contains the mapped one
# is left alone.
grep -q '^scsi0: local-lvm:' "$Q" || fail "local-lvm was clobbered by the 'local' mapping"
grep -q '^scsi1: nas:'       "$Q" || fail "the 'local' storage was not mapped"
pass "storage mapping is anchored"

# The MAC is the value of the model key; everything after it survives.
grep -qE '^net0: virtio=BC:24:11:[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2},bridge=vmbr9,firewall=1,tag=100$' "$Q" \
    || fail "the regenerated net0 line lost its model or its options: $(grep '^net0:' "$Q")"
grep -qE '^net0: name=eth0,bridge=vmbr9,firewall=1,hwaddr=BC:24:11:[0-9A-F]{2}:[0-9A-F]{2}:[0-9A-F]{2},ip=dhcp,type=veth$' "$L" \
    || fail "the lxc hwaddr was not regenerated, or the rest of the line moved: $(grep '^net0:' "$L")"
grep -qE '^net1: e1000-82545em=BC:24:11:' "$Q" \
    || fail "a hyphenated NIC model was skipped: $(grep '^net1:' "$Q")"
pass "MAC regeneration keeps the rest of the line"

# Hardware and identity that did not move with the config.
[[ -e $XSRC/host/etc/network/interfaces ]] && fail "interfaces survived a cross-node restore"
# Shared by the whole cluster: installing the source's copy would delete every
# entry this cluster has that the source lacked.
[[ -e $XSRC/pve/storage.cfg ]] && fail "storage.cfg was not blocked on a cross-node restore"
pass "auto-exclusions and cluster-wide blocks"

# hostpci names a PCI address on the source machine.
[[ -e $XSRC/pve/nodes/pve2/qemu-server/1300.conf ]] && fail "a hostpci guest was not blocked"
pass "hostpci guests are blocked"

# A VMID already live on another node is a collision; one under the source
# node's own tree is not, because a dead node's tree survives and dr mode
# exists to reuse exactly that VMID.
xn_fixture
mkdir -p "$XLIVE/pve/nodes/pve3/qemu-server"
printf 'name: existing\n' > "$XLIVE/pve/nodes/pve3/qemu-server/100.conf"
( CB_TARGET_NODE=pve2 CB_XN_MODE=dr CB_XN_SOURCE_GONE=1; xn_run )
[[ -e $XSRC/pve/nodes/pve2/qemu-server/100.conf ]] \
    && fail "a VMID live on another node was not treated as a collision"
mkdir -p "$XLIVE/pve/nodes/pve1/qemu-server"
printf 'name: stale\n' > "$XLIVE/pve/nodes/pve1/qemu-server/200.conf"
xn_fixture
( CB_TARGET_NODE=pve2 CB_XN_MODE=dr CB_XN_SOURCE_GONE=1; xn_run )
[[ -e $XSRC/pve/nodes/pve2/lxc/200.conf ]] \
    || fail "a stale entry under the dead source node was treated as a collision"
rm -rf "$XLIVE/pve/nodes/pve3" "$XLIVE/pve/nodes/pve1"
pass "VMID collisions distinguish live from stale"
