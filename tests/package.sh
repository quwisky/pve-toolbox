#!/usr/bin/env bash
# Build and inspect the Debian package without installing it on the test host.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

commands=(dpkg-deb)
[[ -n ${PACKAGE_DEB:-} ]] || commands+=(dpkg-buildpackage)
[[ -z ${PACKAGE_DEB_SHA256:-} ]] || commands+=(sha256sum)
for command in "${commands[@]}"; do
    if ! command -v "$command" >/dev/null 2>&1; then
        [[ ${PACKAGING_TEST_REQUIRED:-0} == 1 ]] && fail "$command is required"
        printf 'skip package test, no %s\n' "$command"
        exit 0
    fi
done
if [[ -z ${PACKAGE_DEB:-} ]] && ! dpkg-checkbuilddeps >/dev/null 2>&1; then
    [[ ${PACKAGING_TEST_REQUIRED:-0} == 1 ]] && fail "Debian build dependencies are missing"
    printf 'skip package test, Debian build dependencies are missing\n'
    exit 0
fi

WORK=$(mktemp -d)
PACKAGE_TOUCHED=0
BACKUP_TOUCHED=0
cleanup() {
    status=$?
    trap - EXIT
    if [[ $PACKAGE_TOUCHED -eq 1 ]]; then
        if ! dpkg --purge pve-toolbox >/dev/null; then
            printf 'FAIL could not purge pve-toolbox during cleanup\n' >&2
            status=1
        fi
    fi
    if [[ $BACKUP_TOUCHED -eq 1 ]]; then
        if [[ -d /var/backups/pve-toolbox && ! -L /var/backups/pve-toolbox ]]; then
            rm -rf -- /var/backups/pve-toolbox
        else
            printf 'FAIL refusing unsafe package-test backup cleanup\n' >&2
            status=1
        fi
    fi
    if ! rm -rf -- "$WORK"; then
        printf 'FAIL could not remove package-test workspace: %s\n' "$WORK" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$WORK/src"
if [[ -n ${PACKAGE_DEB:-} ]]; then
    if [[ $PACKAGE_DEB == /* ]]; then
        deb=$PACKAGE_DEB
    else
        deb="$ROOT/$PACKAGE_DEB"
    fi
    [[ -f $deb && ! -L $deb ]] || fail "prebuilt package is missing or unsafe: $deb"
else
    tar --exclude=.git --exclude=site --exclude='*.deb' -cf - . \
        | tar -xf - -C "$WORK/src"
    (cd "$WORK/src" && dpkg-buildpackage --build=binary --no-sign >/dev/null)
    deb=$(find "$WORK" -maxdepth 1 -name 'pve-toolbox_*_all.deb' -print -quit)
    [[ -n $deb ]] || fail "dpkg-buildpackage produced no architecture-all package"
fi

if [[ -n ${PACKAGE_DEB_SHA256:-} ]]; then
    [[ $PACKAGE_DEB_SHA256 =~ ^[0-9a-f]{64}$ ]] \
        || fail "PACKAGE_DEB_SHA256 is not a lowercase SHA-256 digest"
    actual_sha=$(sha256sum "$deb" | awk '{print $1}')
    [[ $actual_sha == "$PACKAGE_DEB_SHA256" ]] \
        || fail "prebuilt package digest changed before package validation"
fi

mkdir "$WORK/control" "$WORK/root"
dpkg-deb --control "$deb" "$WORK/control"
dpkg-deb --extract "$deb" "$WORK/root"

expected_manifest="$WORK/expected-runtime-manifest"
actual_manifest="$WORK/actual-runtime-manifest"
{
    printf '%s\n' VERSION
    printf '%s\n' run-migrations.sh
    for source in "$ROOT"/lib/*.sh; do
        printf 'lib/%s\n' "${source##*/}"
    done
    while IFS= read -r -d '' source; do
        printf '%s\n' "${source#"$ROOT/"}"
    done < <(find "$ROOT/modules" -mindepth 2 -type f \
        ! -path "$ROOT/modules/_*/*" -print0)
} | LC_ALL=C sort > "$expected_manifest"
find "$WORK/root/usr/lib/pve-toolbox" -type f -printf '%P\n' \
    | LC_ALL=C sort > "$actual_manifest"
cmp -s "$expected_manifest" "$actual_manifest" \
    || fail "package runtime manifest differs from source"

for source in "$ROOT"/lib/*.sh; do
    target="$WORK/root/usr/lib/pve-toolbox/lib/${source##*/}"
    cmp -s "$source" "$target" || fail "packaged lib/${source##*/} differs from source"
    expected_mode=644
    [[ -x $source ]] && expected_mode=755
    [[ $(stat -c '%a' "$target") == "$expected_mode" ]] \
        || fail "packaged lib/${source##*/} has the wrong mode"
