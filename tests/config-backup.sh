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
printf 'user:root@pam:1:0:::\n'              > "$FIX/pve/user.cfg"
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
[[ -f $stage/pve/priv/authkey.key ]] || fail "the fixture key was not collected in the first place"
_cb_drop_secrets
[[ -e $stage/pve/priv/authkey.key ]] && fail "a key under priv/ survived _cb_drop_secrets"
_cb_secret_scan >/dev/null || fail "the scan flagged a tree with nothing left in it"
pass "priv/ is dropped before the scan"

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
CB_SECRET_ALLOW='pve/sdn/leaked.conf host/etc/cron.d/leak'
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

# The token must not end up persisted anywhere in the repository.
grep -rq 'ghp_TESTTOKENVALUE' "$CB_GIT_DIR/.git/config" 2>/dev/null \
    && fail "a token was written into .git/config"
pass "no credential in .git/config"
