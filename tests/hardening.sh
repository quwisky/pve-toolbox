#!/usr/bin/env bash
#
# Behaviour-level regression tests for the destructive and scheduled module
# paths. Everything writes only below one throwaway directory; systemd, ZFS,
# release downloads and privileged commands are replaced with shell fixtures.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# --- config-backup paths and uninstall --------------------------------------

(
    PVE_TOOLBOX_LIB="$ROOT/lib"
    export PVE_TOOLBOX_LIB
    # shellcheck source=modules/config-backup/pve-config-backup.sh
    source "$ROOT/modules/config-backup/pve-config-backup.sh"

    if _cb_safe_data_dir / >/dev/null 2>&1; then
        fail "the runner accepted / as a data directory"
    fi
    mkdir -p "$WORK/archive-ok"
    [[ $(_cb_safe_data_dir "$WORK/archive-ok") == "$WORK/archive-ok" ]] \
        || fail "the runner rejected a dedicated data directory"
    ln -s / "$WORK/archive-root-link"
    if _cb_safe_data_dir "$WORK/archive-root-link" >/dev/null 2>&1; then
        fail "the runner accepted a symlink resolving to /"
    fi
) || exit 1
pass "config-backup runtime rejects dangerous data paths"

(
    export TOOLBOX_BIN_DIR="$WORK/cb-bin" TOOLBOX_LIB_DIR="$WORK/cb-lib"
    export TOOLBOX_CONF_DIR="$WORK/cb-conf" TOOLBOX_STATE_DIR="$WORK/cb-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/cb-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR" \
             "$WORK/cb-archives" "$WORK/cb-git"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/config-backup/module.sh
    source "$ROOT/modules/config-backup/module.sh"

    conf_set config-backup CB_ARCHIVE_DIR "$WORK/cb-archives"
    conf_set config-backup CB_GIT_DIR "$WORK/cb-git"
    : > "$WORK/cb-prompts"
    require_root() { :; }
    systemd_remove() { :; }
    state_clear() { :; }
    ask_yn() {
        printf '%s\n' "$2" >> "$WORK/cb-prompts"
        case $1 in
            drop)      printf -v "$1" y ;;
            drop_data) printf -v "$1" n ;;
            drop_git)  printf -v "$1" n ;;
        esac
    }
    module_uninstall >/dev/null
    grep -Fq "also delete the git history in $WORK/cb-git" "$WORK/cb-prompts" \
        || fail "uninstall lost CB_GIT_DIR after clearing config"

    conf_set config-backup CB_ARCHIVE_DIR /
    : > "$WORK/cb-mutations"
    systemd_remove() { printf 'removed unit\n' >> "$WORK/cb-mutations"; }
    if ( module_uninstall ) >/dev/null 2>&1; then
        fail "uninstall accepted / as its archive directory"
    fi
    [[ ! -s $WORK/cb-mutations ]] \
        || fail "uninstall mutated the system before validating its data paths"
) || exit 1
pass "config-backup uninstall retains both data paths"

(
    export TOOLBOX_BIN_DIR="$WORK/cb-i-bin" TOOLBOX_LIB_DIR="$WORK/cb-i-lib"
    export TOOLBOX_CONF_DIR="$WORK/cb-i-conf" TOOLBOX_STATE_DIR="$WORK/cb-i-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/cb-i-systemd" TOOLBOX_ROOT="$ROOT"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/config-backup/module.sh
    source "$ROOT/modules/config-backup/module.sh"

    CB_WEBHOOK='https://discord.com/api/webhooks/1/token'
    require_root() { :; }
    require_pve() { :; }
    pkg_ensure() { :; }
    systemd_oneshot() { :; }
    run_unit() { :; }
    discord_notify() { :; }
    systemd-analyze() {
        [[ $1 == calendar && $2 == --iterations=1 ]] || return 2
        case $3 in
            daily) printf '  Next elapse: Thu 2026-10-01 00:00:00 UTC\n' ;;
            *)     return 1 ;;
        esac
    }

    answers=$'\n'                 # webhook: Enter, keep the preset
    answers+=$'n\nn\n'            # backends: rejected (neither enabled)
    answers+=$'y\nn\n'            # backends: local yes, git no
    answers+=$'/\n'               # archive dir: rejected, unsafe
    answers+="$WORK/cb-archives"$'\n'
    answers+=$'x\n'               # retention count: rejected
    answers+=$'5\n'
    answers+=$'\n'                # retention days: Enter (default)
    answers+=$'whenever\n'        # schedule: rejected
    answers+=$'daily\n'
    answers+=$'n\n'               # reporting
    answers+=$'n\n'               # secrets
    answers+=$'n\n'               # test notification
    answers+=$'n\n'               # run now

    out=$(printf '%s' "$answers" | module_install 2>&1) \
        || fail "config-backup install with valid answers failed: $out"

    for reason in \
        'at least one backend has to be enabled' \
        'refusing unsafe directory: /' \
        'enter a whole number of at least 0' \
        'not a systemd OnCalendar expression: whenever'
    do
        count=$(grep -Fc "$reason" <<<"$out")
        [[ $count -eq 1 ]] \
            || fail "expected exactly one rejection for [$reason], got $count: $out"
    done

    grep -q '^CB_RETENTION_COUNT=.5.$' "$TOOLBOX_CONF_DIR/config-backup.conf" \
        || fail "CB_RETENTION_COUNT=5 was not stored"
) || exit 1
pass "config-backup install validates each prompt and stores the accepted answer"

# --- zfs-replication --------------------------------------------------------

