#!/usr/bin/env bash
# Run package-owned, versioned migrations during a Debian package upgrade.
set -Eeuo pipefail
export LC_ALL=C

if [[ $# -ne 1 || -z $1 ]]; then
    printf 'usage: run-migrations.sh <previous-package-version>\n' >&2
    exit 64
fi

MIGRATION_DIR=${PVE_TOOLBOX_MIGRATION_DIR:-/usr/lib/pve-toolbox/migrations}
CONF_DIR=${PVE_TOOLBOX_CONF_DIR:-/etc/pve-toolbox}
STATE_DIR=${PVE_TOOLBOX_STATE_DIR:-/var/lib/pve-toolbox}
BACKUP_ROOT=${PVE_TOOLBOX_MIGRATION_BACKUP_DIR:-/var/backups/pve-toolbox/migrations}
RUN_DIR=${PVE_TOOLBOX_RUN_DIR:-/run/pve-toolbox}
PREVIOUS_VERSION=$1

[[ -d $MIGRATION_DIR ]] || exit 0

shopt -s nullglob
migrations=("$MIGRATION_DIR"/*.sh)
[[ ${#migrations[@]} -gt 0 ]] || exit 0

command -v flock >/dev/null 2>&1 \
    || { printf 'pve-toolbox: flock is required to run package migrations\n' >&2; exit 69; }

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

managed_file_path() {
    local path=$1 parent=${1%/*}
    [[ $path == /* && $path != *$'\n'* && $path != *$'\t'* ]] || return 1
    [[ $parent == "$CONF_DIR" || $parent == "$STATE_DIR" ]] || return 1
    [[ $path != "$STATE_DIR/migrations.state" \
        && $path != "$STATE_DIR/migration.pending" ]]
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

backup_files() {
    local backup=$1 path relative
    mkdir -p -- "$backup/files"
    chmod 0700 -- "$backup" "$backup/files"
    : > "$backup/manifest"
    chmod 0600 -- "$backup/manifest"
    for path in "${MIGRATION_FILES[@]}"; do
        managed_file_path "$path" \
            || { printf 'pve-toolbox: invalid migration path: %q\n' "$path" >&2; return 1; }
        if [[ -L $path || ( -e $path && ! -f $path ) ]]; then
            printf 'pve-toolbox: refusing unsafe migration path: %s\n' "$path" >&2
            return 1
        fi
        if [[ -f $path ]]; then
            relative=${path#/}
            mkdir -p -- "$backup/files/${relative%/*}"
            cp -a -- "$path" "$backup/files/$relative"
            printf 'present\t%s\n' "$path" >> "$backup/manifest"
        else
            printf 'absent\t%s\n' "$path" >> "$backup/manifest"
        fi
    done
}

backup_and_stop_units() {
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
        systemctl stop "$unit" >/dev/null 2>&1 || {
            printf 'pve-toolbox: could not stop migration unit: %s\n' "$unit" >&2
            return 1
        }
    done
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

restore_files() {
    local backup=$1 kind path relative
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
                ;;
            *) return 1 ;;
        esac
    done < "$backup/manifest"
}

restore_units() {
    local backup=$1 unit enabled active failed=0
    [[ -s $backup/units ]] || return 0
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    while IFS=$'\t' read -r unit enabled active; do
        if [[ $enabled -eq 1 ]]; then
            systemctl enable "$unit" >/dev/null 2>&1 || failed=1
        else
            systemctl disable "$unit" >/dev/null 2>&1 || true
        fi
        if [[ $active -eq 1 ]]; then
            systemctl start "$unit" >/dev/null 2>&1 || failed=1
        else
            systemctl stop "$unit" >/dev/null 2>&1 || true
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
    local file=$1 id backup mode
    id=${file##*/}; id=${id%.sh}
    [[ $id =~ ^[0-9][0-9A-Za-z._-]*$ ]] \
        || { printf 'pve-toolbox: invalid migration filename: %s\n' "${file##*/}" >&2; return 1; }
    completed "$id" && return 0
    [[ -f $file && ! -L $file ]] \
        || { printf 'pve-toolbox: refusing unsafe migration: %s\n' "$file" >&2; return 1; }
    mode=$(stat -c '%a' "$file")
    (( (8#$mode & 022) == 0 )) \
        || { printf 'pve-toolbox: migration is group/world writable: %s\n' "$file" >&2; return 1; }

    unset -f migration_apply 2>/dev/null || true
    unset MIGRATION_FILES MIGRATION_UNITS
    declare -ag MIGRATION_FILES=() MIGRATION_UNITS=()
    # Package-owned migration fragments only define metadata and migration_apply.
    # shellcheck source=/dev/null
    source "$file"
    declare -F migration_apply >/dev/null \
        || { printf 'pve-toolbox: migration has no migration_apply: %s\n' "$file" >&2; return 1; }
    [[ $(declare -p MIGRATION_FILES 2>/dev/null) == 'declare -a '* \
        && $(declare -p MIGRATION_UNITS 2>/dev/null) == 'declare -a '* ]] \
        || { printf 'pve-toolbox: migration metadata must use indexed arrays: %s\n' "$file" >&2; return 1; }

    ensure_safe_directory "$BACKUP_ROOT" 0700
    backup="$BACKUP_ROOT/$id-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -- "$backup"
    backup_files "$backup"
    if ! backup_and_stop_units "$backup"; then
        restore_units "$backup" || true
        return 1
    fi

    if ! write_pending "$id" "$backup"; then
        restore_units "$backup" || true
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
    if ! preserve_file_metadata "$backup" \
        || ! restore_units "$backup" \
        || ! record_completed "$id"; then
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