done
cmp -s "$ROOT/scripts/run-migrations.sh" \
    "$WORK/root/usr/lib/pve-toolbox/run-migrations.sh" \
    || fail "packaged migration runner differs from source"
[[ $(stat -c '%a' "$WORK/root/usr/lib/pve-toolbox/run-migrations.sh") == 755 ]] \
    || fail "packaged migration runner has the wrong mode"
[[ -d $WORK/root/usr/lib/pve-toolbox/migrations ]] \
    || fail "package omitted the migration directory"
while IFS= read -r -d '' source; do
    relative=${source#"$ROOT/"}
    target="$WORK/root/usr/lib/pve-toolbox/$relative"
    cmp -s "$source" "$target" || fail "packaged $relative differs from source"
    expected_mode=644
    [[ -x $source ]] && expected_mode=755
    [[ $(stat -c '%a' "$target") == "$expected_mode" ]] \
        || fail "packaged $relative has the wrong mode"
done < <(find "$ROOT/modules" -mindepth 2 -type f ! -path "$ROOT/modules/_*/*" -print0)
for target in \
    "$WORK/root/usr/bin/pve-toolbox" \
    "$WORK/root/usr/share/man/man1/pve-toolbox.1.gz" \
    "$WORK/root/usr/share/bash-completion/completions/pve-toolbox" \
    "$WORK/root/usr/share/zsh/vendor-completions/_pve-toolbox"
do
    [[ -f $target ]] || fail "package omitted ${target#"$WORK/root"}"
done
cmp -s "$ROOT/pve-toolbox" "$WORK/root/usr/bin/pve-toolbox" \
    || fail "packaged launcher differs from source"
cmp -s "$ROOT/completions/pve-toolbox.bash" \
    "$WORK/root/usr/share/bash-completion/completions/pve-toolbox" \
    || fail "packaged Bash completion differs from source"
cmp -s "$ROOT/completions/_pve-toolbox" \
    "$WORK/root/usr/share/zsh/vendor-completions/_pve-toolbox" \
    || fail "packaged Zsh completion differs from source"
[[ $(<"$WORK/root/usr/lib/pve-toolbox/VERSION") == "$(<VERSION)" ]] \
    || fail "packaged VERSION differs from source"
[[ ! -e $WORK/root/usr/lib/pve-toolbox/modules/_template ]] \
    || fail "package shipped the module template"
pass "package layout matches every runtime source"

control=$(dpkg-deb --field "$deb")
expected_version=$(<VERSION)
[[ $(dpkg-deb --field "$deb" Package) == pve-toolbox ]] \
    || fail "package has the wrong name"
[[ $(dpkg-deb --field "$deb" Version) == "$expected_version" ]] \
    || fail "package version does not match VERSION"
[[ $control == *'Architecture: all'* ]] || fail "package architecture is not all"
[[ $control == *'Depends: curl, jq'* ]] || fail "hard dependencies are incomplete"
[[ $control == *'Recommends: whiptail, zfsutils-linux'* ]] \
    || fail "recommended dependencies are incomplete"
[[ $control == *'Suggests: smartmontools, sanoid'* ]] \
    || fail "suggested dependencies are incomplete"
pass "package metadata"

[[ ! -e $WORK/control/conffiles ]] || fail "runtime config was declared as conffiles"
grep -q '/usr/local/bin/pve-toolbox' "$WORK/control/postinst" \
    || fail "postinst does not warn about a shadowing checkout"
grep -q 'targets Debian 13 (trixie) / PVE 9' "$WORK/control/postinst" \
    || fail "postinst does not warn on unsupported hosts"
grep -Fq '[ "$1" = configure ] && [ -n "${2:-}" ]' "$WORK/control/postinst" \
    || fail "postinst does not limit migrations to package upgrades"
grep -Fq '/usr/lib/pve-toolbox/run-migrations.sh "$2"' "$WORK/control/postinst" \
    || fail "postinst does not run package migrations"
grep -q '\[ "$1" = purge \]' "$WORK/control/postrm" \
    || fail "postrm does not distinguish purge from remove"
[[ $(stat -c '%a' "$WORK/root/etc/pve-toolbox") == 750 ]] \
    || fail "/etc/pve-toolbox is not mode 0750"
[[ $(stat -c '%a' "$WORK/root/var/lib/pve-toolbox") == 755 ]] \
    || fail "/var/lib/pve-toolbox is not mode 0755"
version=$(PVE_TOOLBOX_ROOT="$WORK/root/usr/lib/pve-toolbox" \
    "$WORK/root/usr/bin/pve-toolbox" --version)
[[ $version == "pve-toolbox $expected_version" ]] || fail "installed version is wrong: $version"
pass "package runtime paths and lifecycle"

if [[ ${PACKAGING_INSTALL_TEST_REQUIRED:-0} == 1 ]]; then
    [[ $EUID -eq 0 ]] || fail "the package install lifecycle test requires root"
    if dpkg-query -W -f='${db:Status-Status}' pve-toolbox 2>/dev/null \
        | grep -q '^installed$'; then
        fail "refusing to replace an existing pve-toolbox package"
    fi
    for path in /usr/bin/pve-toolbox /etc/pve-toolbox /var/lib/pve-toolbox \
        /var/backups/pve-toolbox; do
        [[ ! -e $path && ! -L $path ]] \
            || fail "refusing to replace an existing package path: $path"
    done
    for dependency in curl jq; do
        dpkg-query -W -f='${db:Status-Status}' "$dependency" 2>/dev/null \
            | grep -q '^installed$' || fail "$dependency must be installed for the lifecycle test"
    done

    PACKAGE_TOUCHED=1
    dpkg -i "$deb" >/dev/null
    [[ $(/usr/bin/pve-toolbox --version) == "pve-toolbox $expected_version" ]] \
        || fail "the installed package did not run"
    [[ ! -e /var/lib/pve-toolbox/migrations.state \
        && ! -e /var/backups/pve-toolbox/migrations ]] \
        || fail "a fresh install ran or initialized package migrations"

    printf 'FORMAT=old\n' > /etc/pve-toolbox/migration-test.conf
    chmod 0640 /etc/pve-toolbox/migration-test.conf
    dpkg-deb --raw-extract "$deb" "$WORK/upgrade-success"
    success_version="${expected_version}+migrationtest1"
    sed -i "s/^Version: .*/Version: $success_version/" \
        "$WORK/upgrade-success/DEBIAN/control"
    rm -f -- "$WORK/upgrade-success/DEBIAN/md5sums"
    success_migration="$WORK/upgrade-success/usr/lib/pve-toolbox/migrations/900-package-test.sh"
    printf 'MIGRATION_TARGET_VERSION=%q\n' "$success_version" > "$success_migration"
    cat >> "$success_migration" <<'MIGRATION'
MIGRATION_FILES=(/etc/pve-toolbox/migration-test.conf)
MIGRATION_UNITS=()
migration_apply() {
    [[ $(</etc/pve-toolbox/migration-test.conf) == FORMAT=old ]] || return 1
    printf 'FORMAT=current\n' > /etc/pve-toolbox/migration-test.conf
    printf '%s\n' "$PVE_TOOLBOX_PREVIOUS_VERSION" \
        > /var/lib/pve-toolbox/migration-test.previous
    printf 'applied\n' >> /var/lib/pve-toolbox/migration-test.calls
}
MIGRATION
    chmod 0644 "$success_migration"
    dpkg-deb --build "$WORK/upgrade-success" "$WORK/upgrade-success.deb" >/dev/null
    BACKUP_TOUCHED=1
    dpkg -i "$WORK/upgrade-success.deb" >/dev/null
    [[ $(</etc/pve-toolbox/migration-test.conf) == FORMAT=current ]] \
        || fail "package upgrade did not migrate configuration"
    [[ $(stat -c '%a' /etc/pve-toolbox/migration-test.conf) == 640 ]] \
        || fail "package migration changed configuration permissions"
    [[ $(</var/lib/pve-toolbox/migration-test.previous) == "$expected_version" ]] \
        || fail "package migration did not receive the previous version"
    grep -Fxq 900-package-test /var/lib/pve-toolbox/migrations.state \
        || fail "package upgrade did not record its migration"
    package_backup=$(find /var/backups/pve-toolbox/migrations \
        -path '*/files/etc/pve-toolbox/migration-test.conf' -type f -print -quit)
    [[ -n $package_backup && $(<"$package_backup") == FORMAT=old ]] \
        || fail "package upgrade did not retain the original configuration"
    dpkg -i "$WORK/upgrade-success.deb" >/dev/null
    [[ $(grep -c '^applied$' /var/lib/pve-toolbox/migration-test.calls) -eq 1 ]] \
        || fail "reinstall reran a completed package migration"

    printf 'RETRY=old\n' > /etc/pve-toolbox/migration-retry.conf
    chmod 0600 /etc/pve-toolbox/migration-retry.conf
    dpkg-deb --raw-extract "$deb" "$WORK/upgrade-retry"
    retry_version="${expected_version}+migrationtest2"
    sed -i "s/^Version: .*/Version: $retry_version/" \
        "$WORK/upgrade-retry/DEBIAN/control"
    rm -f -- "$WORK/upgrade-retry/DEBIAN/md5sums"
    retry_migration="$WORK/upgrade-retry/usr/lib/pve-toolbox/migrations/910-package-retry.sh"
    printf 'MIGRATION_TARGET_VERSION=%q\n' "$retry_version" > "$retry_migration"
    cat >> "$retry_migration" <<'MIGRATION'
MIGRATION_FILES=(/etc/pve-toolbox/migration-retry.conf)
MIGRATION_UNITS=()
migration_apply() {
    printf 'RETRY=partial\n' > /etc/pve-toolbox/migration-retry.conf
    [[ -f /var/lib/pve-toolbox/allow-package-retry ]] || return 1
    printf 'RETRY=current\n' > /etc/pve-toolbox/migration-retry.conf
}
MIGRATION
    chmod 0644 "$retry_migration"
    dpkg-deb --build "$WORK/upgrade-retry" "$WORK/upgrade-retry.deb" >/dev/null
    retry_output=""
    retry_rc=0
    retry_output=$(dpkg -i "$WORK/upgrade-retry.deb" 2>&1) || retry_rc=$?
    [[ $retry_rc -ne 0 && $retry_output == *'910-package-retry'* \
        && $retry_output == *'restored'* ]] \
        || fail "failed package migration did not stop configuration clearly"
    [[ $(</etc/pve-toolbox/migration-retry.conf) == RETRY=old ]] \
        || fail "failed package migration did not restore configuration"
    [[ $(stat -c '%a' /etc/pve-toolbox/migration-retry.conf) == 600 ]] \
        || fail "failed package migration changed configuration permissions"
    if grep -Fxq 910-package-retry /var/lib/pve-toolbox/migrations.state; then
        fail "failed package migration was recorded as complete"
    fi
    : > /var/lib/pve-toolbox/allow-package-retry
    dpkg --configure pve-toolbox >/dev/null
    [[ $(</etc/pve-toolbox/migration-retry.conf) == RETRY=current ]] \
        || fail "package configuration retry did not complete migration"
    grep -Fxq 910-package-retry /var/lib/pve-toolbox/migrations.state \
        || fail "retried package migration was not recorded"
    pass "dpkg upgrades migrate, roll back, and retry configuration"

    printf 'INTERRUPTED=old\n' > /etc/pve-toolbox/migration-interrupted.conf
    chmod 0640 /etc/pve-toolbox/migration-interrupted.conf
    dpkg-deb --raw-extract "$deb" "$WORK/upgrade-interrupted"
    interrupted_version="${expected_version}+migrationtest3"
    sed -i "s/^Version: .*/Version: $interrupted_version/" \
        "$WORK/upgrade-interrupted/DEBIAN/control"
    rm -f -- "$WORK/upgrade-interrupted/DEBIAN/md5sums"
    interrupted_migration="$WORK/upgrade-interrupted/usr/lib/pve-toolbox/migrations/920-package-interrupted.sh"
    printf 'MIGRATION_TARGET_VERSION=%q\n' "$interrupted_version" \
        > "$interrupted_migration"
    cat >> "$interrupted_migration" <<'MIGRATION'
MIGRATION_FILES=(/etc/pve-toolbox/migration-interrupted.conf)
MIGRATION_UNITS=()
migration_apply() {
    if [[ ! -f /var/lib/pve-toolbox/resume-package-interruption ]]; then
        printf 'INTERRUPTED=partial\n' > /etc/pve-toolbox/migration-interrupted.conf
        : > /var/lib/pve-toolbox/package-interruption-ready
        while true; do sleep 0.1; done
    fi
    cat /etc/pve-toolbox/migration-interrupted.conf \
        > /var/lib/pve-toolbox/package-interruption-observed
    printf 'INTERRUPTED=current\n' > /etc/pve-toolbox/migration-interrupted.conf
}
MIGRATION
    chmod 0644 "$interrupted_migration"
    dpkg-deb --build "$WORK/upgrade-interrupted" \
        "$WORK/upgrade-interrupted.deb" >/dev/null
    setsid dpkg -i "$WORK/upgrade-interrupted.deb" >/dev/null 2>&1 &
    interrupted_pid=$!
    for _ in {1..100}; do
        [[ -e /var/lib/pve-toolbox/package-interruption-ready ]] && break
        sleep 0.05
    done
    if [[ ! -e /var/lib/pve-toolbox/package-interruption-ready ]]; then
        kill -KILL -- "-$interrupted_pid" 2>/dev/null || true
        wait "$interrupted_pid" 2>/dev/null || true
        fail "package interruption fixture never entered its migration"
    fi
    kill -KILL -- "-$interrupted_pid"
    wait "$interrupted_pid" 2>/dev/null || true
    [[ $(</etc/pve-toolbox/migration-interrupted.conf) == INTERRUPTED=partial \
        && -f /var/lib/pve-toolbox/migration.pending ]] \
        || fail "interrupted package upgrade left no recoverable transaction"
    : > /var/lib/pve-toolbox/resume-package-interruption
    dpkg --configure pve-toolbox >/dev/null
    [[ $(</var/lib/pve-toolbox/package-interruption-observed) == INTERRUPTED=old \
        && $(</etc/pve-toolbox/migration-interrupted.conf) == INTERRUPTED=current ]] \
        || fail "package retry did not restore before resuming interruption"
    [[ ! -e /var/lib/pve-toolbox/migration.pending ]] \
        || fail "package retry retained its pending transaction"
    grep -Fxq 920-package-interrupted /var/lib/pve-toolbox/migrations.state \
        || fail "resumed package migration was not recorded"
    pass "dpkg upgrade interruption restores before retry"

    printf 'keep\n' > /etc/pve-toolbox/package-test.conf
    printf 'keep\n' > /var/lib/pve-toolbox/package-test.state
    dpkg --remove pve-toolbox >/dev/null
    [[ -f /etc/pve-toolbox/package-test.conf ]] \
        || fail "package removal deleted runtime config"
    [[ -f /var/lib/pve-toolbox/package-test.state ]] \
        || fail "package removal deleted runtime state"
    dpkg -i "$deb" >/dev/null
    dpkg --purge pve-toolbox >/dev/null
    [[ ! -e /etc/pve-toolbox ]] || fail "package purge retained runtime config"
    [[ ! -e /var/lib/pve-toolbox ]] || fail "package purge retained runtime state"
    [[ -d /var/backups/pve-toolbox/migrations ]] \
        || fail "package purge deleted retained migration backups"
    rm -rf -- /var/backups/pve-toolbox
    BACKUP_TOUCHED=0
    PACKAGE_TOUCHED=0
    pass "dpkg install, remove and purge lifecycle"
fi