(
    export TOOLBOX_BIN_DIR="$WORK/zr-bin" TOOLBOX_LIB_DIR="$WORK/zr-lib"
    export TOOLBOX_CONF_DIR="$WORK/zr-conf" TOOLBOX_STATE_DIR="$WORK/zr-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/zr-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/zfs-replication/module.sh
    source "$ROOT/modules/zfs-replication/module.sh"

    if _zr_jobs_unique a-b a_b; then
        fail "colliding replication job keys were accepted"
    fi
    _zr_jobs_unique one two \
        || fail "distinct replication job keys were rejected"

    systemd-analyze() { [[ $1 == calendar && $2 == daily ]]; }
    _zr_valid_schedule daily || fail "a valid replication schedule was rejected"
    if _zr_valid_schedule nonsense; then fail "an invalid replication schedule was accepted"; fi
    if ( _zr_write_timer job nonsense ) >/dev/null 2>&1; then
        fail "an invalid replication timer was written"
    fi
    [[ ! -e $TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@job.timer ]] \
        || fail "invalid replication timer content reached disk"
    systemctl() { return 1; }
    if _zr_enable job >/dev/null 2>&1; then
        fail "replication timer enable failure was swallowed"
    fi
) || exit 1
pass "zfs-replication rejects key and timer failures"

(
    PVE_TOOLBOX_LIB="$ROOT/lib"
    export PVE_TOOLBOX_LIB
    # shellcheck source=modules/zfs-replication/pve-toolbox-zfs-sync.sh
    source "$ROOT/modules/zfs-replication/pve-toolbox-zfs-sync.sh"

    TARGET="$WORK/zr-target"
    OUTSIDE="$WORK/zr-outside"
    mkdir -p "$TARGET/child" "$OUTSIDE"
    JOB_DST=tank/backup
    zfs() {
        [[ $1 == get ]] && { printf '%s\n' "$TARGET"; return 0; }
        return 0
    }

    JOB_PATH="$TARGET/child"
    _resolve_fixup_path || fail "a child of the target mountpoint was rejected"
    [[ $FIXUP_PATH == "$TARGET/child" ]] || fail "the fixup path was not canonicalized"
    JOB_PATH=/
    if _resolve_fixup_path; then fail "the replication runner accepted / for recursive fixups"; fi
    JOB_PATH="$OUTSIDE"
    if _resolve_fixup_path; then fail "a fixup path outside the target mountpoint was accepted"; fi

    LOCK_DIR="$WORK/zr-lock"
    JOB=job
    _take_lock || fail "a private replication lock could not be taken"
    [[ $(mode_of "$LOCK_DIR") == 700 ]] || fail "the replication lock directory is not 0700"
    [[ $(mode_of "$LOCK_DIR/pve-toolbox-zfs-sync-job.lock") == 600 ]] \
        || fail "the replication lock file is not 0600"
    exec 9>&-
    ln -s "$LOCK_DIR" "$WORK/zr-lock-link"
    LOCK_DIR="$WORK/zr-lock-link"
    lock_rc=0; _take_lock || lock_rc=$?
    [[ $lock_rc -eq 2 ]] || fail "a symlinked replication lock directory did not fail closed"

    JOB_CHOWN=1000:1000 JOB_CHMOD=""
    _resolve_fixup_path() { FIXUP_PATH=$TARGET; return 0; }
    chown() { return 1; }
    if _apply_fixups >/dev/null 2>&1; then
        fail "a failed recursive chown was reported as successful"
    fi
    [[ $FIXUP_PERMS == *failed* ]] || fail "the failed chown was not described"

    JOBS='a-b a_b'
    if ( _jobs_unique ) >/dev/null 2>&1; then
        fail "the runner accepted colliding job keys from a hand-edited config"
    fi
) || exit 1
pass "zfs-replication locks and fixups fail closed"

(
    export TOOLBOX_BIN_DIR="$WORK/zr-ask-bin" TOOLBOX_LIB_DIR="$WORK/zr-ask-lib"
    export TOOLBOX_CONF_DIR="$WORK/zr-ask-conf" TOOLBOX_STATE_DIR="$WORK/zr-ask-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/zr-ask-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    unset ZFS_REPL_OPTS ZFS_REPL_SCHEDULE \
          ZFS_REPL_JOB1_SRC ZFS_REPL_JOB1_DST ZFS_REPL_JOB1_OPTS \
          ZFS_REPL_JOB1_CHOWN ZFS_REPL_JOB1_CHMOD ZFS_REPL_JOB1_PATH \
          ZFS_REPL_JOB1_SCHEDULE
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/zfs-replication/module.sh
    source "$ROOT/modules/zfs-replication/module.sh"

    have_zfs() { return 1; }
    _zr_write_timer() { :; }
    systemd-analyze() {
        [[ $1 == calendar && $2 == --iterations=1 ]] || return 2
        case $3 in
            daily) printf '  Next elapse: Thu 2026-10-01 00:00:00 UTC\n' ;;
            *)     return 1 ;;
        esac
    }
    _zr_defaults
    declare -A ZR_ANS_SRC=() ZR_ANS_DST=() ZR_ANS_OPTS=() ZR_ANS_CHOWN=() \
               ZR_ANS_CHMOD=() ZR_ANS_PATH=() ZR_ANS_SCHED=()

    answers=$'tank/a\n'    # source dataset
    answers+=$'backup/a\n' # target dataset
    answers+=$'\n'         # syncoid options: Enter
    answers+=$'n\n'        # fix ownership
    answers+=$'bogus\n'    # schedule: rejected
    answers+=$'daily\n'    # schedule: accepted

    out=$(printf '%s' "$answers" | _zr_ask_job job1 2>&1) \
        || fail "_zr_ask_job with valid answers failed: $out"
    grep -Fq 'not a systemd OnCalendar expression: bogus' <<<"$out" \
        || fail "_zr_ask_job accepted an invalid schedule: $out"
) || exit 1
pass "zfs-replication job prompt validates the schedule"

