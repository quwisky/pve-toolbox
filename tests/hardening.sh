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
) || exit 1
pass "zfs-scrub rejects schedule collisions and timer failures"

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
    ask_secret() { :; }
    ask_yn() { :; }
    have_zfs() { return 0; }
    have_mdadm() { return 1; }
    zpool() { printf 'tank\n'; }
    gh_release() { GH_TAG=v2.0.0; }
    gh_fetch_checksums() { CHECKSUM_FILE=""; }
    _sc_stage_binary() {
        [[ $1 == collector-zfs ]] && return 1
        printf 'new metrics\n' > "$3"
    }

    if ( module_install ) >/dev/null 2>&1; then
        fail "a collector install with a missing selected asset succeeded"
    fi
    [[ ! -e "$TOOLBOX_BIN_DIR/${SC_BIN[metrics]}" ]] \
        || fail "a failed collector install left a partial binary set"
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
    ask_secret() { :; }
    ask_yn() {
        case $2 in
            'fio performance collector'*) printf -v "$1" y ;;
            *) printf -v "$1" n ;;
        esac
    }
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
