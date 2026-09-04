#!/usr/bin/env bash
# Remove legacy notification provisioning only after its migration is complete.
set -Eeuo pipefail

[[ $# -ge 1 \
    && ( ( $# -eq 1 && $1 == fresh ) \
        || ( $# -le 2 && $1 == upgrade ) ) ]] || {
    printf 'usage: retire-native-notifications.sh fresh | upgrade [previous-version]\n' >&2
    exit 64
}

root=${PVE_TOOLBOX_MAINTAINER_ROOT:-}
[[ -z $root || ( $root == /* && -d $root && ! -L $root ) ]] || {
    printf 'pve-toolbox: refusing unsafe package root: %s\n' "$root" >&2
    exit 1
}

module_dir="$root/usr/lib/pve-toolbox/modules/native-notifications"
package_helper="$root/usr/bin/pve-toolbox-native-notify"
legacy_helper="$root/usr/local/bin/pve-toolbox-native-notify"
conf="$root/etc/pve-toolbox/native-notifications.conf"
state="$root/var/lib/pve-toolbox/native-notifications.state"
backups="$root/var/lib/pve-toolbox/native-notifications-backups"
migration_state="$root/var/lib/pve-toolbox/migrations.state"

remove_tree() {
    local path=$1
    [[ ! -e $path && ! -L $path ]] && return 0
    [[ -d $path && ! -L $path ]] || {
        printf 'pve-toolbox: refusing unsafe obsolete path: %s\n' "$path" >&2
        return 1
    }
    rm -rf -- "$path"
}

migration_complete() {
    local mode
    [[ -f $migration_state && ! -L $migration_state \
        && $(stat -c '%u' "$migration_state") -eq $EUID ]] || return 1
    mode=$(stat -c '%a' "$migration_state")
    (( (8#$mode & 022) == 0 )) || return 1
    [[ $(grep -Fxc 010-native-notification-ownership "$migration_state") -eq 1 ]]
}

if [[ $1 == fresh ]]; then
    [[ ! -e $conf && ! -L $conf && ! -e $state && ! -L $state ]] || {
        printf 'pve-toolbox: legacy notification state needs an upgrade migration; package cleanup stopped\n' >&2
        exit 1
    }
    remove_tree "$module_dir"
    exit 0
fi

if ! migration_complete; then
    if [[ -n ${2:-} ]] && dpkg --validate-version "$2" >/dev/null 2>&1 \
        && dpkg --compare-versions "$2" ge 0.7.0 \
        && [[ ! -e $conf && ! -L $conf \
            && ! -e $state && ! -L $state \
            && ! -e $backups && ! -L $backups \
            && ! -e $legacy_helper && ! -L $legacy_helper ]]; then
        # A package first installed after provisioning was retired has no
        # migration to record. Later upgrades may safely discard only the
        # compatibility module that dpkg has unpacked again.
        remove_tree "$module_dir"
        exit 0
    fi
    printf 'pve-toolbox: notification migration is not recorded; obsolete provisioning was retained\n' >&2
    exit 1
fi
[[ ! -e $conf && ! -L $conf && ! -e $state && ! -L $state ]] || {
    printf 'pve-toolbox: notification migration left legacy ownership files; obsolete provisioning was retained\n' >&2
    exit 1
}

remove_tree "$module_dir"
remove_tree "$backups"
if [[ -e $legacy_helper || -L $legacy_helper ]]; then
    if [[ -f $legacy_helper && ! -L $legacy_helper \
        && -f $package_helper && ! -L $package_helper \
        && $legacy_helper -ef $package_helper ]]; then
        rm -f -- "$legacy_helper"
    elif [[ -f $legacy_helper && ! -L $legacy_helper \
        && -f $package_helper && ! -L $package_helper ]] \
        && cmp -s "$legacy_helper" "$package_helper"; then
        rm -f -- "$legacy_helper"
    else
        printf 'pve-toolbox: kept modified legacy notification helper: %s\n' \
            "$legacy_helper" >&2
    fi
fi