(
    export TOOLBOX_BIN_DIR="$WORK/zr-y-bin" TOOLBOX_LIB_DIR="$WORK/zr-y-lib"
    export TOOLBOX_CONF_DIR="$WORK/zr-y-conf" TOOLBOX_STATE_DIR="$WORK/zr-y-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/zr-y-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    unset ZFS_REPL_OPTS ZFS_REPL_SCHEDULE \
          ZFS_REPL_NIGHTLY_SRC ZFS_REPL_NIGHTLY_DST ZFS_REPL_NIGHTLY_OPTS \
          ZFS_REPL_NIGHTLY_CHOWN ZFS_REPL_NIGHTLY_CHMOD ZFS_REPL_NIGHTLY_PATH
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/zfs-replication/module.sh
    source "$ROOT/modules/zfs-replication/module.sh"

    have_zfs() { return 1; }
    systemd-analyze() {
        [[ $1 == calendar && $2 == --iterations=1 ]] || return 2
        case $3 in
            daily) printf '  Next elapse: Thu 2026-10-01 00:00:00 UTC\n' ;;
            *)     return 1 ;;
        esac
    }
    _zr_defaults
    declare -A ZR_ANS_SRC=() ZR_ANS_DST=() ZR_ANS_OPTS=() ZR_ANS_CHOWN=() \
               ZR_ANS_CHMOD=() ZR_ANS_PATH=() ZR_ANS_SCHED=()

    ASSUME_YES=1
    export ZFS_REPL_NIGHTLY_SRC=tank/a ZFS_REPL_NIGHTLY_DST=backup/a \
           ZFS_REPL_NIGHTLY_SCHEDULE=bogus

    out=$(_zr_ask_job nightly 2>&1) && fail "an invalid -y replication schedule was accepted"
    [[ $out == *'schedule for nightly'* ]] \
        || fail "the -y schedule failure did not name the job: $out"
    [[ $out == *'not a systemd OnCalendar expression: bogus'* ]] \
        || fail "the -y schedule failure did not include the reason: $out"
    grep -q '^JOB_NIGHTLY_' "$TOOLBOX_CONF_DIR/zfs-replication.conf" 2>/dev/null \
        && fail "an invalid -y replication schedule wrote job keys anyway"
    [[ ! -e "$TOOLBOX_SYSTEMD_DIR/$ZR_UNIT@nightly.timer" ]] \
        || fail "an invalid -y replication schedule wrote a timer file anyway"
) || exit 1
pass "an invalid -y replication schedule names the job and writes nothing for it"

