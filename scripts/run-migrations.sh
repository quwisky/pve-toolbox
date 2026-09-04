#!/usr/bin/env bash
# Run package-owned, versioned migrations during a Debian package upgrade.
set -Eeuo pipefail
export LC_ALL=C

if [[ $# -ne 1 || -z $1 ]]; then
    printf 'usage: run-migrations.sh <previous-package-version>\n' >&2
    exit 64
fi

MIGRATION_DIR_STRICT=0
if [[ -z ${PVE_TOOLBOX_MIGRATION_DIR+x} ]]; then
    MIGRATION_DIR=/usr/lib/pve-toolbox/migrations
    MIGRATION_DIR_STRICT=1
else
    MIGRATION_DIR=$PVE_TOOLBOX_MIGRATION_DIR
fi
CONF_DIR=${PVE_TOOLBOX_CONF_DIR:-/etc/pve-toolbox}
STATE_DIR=${PVE_TOOLBOX_STATE_DIR:-/var/lib/pve-toolbox}
SYSTEMD_DIR=${PVE_TOOLBOX_SYSTEMD_DIR:-/etc/systemd/system}
BACKUP_ROOT=${PVE_TOOLBOX_MIGRATION_BACKUP_DIR:-/var/backups/pve-toolbox/migrations}
RUN_DIR=${PVE_TOOLBOX_RUN_DIR:-/run/pve-toolbox}
PREVIOUS_VERSION=$1

if [[ ! -e $MIGRATION_DIR && ! -L $MIGRATION_DIR ]]; then
    exit 0
fi
command -v realpath >/dev/null 2>&1 \
    || { printf 'pve-toolbox: realpath is required to validate migrations\n' >&2; exit 69; }
canonical_migration_dir=$(realpath -e -- "$MIGRATION_DIR" 2>/dev/null) || true
[[ -d $MIGRATION_DIR && ! -L $MIGRATION_DIR \
    && $canonical_migration_dir == "$MIGRATION_DIR" ]] || {
    printf 'pve-toolbox: refusing unsafe migration directory: %s\n' \
        "$MIGRATION_DIR" >&2
    exit 1
}
if [[ $MIGRATION_DIR_STRICT -eq 1 ]]; then
    for package_dir in / /usr /usr/lib /usr/lib/pve-toolbox "$MIGRATION_DIR"; do
        package_mode=$(stat -c '%a' "$package_dir")
        [[ $(stat -c '%u' "$package_dir") -eq 0 ]] \
            && (( (8#$package_mode & 022) == 0 )) || {
            printf 'pve-toolbox: migration directory chain is not root-owned and protected: %s\n' \
                "$package_dir" >&2
            exit 1
        }
    done
fi

shopt -s nullglob
migrations=("$MIGRATION_DIR"/*.sh)
[[ ${#migrations[@]} -gt 0 ]] || exit 0

command -v flock >/dev/null 2>&1 \
    || { printf 'pve-toolbox: flock is required to run package migrations\n' >&2; exit 69; }
command -v dpkg >/dev/null 2>&1 \
    || { printf 'pve-toolbox: dpkg is required to run package migrations\n' >&2; exit 69; }
dpkg --validate-version "$PREVIOUS_VERSION" >/dev/null 2>&1 \
    || { printf 'pve-toolbox: invalid previous package version: %s\n' "$PREVIOUS_VERSION" >&2; exit 1; }

ensure_safe_directory() {
    local path=$1 mode=$2
    if [[ -L $path || ( -e $path && ! -d $path ) ]]; then
        printf 'pve-toolbox: refusing unsafe directory: %s\n' "$path" >&2
        return 1
    fi
    mkdir -p -- "$path"
    [[ -d $path && ! -L $path ]] || {
        printf 'pve-toolbox: refusing unsafe directory: %s\n' "$path" >&2
        return 1
    }
    chmod "$mode" -- "$path"
}

ensure_safe_directory "$RUN_DIR" 0700
exec 9> "$RUN_DIR/migrations.lock"
chmod 0600 -- "$RUN_DIR/migrations.lock"
flock -n 9 || {
    printf 'pve-toolbox: another migration run is already active\n' >&2
    exit 75
}
ensure_safe_directory "$STATE_DIR" 0755
ensure_safe_directory "$CONF_DIR" 0750
for state_file in migrations.state migration.pending; do
    if [[ -e $STATE_DIR/$state_file \
        && ( ! -f $STATE_DIR/$state_file || -L $STATE_DIR/$state_file ) ]]; then
        printf 'pve-toolbox: refusing unsafe migration state: %s\n' \
            "$STATE_DIR/$state_file" >&2
        exit 1
    fi
done

completed() {
    [[ -r $STATE_DIR/migrations.state ]] \
        && grep -Fqx -- "$1" "$STATE_DIR/migrations.state"
}

managed_data_file_path() {
    local path=$1 parent=${1%/*}
    [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* ]] || return 1
    [[ $parent == "$CONF_DIR" || $parent == "$STATE_DIR" ]] || return 1
    [[ $path != "$STATE_DIR/migrations.state" \
        && $path != "$STATE_DIR/migration.pending" ]]
}

managed_systemd_file_path() {
    local path=$1 parent relative canonical_systemd_dir
    canonical_systemd_dir=$(realpath -e -- "$SYSTEMD_DIR" 2>/dev/null) || return 1
    [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* \
        && -d $SYSTEMD_DIR && ! -L $SYSTEMD_DIR \
        && $canonical_systemd_dir == "$SYSTEMD_DIR" ]] || return 1
    relative=${path#"$SYSTEMD_DIR/"}
    [[ $relative != "$path" \
        && $relative =~ ^[A-Za-z0-9_.@:-]+\.timer\.d/override\.conf$ ]] \
        || return 1
    parent=${path%/*}
    [[ ! -L $parent && ( ! -e $parent || -d $parent ) ]]
}

managed_file_path() {
    managed_data_file_path "$1" || managed_systemd_file_path "$1"
}

record_completed() {
    local id=$1 tmp
    tmp=$(mktemp "$STATE_DIR/.migrations.state.XXXXXX")
    if [[ -r $STATE_DIR/migrations.state ]]; then
        cat -- "$STATE_DIR/migrations.state" > "$tmp"
    fi
    printf '%s\n' "$id" >> "$tmp"
    chmod 0644 -- "$tmp"
    mv -f -- "$tmp" "$STATE_DIR/migrations.state"
}

backup_one_file() {
    local backup=$1 path=$2 relative
    if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
        printf 'pve-toolbox: refusing unsafe migration path: %s\n' "$path" >&2
        return 1
    fi
    relative=${path#/}
    if [[ -f $path ]]; then
        mkdir -p -- "$backup/files/${relative%/*}"
        cp -a -- "$path" "$backup/files/$relative"
        printf 'present\t%s\n' "$path" >> "$backup/manifest"
    else
        printf 'absent\t%s\n' "$path" >> "$backup/manifest"
    fi
}

backup_files() {
    local backup=$1 path
    mkdir -p -- "$backup/files"
    chmod 0700 -- "$backup" "$backup/files"
    : > "$backup/manifest"
    chmod 0600 -- "$backup/manifest"
    for path in "${MIGRATION_FILES[@]}"; do
        managed_data_file_path "$path" \
            || { printf 'pve-toolbox: invalid migration path: %q\n' "$path" >&2; return 1; }
        backup_one_file "$backup" "$path" || return 1
    done
    for path in "${MIGRATION_SYSTEMD_FILES[@]}"; do
        managed_systemd_file_path "$path" \
            || { printf 'pve-toolbox: invalid migration systemd path: %q\n' "$path" >&2; return 1; }
        backup_one_file "$backup" "$path" || return 1
    done
}

backup_unit_state() {
    local backup=$1 unit enabled active
    : > "$backup/units"
    chmod 0600 -- "$backup/units"
    [[ ${#MIGRATION_UNITS[@]} -gt 0 ]] || return 0
    command -v systemctl >/dev/null 2>&1 \
        || { printf 'pve-toolbox: systemctl is required for this migration\n' >&2; return 1; }
    for unit in "${MIGRATION_UNITS[@]}"; do
        [[ $unit =~ ^[A-Za-z0-9_.@:-]+$ ]] \
            || { printf 'pve-toolbox: invalid migration unit: %s\n' "$unit" >&2; return 1; }
        enabled=0
        active=0
        systemctl is-enabled --quiet "$unit" >/dev/null 2>&1 && enabled=1
        systemctl is-active --quiet "$unit" >/dev/null 2>&1 && active=1
        printf '%s\t%s\t%s\n' "$unit" "$enabled" "$active" >> "$backup/units"
    done
}

stop_units() {
    local backup=$1 unit enabled active
    while IFS=$'\t' read -r unit enabled active; do
        systemctl stop "$unit" >/dev/null 2>&1 || {
            printf 'pve-toolbox: could not stop migration unit: %s\n' "$unit" >&2
            return 1
        }
    done < "$backup/units"
}

preserve_file_metadata() {
    local backup=$1 kind path relative
    while IFS=$'\t' read -r kind path; do
        [[ $kind == present && -f $path ]] || continue
        relative=${path#/}
        chown --reference="$backup/files/$relative" -- "$path"
        chmod --reference="$backup/files/$relative" -- "$path"
    done < "$backup/manifest"
}

validate_file_results() {
    local path
    for path in "${MIGRATION_FILES[@]}"; do
        managed_data_file_path "$path" || return 1
        if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
            printf 'pve-toolbox: unsafe migration result: %s\n' "$path" >&2
            return 1
        fi
    done
    for path in "${MIGRATION_SYSTEMD_FILES[@]}"; do
        managed_systemd_file_path "$path" || return 1
        if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
            printf 'pve-toolbox: unsafe migration result: %s\n' "$path" >&2
            return 1
        fi
    done
}

restore_files() {
    local backup=$1 kind path relative parent
    [[ $backup == "$BACKUP_ROOT/"* && -d $backup && ! -L $backup \
        && -r $backup/manifest ]] || {
        printf 'pve-toolbox: migration backup is missing or unsafe: %s\n' "$backup" >&2
        return 1
    }
    while IFS=$'\t' read -r kind path; do
        managed_file_path "$path" || return 1
        case $kind in
            present)
                relative=${path#/}
                [[ -f $backup/files/$relative && ! -L $backup/files/$relative ]] \
                    || return 1
                [[ ! -e $path || -f $path || -L $path ]] || return 1
                rm -f -- "$path"
                cp -a -- "$backup/files/$relative" "$path"
                ;;
            absent)
                [[ ! -e $path || -f $path || -L $path ]] || return 1
                rm -f -- "$path"
                if managed_systemd_file_path "$path"; then
                    parent=${path%/*}
                    rmdir -- "$parent" 2>/dev/null || true
                fi
                ;;
            *) return 1 ;;
        esac
    done < "$backup/manifest"
}

restore_units() {
    local backup=$1 unit enabled active failed=0
    [[ -s $backup/units ]] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || {
        printf 'pve-toolbox: could not reload systemd during unit restoration\n' >&2
        return 1
    }
    while IFS=$'\t' read -r unit enabled active; do
        if [[ $enabled -eq 1 ]]; then
            systemctl enable "$unit" >/dev/null 2>&1 || {
                printf 'pve-toolbox: could not restore enabled unit: %s\n' "$unit" >&2
                failed=1
            }
        else
            systemctl disable "$unit" >/dev/null 2>&1 || {
                printf 'pve-toolbox: could not restore disabled unit: %s\n' "$unit" >&2
                failed=1
            }
        fi
        if [[ $active -eq 1 ]]; then
            systemctl start "$unit" >/dev/null 2>&1 || {
                printf 'pve-toolbox: could not restore active unit: %s\n' "$unit" >&2
                failed=1
            }
        else
            systemctl stop "$unit" >/dev/null 2>&1 || {
                printf 'pve-toolbox: could not restore inactive unit: %s\n' "$unit" >&2
                failed=1
            }
        fi
    done < "$backup/units"
    [[ $failed -eq 0 ]]
}

restore_transaction() {
    local backup=$1
    restore_files "$backup" || return 1
    restore_units "$backup"
}

write_pending() {
    local id=$1 backup=$2 tmp
    tmp=$(mktemp "$STATE_DIR/.migration.pending.XXXXXX")
    printf '%s\t%s\n' "$id" "$backup" > "$tmp"
    chmod 0600 -- "$tmp"
    mv -f -- "$tmp" "$STATE_DIR/migration.pending"
}

recover_pending() {
    local id backup
    [[ -e $STATE_DIR/migration.pending ]] || return 0
    [[ -f $STATE_DIR/migration.pending && ! -L $STATE_DIR/migration.pending ]] \
        || { printf 'pve-toolbox: pending migration record is unsafe\n' >&2; return 1; }
    IFS=$'\t' read -r id backup < "$STATE_DIR/migration.pending" || true
    [[ $id =~ ^[0-9][0-9A-Za-z._-]*$ && -n $backup ]] \
        || { printf 'pve-toolbox: pending migration record is invalid\n' >&2; return 1; }
    if completed "$id"; then
        rm -f -- "$STATE_DIR/migration.pending"
        return 0
    fi
    restore_transaction "$backup" || {
        printf 'pve-toolbox: could not restore interrupted migration %s from %s\n' \
            "$id" "$backup" >&2
        return 1
    }
    rm -f -- "$STATE_DIR/migration.pending"
    printf 'pve-toolbox: restored interrupted migration %s from %s\n' "$id" "$backup"
}

migration_failed() {
    local id=$1 backup=$2 status=$3
    if restore_transaction "$backup"; then
        rm -f -- "$STATE_DIR/migration.pending"
        printf 'pve-toolbox: migration %s failed; restored files from %s\n' \
            "$id" "$backup" >&2
    else
        printf 'pve-toolbox: migration %s failed and rollback from %s failed\n' \
            "$id" "$backup" >&2
    fi
    return "$status"
}

run_migration() {
    local file=$1 id backup mode declaration restore_after_apply=1
    id=${file##*/}; id=${id%.sh}
    [[ $id =~ ^[0-9][0-9A-Za-z._-]*$ ]] \
        || { printf 'pve-toolbox: invalid migration filename: %s\n' "${file##*/}" >&2; return 1; }
    completed "$id" && return 0
    [[ -f $file && ! -L $file ]] \
        || { printf 'pve-toolbox: refusing unsafe migration: %s\n' "$file" >&2; return 1; }
    if [[ $MIGRATION_DIR_STRICT -eq 1 && $(stat -c '%u' "$file") -ne 0 ]]; then
        printf 'pve-toolbox: migration is not root-owned: %s\n' "$file" >&2
        return 1
    fi
    mode=$(stat -c '%a' "$file")
    (( (8#$mode & 022) == 0 )) \
        || { printf 'pve-toolbox: migration is group/world writable: %s\n' "$file" >&2; return 1; }

    unset -f migration_apply migration_prepare 2>/dev/null || true
    unset MIGRATION_TARGET_VERSION MIGRATION_FILES MIGRATION_SYSTEMD_FILES \
        MIGRATION_UNITS MIGRATION_KEEP_UNIT_STATE
    declare -g MIGRATION_TARGET_VERSION=
    declare -ag MIGRATION_FILES=() MIGRATION_SYSTEMD_FILES=() MIGRATION_UNITS=()
    declare -gi MIGRATION_KEEP_UNIT_STATE=0
    # Package-owned fragments define metadata, an optional read-only prepare
    # hook, and migration_apply.
    # shellcheck source=/dev/null
    source "$file"
    declare -F migration_apply >/dev/null \
        || { printf 'pve-toolbox: migration has no migration_apply: %s\n' "$file" >&2; return 1; }
    declaration=$(declare -p MIGRATION_TARGET_VERSION 2>/dev/null)
    [[ $declaration == 'declare -- '* && -n $MIGRATION_TARGET_VERSION ]] \
        || { printf 'pve-toolbox: migration has no target version: %s\n' "$file" >&2; return 1; }
    dpkg --validate-version "$MIGRATION_TARGET_VERSION" >/dev/null 2>&1 \
        || { printf 'pve-toolbox: migration has invalid target version: %s\n' "$file" >&2; return 1; }
    if dpkg --compare-versions "$PREVIOUS_VERSION" ge "$MIGRATION_TARGET_VERSION"; then
        record_completed "$id"
        return 0
    fi
    if declare -F migration_prepare >/dev/null && ! migration_prepare; then
        printf 'pve-toolbox: migration preparation failed: %s\n' "$file" >&2
        return 1
    fi
    [[ $(declare -p MIGRATION_FILES 2>/dev/null) == 'declare -a '* \
        && $(declare -p MIGRATION_SYSTEMD_FILES 2>/dev/null) == 'declare -a '* \
        && $(declare -p MIGRATION_UNITS 2>/dev/null) == 'declare -a '* \
        && $(declare -p MIGRATION_KEEP_UNIT_STATE 2>/dev/null) == 'declare -i '* \
        && ( $MIGRATION_KEEP_UNIT_STATE -eq 0 || $MIGRATION_KEEP_UNIT_STATE -eq 1 ) ]] \
        || { printf 'pve-toolbox: migration metadata is invalid: %s\n' "$file" >&2; return 1; }
    [[ $MIGRATION_KEEP_UNIT_STATE -eq 0 ]] || restore_after_apply=0

    ensure_safe_directory "$BACKUP_ROOT" 0700
    backup="$BACKUP_ROOT/$id-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -- "$backup"
    backup_files "$backup"
    backup_unit_state "$backup"

    if ! write_pending "$id" "$backup"; then
        return 1
    fi
    if ! stop_units "$backup"; then
        migration_failed "$id" "$backup" 1
        return 1
    fi
    PVE_TOOLBOX_CONF_DIR=$CONF_DIR
    PVE_TOOLBOX_STATE_DIR=$STATE_DIR
    PVE_TOOLBOX_PREVIOUS_VERSION=$PREVIOUS_VERSION
    export PVE_TOOLBOX_CONF_DIR PVE_TOOLBOX_STATE_DIR PVE_TOOLBOX_PREVIOUS_VERSION
    if ! migration_apply; then
        migration_failed "$id" "$backup" 1
        return 1
    fi
    if ! validate_file_results \
        || ! preserve_file_metadata "$backup"; then
        migration_failed "$id" "$backup" 1
        return 1
    fi
    if [[ $restore_after_apply -eq 1 ]] && ! restore_units "$backup"; then
        migration_failed "$id" "$backup" 1
        return 1
    fi
    if ! record_completed "$id"; then
        migration_failed "$id" "$backup" 1
        return 1
    fi
    rm -f -- "$STATE_DIR/migration.pending"
    printf 'pve-toolbox: applied migration %s\n' "$id"
}

if [[ -e $STATE_DIR/migration.pending ]]; then
    ensure_safe_directory "$BACKUP_ROOT" 0700
    recover_pending
fi
for migration in "${migrations[@]}"; do
    run_migration "$migration"
done