# Runs a zfs-replication function end to end against <dir>, with every
# ZFS_REPL_* preset from the calling environment removed. Sets ZR_RC and ZR_OUT.
zr_run() { # zr_run <dir> <answers> <function> [VAR=value]...
    local dir=$1 answers=$2
    shift 2
    mkdir -p "$dir"/{bin,lib,conf,state,systemd,log,fake}
    cat > "$dir/fake/systemctl" <<'SH'
#!/bin/sh
case $1 in is-enabled|is-active) exit 1 ;; esac
exit 0
SH
    chmod +x "$dir/fake/systemctl"
    ZR_RC=0
    ZR_OUT=$(printf '%b' "$answers" | PATH="$dir/fake:$PATH" timeout 20 bash -c '
        set -euo pipefail
        for v in $(compgen -v ZFS_REPL_ || true); do unset "$v"; done
        export TOOLBOX_BIN_DIR=$1/bin TOOLBOX_LIB_DIR=$1/lib TOOLBOX_CONF_DIR=$1/conf
        export TOOLBOX_STATE_DIR=$1/state TOOLBOX_SYSTEMD_DIR=$1/systemd TOOLBOX_ROOT=$PWD
        dir=$1 fn=$2
        shift 2
        [[ $# -eq 0 ]] || export "$@"
        source lib/common.sh
        source modules/zfs-replication/module.sh
        ZR_LOG_DIR=$dir/log
        require_root() { :; }; require_pve() { :; }; pkg_ensure() { :; }
        have_zfs() { return 0; }; zfs() { return 0; }
        systemd-analyze() { # any schedule but "bogus" is valid
            [[ $1 == calendar && ${*: -1} != bogus ]] || return 1
            printf "  Next elapse: Thu 2026-10-01 00:00:00 UTC\n"
        }
        "$fn"
    ' _ "$dir" "$@" 2>&1) || ZR_RC=$?
    [[ $ZR_RC -ne 124 ]] || fail "zfs-replication $3 hung: $ZR_OUT"
}
zr_nothing_written() { # zr_nothing_written <dir> <what>
    local left
    left=$(find "$1"/{bin,lib,conf,state,systemd,log} -type f)
    [[ -z $left ]] || fail "$2 wrote files: $left"
}
zr_hook=https://discord.com/api/webhooks/1/token

# Job a is answered in full, then the answers run out inside job b. Nothing may
# be written: not job a's keys or timer, not the webhook, not the runner.
zr_run "$WORK/zr-mid" "$zr_hook\ntank/a\nbackup/a\n\n\n\ntank/b\n" module_install \
    ZFS_REPL_JOBS='a b'
[[ $ZR_RC -ne 0 ]] || fail "zfs-replication installed on answers that ran out: $ZR_OUT"
[[ $ZR_OUT == *'Job: b'* && $ZR_OUT == *'no answer for "  target dataset"'* ]] \
    || fail "zfs-replication did not stop at job b's target: $ZR_OUT"
zr_nothing_written "$WORK/zr-mid" "zfs-replication with answers ending inside a job"
pass "zfs-replication writes nothing when the answers run out inside a later job"

# Every job dropped: the install ends before the after-install questions (an
# answer for them would be missing, so asking one would fail with no answer).
zr_run "$WORK/zr-none" "$zr_hook\n\n\n\n\n" module_install ZFS_REPL_JOBS='a b'
[[ $ZR_RC -ne 0 ]] || fail "zfs-replication installed with no usable jobs: $ZR_OUT"
[[ $ZR_OUT == *'no usable jobs'* ]] \
    || fail "zfs-replication did not report no usable jobs: $ZR_OUT"
[[ $ZR_OUT != *'no answer for'* ]] \
    || fail "zfs-replication asked more questions after every job was dropped: $ZR_OUT"
zr_nothing_written "$WORK/zr-none" "zfs-replication with no usable jobs"
pass "zfs-replication with no usable jobs stops before the notify questions and writes nothing"

# Under -y an invalid preset in a later job stops the install before job a,
# which is valid, or anything else is written.
zr_run "$WORK/zr-y-mid" '' module_install ASSUME_YES=1 \
    ZFS_REPL_WEBHOOK="$zr_hook" ZFS_REPL_JOBS='a b' \
    ZFS_REPL_A_SRC=tank/a ZFS_REPL_A_DST=backup/a ZFS_REPL_A_SCHEDULE=daily \
    ZFS_REPL_B_SRC=tank/b ZFS_REPL_B_DST=backup/b ZFS_REPL_B_SCHEDULE=bogus
[[ $ZR_RC -ne 0 ]] || fail "zfs-replication -y installed with an invalid schedule for job b: $ZR_OUT"
[[ $ZR_OUT == *'schedule for b'*'not a systemd OnCalendar expression: bogus'* ]] \
    || fail "zfs-replication -y did not name job b's schedule: $ZR_OUT"
zr_nothing_written "$WORK/zr-y-mid" "zfs-replication -y with an invalid schedule for job b"
pass "zfs-replication -y with an invalid later job writes nothing"

# The complete answer set writes each job's keys and timer.
answers="$zr_hook\n"
answers+='tank/a\nbackup/a\n\ny\n1000:1000\n775\n\n\n'  # job a: fixup, default schedule
answers+='tank/b\nbackup/b\n--no-sync-snap\nn\nhourly\n'  # job b
answers+='\nn\nn\n'                                      # notify start, test, run now
zr_run "$WORK/zr-ok" "$answers" module_install ZFS_REPL_JOBS='a b'
[[ $ZR_RC -eq 0 ]] || fail "zfs-replication install with full answers failed: $ZR_OUT"
(
    export TOOLBOX_CONF_DIR="$WORK/zr-ok/conf" TOOLBOX_STATE_DIR="$WORK/zr-ok/state"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    expect() { # expect <key> <value>
        local got
        got=$(conf_get zfs-replication "$1")
        [[ $got == "$2" ]] || fail "zfs-replication stored $1='$got', expected '$2'"
    }
    expect DISCORD_WEBHOOK "$zr_hook"
    expect JOBS 'a b'
    expect NOTIFY_START 0
    expect JOB_A_SRC tank/a;  expect JOB_A_DST backup/a
    expect JOB_A_OPTS '--recursive --compress=zstd-fast'
    expect JOB_A_CHOWN 1000:1000; expect JOB_A_CHMOD 775; expect JOB_A_PATH ''
    expect JOB_B_SRC tank/b;  expect JOB_B_DST backup/b
    expect JOB_B_OPTS --no-sync-snap
    expect JOB_B_CHOWN '';    expect JOB_B_CHMOD '';    expect JOB_B_PATH ''
    [[ $(state_get zfs-replication JOBS) == 'a b' ]] \
        || fail "zfs-replication state does not list both jobs"
) || exit 1
grep -qx 'OnCalendar=\*-\*-\* 02:30:00' "$WORK/zr-ok/systemd/pve-toolbox-zfs-sync@a.timer" \
    || fail "zfs-replication job a has no timer with the default schedule"
grep -qx 'OnCalendar=hourly' "$WORK/zr-ok/systemd/pve-toolbox-zfs-sync@b.timer" \
    || fail "zfs-replication job b has no timer with its own schedule"
[[ -x $WORK/zr-ok/bin/pve-toolbox-zfs-sync && -f $WORK/zr-ok/systemd/pve-toolbox-zfs-sync@.service ]] \
    || fail "zfs-replication did not install the runner and service"
pass "zfs-replication install writes every job's keys and timer"

# update asks for and writes each configured job whose timer is missing. Job a
# has no stored OPTS, so its prompt falls back to the module default.
(
    export TOOLBOX_CONF_DIR="$WORK/zr-upd/conf"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    conf_set zfs-replication JOBS 'a b'
    conf_set zfs-replication JOB_A_SRC tank/a
    conf_set zfs-replication JOB_A_DST backup/a
    conf_set zfs-replication JOB_A_OPTS ''
    conf_set zfs-replication JOB_B_SRC tank/b
    conf_set zfs-replication JOB_B_DST backup/b
    conf_set zfs-replication JOB_B_OPTS --no-sync-snap
) >/dev/null || exit 1
answers='\n\n\n\n\n'            # job a: every default
answers+='\n\n\n\nhourly\n'       # job b: its own schedule
zr_run "$WORK/zr-upd" "$answers" module_update
[[ $ZR_RC -eq 0 ]] || fail "zfs-replication update could not repair missing timers: $ZR_OUT"
grep -qx 'OnCalendar=\*-\*-\* 02:30:00' "$WORK/zr-upd/systemd/pve-toolbox-zfs-sync@a.timer" \
    || fail "zfs-replication update did not write job a's timer with the default schedule: $ZR_OUT"
grep -qx 'OnCalendar=hourly' "$WORK/zr-upd/systemd/pve-toolbox-zfs-sync@b.timer" \
    || fail "zfs-replication update did not write job b's timer: $ZR_OUT"
grep -qx "JOB_A_OPTS='--recursive --compress=zstd-fast'" "$WORK/zr-upd/conf/zfs-replication.conf" \
    || fail "zfs-replication update did not fill job a's empty OPTS with the default"
pass "zfs-replication update rewrites missing job timers with the module defaults"

# --- zfs-scrub --------------------------------------------------------------

(
    export TOOLBOX_BIN_DIR="$WORK/zs-bin" TOOLBOX_LIB_DIR="$WORK/zs-lib"
    export TOOLBOX_CONF_DIR="$WORK/zs-conf" TOOLBOX_STATE_DIR="$WORK/zs-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/zs-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/zfs-scrub/module.sh
    source "$ROOT/modules/zfs-scrub/module.sh"

    if _zs_pools_unique tank-a tank_a; then
        fail "colliding scrub schedule variables were accepted"
    fi
    _zs_pools_unique tank-a tank-b \
        || fail "distinct scrub schedule variables were rejected"

    systemd-analyze() { [[ $1 == calendar && $2 == weekly ]]; }
    _zs_valid_schedule weekly || fail "a valid scrub schedule was rejected"
    if _zs_valid_schedule nonsense; then fail "an invalid scrub schedule was accepted"; fi
    if ( _zs_write_timer tank nonsense ) >/dev/null 2>&1; then
        fail "an invalid scrub timer was written"
    fi
    [[ ! -e $TOOLBOX_SYSTEMD_DIR/$ZS_UNIT@tank.timer ]] \
        || fail "invalid scrub timer content reached disk"
    systemctl() { return 1; }
    if _zs_enable tank >/dev/null 2>&1; then
        fail "scrub timer enable failure was swallowed"
    fi

    state_set zfs-scrub POOLS 'tank backup'
    state_set zfs-scrub SCHEDULE_OWNER native
    state_set zfs-scrub NATIVE_TIMER_TEMPLATE zfs-scrub-weekly@.timer
    require_root() { :; }
    if ( module_install ) >/dev/null 2>&1; then
        fail "migrated native schedules could be claimed by module install"
    fi
    native_update=$(module_update --check)
    [[ $native_update == *'managed by native ZFS timers'* ]] \
        || fail "module update did not preserve migrated native schedules"
    systemctl() { [[ $1 == is-enabled && $2 == --quiet ]]; }
    [[ $(module_status) == 'native timers  [tank backup]' ]] \
        || fail "module status did not report native schedule ownership"
) || exit 1
pass "zfs-scrub rejects unsafe timers and preserves native ownership"

# --- scrutiny collector install and update transactions --------------------

(
    export TOOLBOX_BIN_DIR="$WORK/sc-new-bin" TOOLBOX_LIB_DIR="$WORK/sc-new-lib"
    export TOOLBOX_CONF_DIR="$WORK/sc-new-conf" TOOLBOX_STATE_DIR="$WORK/sc-new-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/sc-new-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/scrutiny-collectors/module.sh
    source "$ROOT/modules/scrutiny-collectors/module.sh"

    CONFIG_DIR="$WORK/sc-new-config"
    SCRUTINY_API_ENDPOINT=https://example.invalid
    require_root() { :; }
    require_pve() { :; }
    pkg_ensure() { :; }
    detect_arch() { printf 'amd64'; }
    curl() { :; }
    ask() { :; }
    ask_valid() { :; }
    ask_secret() { :; }
    ask_yn() { :; }
    ask_schedule() { :; }
    have_zfs() { return 0; }
    have_mdadm() { return 1; }
    zpool() { printf 'tank\n'; }
    gh_release() { GH_TAG=v2.0.0; }
    gh_fetch_checksums() { CHECKSUM_FILE=""; }
    : > "$WORK/sc-new-staged"
    _sc_stage_binary() {
        printf '%s\n' "$1" >> "$WORK/sc-new-staged"
        [[ $1 == collector-zfs ]] && return 1
        printf 'new metrics\n' > "$3"
    }

    if ( module_install ) >/dev/null 2>&1; then
        fail "a collector install with a missing selected asset succeeded"
    fi
    [[ ! -e "$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}" ]] \
        || fail "a failed collector install left a partial binary set"
    # Proves the staging loop actually ran (rather than the install dying
    # earlier, e.g. on an un-stubbed validator hitting closed stdin): both
    # the metrics and the failing zfs asset must have been staged.
    grep -Fxq 'collector-metrics' "$WORK/sc-new-staged" \
        || fail "the metrics asset was never staged - install died before reaching it"
    grep -Fxq 'collector-zfs' "$WORK/sc-new-staged" \
        || fail "the missing zfs asset was never staged - install died before reaching it"
) || exit 1
pass "scrutiny installs require every selected release asset"

(
    export TOOLBOX_BIN_DIR="$WORK/sc-fio-bin" TOOLBOX_LIB_DIR="$WORK/sc-fio-lib"
    export TOOLBOX_CONF_DIR="$WORK/sc-fio-conf" TOOLBOX_STATE_DIR="$WORK/sc-fio-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/sc-fio-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/scrutiny-collectors/module.sh
    source "$ROOT/modules/scrutiny-collectors/module.sh"

    CONFIG_DIR="$WORK/sc-fio-config"
    SCRUTINY_API_ENDPOINT=https://example.invalid
    require_root() { :; }
    require_pve() { :; }
    pkg_ensure() { printf '%s\n' "$*" >> "$WORK/sc-fio-packages"; }
    detect_arch() { printf 'amd64'; }
    curl() { :; }
    ask() { :; }
    ask_valid() { :; }
    ask_secret() { :; }
    ask_yn() {
        case $2 in
            'fio performance collector'*) printf -v "$1" y ;;
            *) printf -v "$1" n ;;
        esac
    }
    ask_schedule() { :; }
    have_zfs() { return 1; }
    have_mdadm() { return 1; }
    gh_release() { GH_TAG=v2.0.0; }
    gh_fetch_checksums() { CHECKSUM_FILE=""; }
    _sc_stage_binary() { printf 'performance\n' > "$3"; }
    systemd_oneshot() { :; }
    state_set() { :; }

    module_install >/dev/null
    grep -Eq '(^| )fio:fio( |$)' "$WORK/sc-fio-packages" \
        || fail "performance collector install did not provision fio"

    : > "$WORK/sc-fio-packages"
    _sc_installed() { SC_PRESENT=(performance); }
    _sc_version() { printf 'v2.0.0'; }
    _sc_compare() { printf 'same'; }
    module_update >/dev/null
    grep -Eq '(^| )fio:fio( |$)' "$WORK/sc-fio-packages" \
        || fail "performance collector update did not repair a missing fio dependency"
) || exit 1
pass "scrutiny performance installs and repairs its fio dependency"

(
    export TOOLBOX_BIN_DIR="$WORK/sc-bin" TOOLBOX_LIB_DIR="$WORK/sc-lib"
    export TOOLBOX_CONF_DIR="$WORK/sc-conf" TOOLBOX_STATE_DIR="$WORK/sc-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/sc-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/scrutiny-collectors/module.sh
    source "$ROOT/modules/scrutiny-collectors/module.sh"

    printf 'old metrics\n' > "$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}"
    printf 'old zfs\n' > "$TOOLBOX_BIN_DIR/${SC_BIN[zfs]}"
    chmod 0755 "$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}" "$TOOLBOX_BIN_DIR/${SC_BIN[zfs]}"

    require_root() { :; }
    pkg_ensure() { :; }
    detect_arch() { printf 'amd64'; }
    _sc_installed() { SC_PRESENT=(metrics zfs); }
    _sc_version() { printf 'v1.0.0'; }
    gh_release() { GH_TAG=v2.0.0; }
    _sc_compare() { printf 'upgrade'; }
    confirm() { return 0; }
    gh_fetch_checksums() { CHECKSUM_FILE=""; }
    wait_for_idle() { :; }
    state_set() { :; }
    run_unit() { return 0; }

    : > "$WORK/sc-stage-systemctl"
    if (
        systemctl() { printf '%s\n' "$*" >> "$WORK/sc-stage-systemctl"; return 0; }
        _sc_stage_binary() {
            [[ $1 == collector-zfs ]] && return 1
            printf 'new metrics\n' > "$3"
        }
        module_update
    ) >/dev/null 2>&1; then
        fail "a collector update with a missing staged asset succeeded"
    fi
    grep -q '^stop ' "$WORK/sc-stage-systemctl" \
        && fail "collector timers stopped before every asset was staged"
    [[ $(<"$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}") == 'old metrics' ]] \
        || fail "staging failure replaced an installed collector"

    : > "$WORK/sc-install-systemctl"
    if (
        systemctl() { printf '%s\n' "$*" >> "$WORK/sc-install-systemctl"; return 0; }
        _sc_stage_binary() { printf 'new %s\n' "$1" > "$3"; }
        _sc_install_staged() {
            [[ $2 == "${SC_BIN[zfs]}" ]] && return 1
            cp -a "$TOOLBOX_BIN_DIR/$2" "$TOOLBOX_BIN_DIR/$2.prev"
            command install -m 0755 "$1" "$TOOLBOX_BIN_DIR/$2"
        }
        module_update
    ) >/dev/null 2>&1; then
        fail "a partial collector replacement succeeded"
    fi
    [[ $(<"$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}") == 'old metrics' ]] \
        || fail "a partial replacement did not roll back the first collector"
    grep -q "^start $UNIT_PREFIX-metrics.timer" "$WORK/sc-install-systemctl" \
        || fail "metrics timer was not restored after update failure"
    grep -q "^start $UNIT_PREFIX-zfs.timer" "$WORK/sc-install-systemctl" \
        || fail "zfs timer was not restored after update failure"

    printf 'old metrics\n' > "$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}"
    printf 'old zfs\n' > "$TOOLBOX_BIN_DIR/${SC_BIN[zfs]}"
    : > "$WORK/sc-smoke-systemctl"
    : > "$WORK/sc-state-writes"
    (
        systemctl() { printf '%s\n' "$*" >> "$WORK/sc-smoke-systemctl"; return 0; }
        _sc_stage_binary() { printf 'new %s\n' "$1" > "$3"; }
        run_unit() { [[ $1 != "$UNIT_PREFIX-zfs" ]]; }
        state_set() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$WORK/sc-state-writes"; }
        module_update
    ) >/dev/null 2>&1 || fail "a smoke-test rollback did not complete"
    [[ $(<"$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}") == 'old metrics' ]] \
        || fail "a failed release left metrics on the new version"
    [[ $(<"$TOOLBOX_BIN_DIR/${SC_BIN[zfs]}") == 'old zfs' ]] \
        || fail "a failed release left zfs on the new version"
    if grep -q ' VERSION ' "$WORK/sc-state-writes"; then
        fail "a rolled-back release was recorded as current"
    fi
) || exit 1
pass "scrutiny updates stage first and restore timers on failure"

(
    export TOOLBOX_BIN_DIR="$WORK/sc-prompt-bin" TOOLBOX_LIB_DIR="$WORK/sc-prompt-lib"
    export TOOLBOX_CONF_DIR="$WORK/sc-prompt-conf" TOOLBOX_STATE_DIR="$WORK/sc-prompt-state"
    export TOOLBOX_SYSTEMD_DIR="$WORK/sc-prompt-systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    unset SCRUTINY_API_ENDPOINT SCRUTINY_API_TOKEN SCRUTINY_HOST_ID SCRUTINY_VERSION \
          SCRUTINY_SCHEDULE_METRICS SCRUTINY_SCHEDULE_ZFS SCRUTINY_SCHEDULE_MDADM \
          SCRUTINY_SCHEDULE_PERFORMANCE
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/scrutiny-collectors/module.sh
    source "$ROOT/modules/scrutiny-collectors/module.sh"

    CONFIG_DIR="$WORK/sc-prompt-config"
    require_root() { :; }
    require_pve() { :; }
    pkg_ensure() { :; }
    detect_arch() { printf 'amd64'; }
    curl() { return 1; }
    gh_release() { GH_TAG=v2.0.0; }
    gh_fetch_checksums() { CHECKSUM_FILE=""; }
    _sc_stage_binary() { printf 'metrics\n' > "$3"; }
    systemd_oneshot() { :; }
    state_set() { :; }
    have_zfs() { return 1; }
    have_mdadm() { return 1; }
    systemd-analyze() {
        [[ $1 == calendar && $2 == --iterations=1 ]] || return 2
        case $3 in
            daily) printf '  Next elapse: Thu 2026-10-01 00:00:00 UTC\n' ;;
            *)     return 1 ;;
        esac
    }

    answers=$'not a url\n'         # endpoint: rejected
    answers+=$'http://10.0.0.10:8080\n'
    answers+=$'\n'                 # token: Enter
    answers+=$'\n'                 # host id: Enter
    answers+=$'y\n'                # continue anyway (curl fails)
    answers+=$'y\n'                # SMART metrics collector
    answers+=$'n\n'                # fio performance collector
    answers+=$'never-ever\n'       # metrics schedule: rejected
    answers+=$'daily\n'            # metrics schedule: accepted
    answers+=$'\n'                 # release tag: Enter
    answers+=$'n\n'                # run now

    out=$(printf '%s' "$answers" | module_install 2>&1) \
        || fail "scrutiny install with valid answers failed: $out"

    for reason in \
        'enter an http:// or https:// URL' \
        'not a systemd OnCalendar expression: never-ever'
    do
        count=$(grep -Fc "$reason" <<<"$out")
        [[ $count -eq 1 ]] \
            || fail "expected exactly one rejection for [$reason], got $count: $out"
    done
) || exit 1
pass "scrutiny install validates the endpoint, host id and metrics schedule"

(
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/scrutiny-collectors/module.sh
    source "$ROOT/modules/scrutiny-collectors/module.sh"

    while IFS='|' read -r endpoint stored; do
        _sc_valid_endpoint "$endpoint" \
            || fail "a valid scrutiny endpoint was rejected: $endpoint ($ASK_REASON)"
        [[ ${ASK_NORMALIZED:-$endpoint} == "$stored" ]] \
            || fail "scrutiny endpoint $endpoint was stored as $ASK_NORMALIZED, not $stored"
    done <<'EOF'
http://10.0.0.10:8080|http://10.0.0.10:8080
https://scrutiny.example.com|https://scrutiny.example.com
http://10.0.0.10:8080/|http://10.0.0.10:8080
http://h/scrutiny/|http://h/scrutiny
http://[fd00::10]:8080|http://[fd00::10]:8080
https://[::1]/|https://[::1]
EOF
    # The value lands in a YAML double-quoted string, so " and \ cannot be
    # allowed through into it.
    while IFS= read -r endpoint; do
        if _sc_valid_endpoint "$endpoint"; then
            fail "an invalid scrutiny endpoint was accepted: $endpoint"
        fi
    done <<'EOF'
not a url
ftp://10.0.0.10
http://
http://h/"x
http://h/a\b
http://h/a b
http://[fd00::10
EOF
) || exit 1
pass "scrutiny endpoints accept IPv6 literals and refuse YAML-breaking paths"

# The run-now question used to come after the binaries, the token-bearing
# collector config and the enabled timers were written, so closed input there
# left a half-installed module that status reported as installed.
(
    dir="$WORK/sc-eof"
    export TOOLBOX_BIN_DIR="$dir/bin" TOOLBOX_LIB_DIR="$dir/lib"
    export TOOLBOX_CONF_DIR="$dir/conf" TOOLBOX_STATE_DIR="$dir/state"
    export TOOLBOX_SYSTEMD_DIR="$dir/systemd"
    mkdir -p "$TOOLBOX_BIN_DIR" "$TOOLBOX_LIB_DIR" "$TOOLBOX_CONF_DIR" \
             "$TOOLBOX_STATE_DIR" "$TOOLBOX_SYSTEMD_DIR"
    unset SCRUTINY_API_ENDPOINT SCRUTINY_API_TOKEN SCRUTINY_HOST_ID SCRUTINY_VERSION \
          SCRUTINY_SCHEDULE_METRICS SCRUTINY_SCHEDULE_ZFS SCRUTINY_SCHEDULE_MDADM \
          SCRUTINY_SCHEDULE_PERFORMANCE
    # shellcheck source=lib/common.sh
    source "$ROOT/lib/common.sh"
    # shellcheck source=modules/scrutiny-collectors/module.sh
    source "$ROOT/modules/scrutiny-collectors/module.sh"

    CONFIG_DIR="$dir/config"
    require_root() { :; }
    require_pve() { :; }
    pkg_ensure() { :; }
    detect_arch() { printf 'amd64'; }
    curl() { return 0; }
    systemctl() { return 0; }
    gh_release() { GH_TAG=v2.0.0; }
    gh_fetch_checksums() { CHECKSUM_FILE=""; }
    _sc_stage_binary() { printf 'metrics\n' > "$3"; }
    have_zfs() { return 1; }
    have_mdadm() { return 1; }
    systemd-analyze() { printf '  Next elapse: Thu 2026-10-01 00:00:00 UTC\n'; }

    answers=$'http://10.0.0.10:8080\n'  # endpoint
    answers+=$'\n'                       # token: Enter
    answers+=$'pve1\n'                   # host id
    answers+=$'y\n'                      # SMART metrics collector
    answers+=$'n\n'                      # fio performance collector
    answers+=$'daily\n'                  # metrics schedule
    answers+=$'\n'                       # release tag: Enter; input ends here

    rc=0
    out=$(printf '%s' "$answers" | module_install 2>&1) || rc=$?
    [[ $rc -ne 0 ]] || fail "scrutiny installed on closed input: $out"
    [[ $out == *'no answer for "run each collector once now?'* ]] \
        || fail "scrutiny did not stop at the run-now question: $out"
    left=$(find "$dir" -type f)
    [[ -z $left ]] || fail "scrutiny wrote files before its last question: $left"
    [[ ! -e $CONFIG_DIR ]] || fail "scrutiny created $CONFIG_DIR before its last question"
) || exit 1
pass "scrutiny asks whether to run the collectors before it writes anything"

# --- webhook prompts ----------------------------------------------------------

# A webhook URL is a credential: it must never be read with the echoing ask.
if grep -nE '^\s*ask [A-Z_]*WEBHOOK\b' modules/*/module.sh; then
    fail "a webhook URL is read with the echoing ask"
fi

# Closed input at the webhook prompt used to spin forever in
# `while [[ -z $X ]]; do ask X ...; done`. It must now fail promptly.
webhook_eof() { # webhook_eof <module> <var>
    local rc=0 out
    out=$(printf '' | timeout 20 bash -c '
        set -euo pipefail
        export TOOLBOX_CONF_DIR=$1/conf TOOLBOX_STATE_DIR=$1/state
        mkdir -p "$TOOLBOX_CONF_DIR" "$TOOLBOX_STATE_DIR"
        source lib/common.sh
        source "modules/$2/module.sh"
        require_root() { :; }; require_pve() { :; }; pkg_ensure() { :; }
        have_zfs() { return 0; }; _zs_native_owner() { return 1; }
        unset "$3"
        module_install
    ' _ "$WORK/eof-$1" "$1" "$2" 2>&1) || rc=$?
    [[ $rc -ne 124 ]] || fail "$1 hung on closed input at the webhook prompt"
    [[ $rc -ne 0 ]] || fail "$1 installed with no webhook on closed input"
    [[ $out == *'no answer for "Discord webhook URL"'* ]] \
        || fail "$1 did not report the unanswered webhook prompt: $out"
}
webhook_eof config-backup CB_WEBHOOK
webhook_eof zfs-scrub ZFS_SCRUB_WEBHOOK
webhook_eof zfs-replication ZFS_REPL_WEBHOOK
pass "webhook prompts are secret and fail closed on EOF"

# Answers that run out part-way must stop an install before it writes
# anything: no binary, lib, conf, state or unit file. The questions about what
# to do after the install are asked before its first write for this reason.
install_eof() { # install_eof <module> <answers> <unanswered prompt> [VAR=value]...
    local module=$1 answers=$2 stop=$3 dir="$WORK/partial-$1" rc=0 out left
    shift 3
    mkdir -p "$dir"/{bin,lib,conf,state,systemd,data,fake}
    cat > "$dir/fake/systemctl" <<'SH'
#!/bin/sh
case $1 in is-enabled|is-active) exit 1 ;; esac
exit 0
SH
    chmod +x "$dir/fake/systemctl"
    out=$(printf '%b' "$answers" | env "$@" PATH="$dir/fake:$PATH" timeout 20 bash -c '
        set -euo pipefail
        export TOOLBOX_BIN_DIR=$1/bin TOOLBOX_LIB_DIR=$1/lib TOOLBOX_CONF_DIR=$1/conf
        export TOOLBOX_STATE_DIR=$1/state TOOLBOX_SYSTEMD_DIR=$1/systemd TOOLBOX_ROOT=$PWD
        source lib/common.sh
        source "modules/$2/module.sh"
        require_root() { :; }; require_pve() { :; }; pkg_ensure() { :; }
        have_zfs() { return 0; }; _zs_native_owner() { return 1; }
        _zs_pools() { printf "tank\n"; }
        zpool() { printf "ok\n"; }
        systemd-analyze() { [[ $1 == calendar ]] && printf "  Next elapse: Thu 2026-10-01 00:00:00 UTC\n"; }
        module_install
    ' _ "$dir" "$module" 2>&1) || rc=$?
    [[ $rc -ne 124 ]] || fail "$module hung on closed input"
    [[ $rc -ne 0 ]] || fail "$module installed on closed input: $out"
    [[ $out == *"$stop"* ]] || fail "$module did not stop at \"$stop\": $out"
    left=$(find "$dir"/{bin,lib,conf,state,systemd} -type f)
    [[ -z $left ]] || fail "$module wrote files before its last question: $left"
}
hook=https://discord.com/api/webhooks/1/token
install_eof config-backup "$hook\n\n\n\n\n\n\n\n\n" \
    'no answer for "send a test notification to Discord now' \
    CB_ARCHIVE_DIR="$WORK/partial-config-backup/data/archives"
install_eof zfs-scrub "$hook\n\n\n\n\n" \
    'no answer for "send a test notification to Discord now'
install_eof zfs-replication "$hook\ntank/a\nbackup/a\n\n\n\n" \
    'no answer for "also notify when a job starts' ZFS_REPL_JOBS=nightly
pass "installs stop before writing when the answers run out"

# Under -y an invalid preset is refused before anything is written, and the
# error names the variable to fix.
install_eof config-backup "" 'invalid value for CB_WEBHOOK' \
    ASSUME_YES=1 CB_WEBHOOK=http://x
pass "an invalid webhook preset under -y names its variable and writes nothing"
