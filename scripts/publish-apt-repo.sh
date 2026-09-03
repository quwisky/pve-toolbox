#!/usr/bin/env bash
# Publish a package into a signed, rollback-capable trixie APT repository.
set -Eeuo pipefail

[[ $# -eq 5 ]] || {
    printf 'usage: %s <repository-dir> <deb> <fingerprint> <public-key> <retain-count>\n' \
        "$0" >&2
    exit 2
}

repo_dir=$1
deb=$2
fingerprint=${3^^}
public_key=$4
retain_count=$5

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

for command in apt-ftparchive awk chmod cmp cp date dpkg-deb dpkg-scanpackages \
    find gpg gpgv gzip install mktemp realpath rsync sha256sum sort stat; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -f $deb && ! -L $deb ]] || fail "package is missing or unsafe: $deb"
[[ -f $public_key && ! -L $public_key ]] \
    || fail "public key is missing or unsafe: $public_key"
[[ $fingerprint =~ ^[0-9A-F]{40}$ ]] \
    || fail "expected a 40-character signing-key fingerprint"
[[ $retain_count =~ ^[1-9][0-9]*$ && $retain_count -le 20 ]] \
    || fail "retain-count must be between 1 and 20"

repo_abs=$(realpath -m -- "$repo_dir")
[[ $repo_abs != / ]] || fail "refusing to publish into the filesystem root"
if [[ -e $repo_abs || -L $repo_abs ]]; then
    [[ -d $repo_abs && ! -L $repo_abs ]] \
        || fail "repository path is not a safe directory: $repo_abs"
    repo_exists=1
else
    parent=$(dirname -- "$repo_abs")
    [[ -d $parent && ! -L $parent ]] \
        || fail "repository parent is not a safe directory: $parent"
    repo_exists=0
fi
if [[ $repo_exists -eq 1 ]]; then
    unsafe_link=$(find "$repo_abs" -path "$repo_abs/.git" -prune -o -type l -print -quit)
    [[ -z $unsafe_link ]] || fail "repository contains an unsafe symlink: $unsafe_link"
fi

package=$(dpkg-deb --field "$deb" Package)
version=$(dpkg-deb --field "$deb" Version)
architecture=$(dpkg-deb --field "$deb" Architecture)
[[ $package == pve-toolbox ]] || fail "package name must be pve-toolbox"
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "package version must be stable semantic versioning"
[[ $architecture == all ]] || fail "package architecture must be all"

public_fingerprint=$(gpg --batch --with-colons --show-keys "$public_key" \
    | awk -F: '$1 == "fpr" { print toupper($10); exit }')
[[ $public_fingerprint == "$fingerprint" ]] \
    || fail "signing key does not match the committed public key"
gpg --batch --list-secret-keys "$fingerprint" >/dev/null 2>&1 \
    || fail "signing secret key is unavailable"

work=$(mktemp -d)
stage="$work/stage"
backup="$work/backup"
cleanup() {
    status=$?
    trap - EXIT
    if ! rm -rf -- "$work"; then
        printf 'error: could not remove publisher workspace: %s\n' "$work" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p "$stage/pool/main/p/pve-toolbox" "$backup" "$work/package-root"
dpkg-deb --extract "$deb" "$work/package-root"
packaged_changelog="$work/package-root/usr/share/doc/pve-toolbox/changelog.gz"
[[ -f $packaged_changelog && ! -L $packaged_changelog ]] \
    || fail "package does not contain a safe Debian changelog"
gzip -dc "$packaged_changelog" > "$work/package-changelog"
release_date=$(awk '
    /^ -- .*  / {
        sub(/^ -- .*  /, "")
        print
        exit
    }
' "$work/package-changelog")
[[ -n $release_date ]] || fail "package changelog has no release date"
release_epoch=$(LC_ALL=C date -d "$release_date" +%s) \
    || fail "package changelog release date is invalid"

copy_package() {
    local source=$1
    local source_package source_version source_architecture target
    [[ -f $source && ! -L $source ]] || fail "unsafe package in repository: $source"
    source_package=$(dpkg-deb --field "$source" Package)
    source_version=$(dpkg-deb --field "$source" Version)
    source_architecture=$(dpkg-deb --field "$source" Architecture)
    [[ $source_package == pve-toolbox ]] || fail "unexpected package in repository: $source"
    [[ $source_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "unstable package version in repository: $source_version"
    [[ $source_architecture == all ]] \
        || fail "unexpected package architecture in repository: $source_architecture"
    target="$stage/pool/main/p/pve-toolbox/pve-toolbox_${source_version}_all.deb"
    if [[ -e $target ]]; then
        cmp -s "$source" "$target" \
            || fail "pve-toolbox $source_version exists with different bytes"
    else
        cp -p -- "$source" "$target"
        chmod 0644 "$target"
    fi
}

if [[ -d $repo_abs/pool ]]; then
    while IFS= read -r -d '' existing; do
        copy_package "$existing"
    done < <(find "$repo_abs/pool" -type f -name '*.deb' -print0)
fi
copy_package "$deb"

mapfile -t retained < <(
    while IFS= read -r -d '' candidate; do
        candidate_version=$(dpkg-deb --field "$candidate" Version)
        printf '%s\t%s\n' "$candidate_version" "$candidate"
    done < <(find "$stage/pool" -type f -name '*.deb' -print0) \
        | sort -t $'\t' -k1,1Vr
)
[[ ${#retained[@]} -gt 0 ]] || fail "repository contains no packages"
for ((index = retain_count; index < ${#retained[@]}; index++)); do
    old_package=${retained[$index]#*$'\t'}
    [[ $old_package == "$stage/pool/"* ]] \
        || fail "refusing to prune package outside the staged pool"
    rm -f -- "$old_package"
done

index_dir="$stage/dists/trixie/main/binary-amd64"
mkdir -p "$index_dir"
(
    cd "$stage"
    dpkg-scanpackages --multiversion pool /dev/null > \
        dists/trixie/main/binary-amd64/Packages
)
gzip -n -9 -c "$index_dir/Packages" > "$index_dir/Packages.gz"

release_dir="$stage/dists/trixie"
release_file="$work/Release"
key_epoch=$(gpg --batch --with-colons --list-secret-keys "$fingerprint" \
    | awk -F: '$1 == "sec" { print $6; exit }')
[[ $key_epoch =~ ^[0-9]+$ ]] || fail "signing key has no creation timestamp"
(( key_epoch >= release_epoch )) && release_epoch=$((key_epoch + 1))
release_date=$(LC_ALL=C date -Ru -d "@$release_epoch")
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=pve-toolbox \
    -o APT::FTPArchive::Release::Label=pve-toolbox \
    -o APT::FTPArchive::Release::Suite=trixie \
    -o APT::FTPArchive::Release::Codename=trixie \
    -o APT::FTPArchive::Release::Architectures=amd64 \
    -o APT::FTPArchive::Release::Components=main \
    -o "APT::FTPArchive::Release::Date=$release_date" \
    -o 'APT::FTPArchive::Release::Description=pve-toolbox packages for PVE 9 / Debian 13' \
    release "$release_dir" > "$release_file"
install -m 0644 "$release_file" "$release_dir/Release"
gpg --batch --yes --faked-system-time "$release_epoch" \
    --local-user "$fingerprint" --clearsign \
    --output "$release_dir/InRelease" "$release_dir/Release"
gpg --batch --yes --faked-system-time "$release_epoch" \
    --local-user "$fingerprint" --detach-sign \
    --output "$release_dir/Release.gpg" "$release_dir/Release"
install -m 0644 "$public_key" "$stage/pve-toolbox.asc"
gpg --batch --yes --dearmor \
    --output "$stage/pve-toolbox.gpg" "$public_key"

verify_repository() {
    local repository=$1
    local release_root="$repository/dists/trixie"
    local release="$release_root/Release"
    local keyring="$repository/pve-toolbox.gpg"
    local verified_release="$work/verified-InRelease"
    local required entry expected_hash expected_size relative index
    local actual_hash actual_size
    local packages_seen=0
    local packages_gz_seen=0
    local -a sha256_entries=()

    for required in "$release" "$release_root/InRelease" \
        "$release_root/Release.gpg" "$keyring"; do
        [[ -f $required && ! -L $required ]] || {
            printf 'repository metadata is missing or unsafe: %s\n' "$required" >&2
            return 1
        }
    done
    gpgv --keyring "$keyring" "$release_root/Release.gpg" "$release" \
        >/dev/null 2>&1 || {
        printf 'repository Release signature did not verify\n' >&2
        return 1
    }
    rm -f -- "$verified_release"
    gpgv --keyring "$keyring" --output "$verified_release" \
        "$release_root/InRelease" >/dev/null 2>&1 || {
        printf 'repository InRelease signature did not verify\n' >&2
        return 1
    }
    cmp -s "$release" "$verified_release" || {
        printf 'repository InRelease payload does not match Release\n' >&2
        return 1
    }
    rm -f -- "$verified_release" || {
        printf 'could not remove verified InRelease payload\n' >&2
        return 1
    }

    mapfile -t sha256_entries < <(awk '
        $1 == "SHA256:" { in_sha256 = 1; next }
        in_sha256 && /^[A-Z][A-Za-z0-9-]*:/ { in_sha256 = 0 }
        in_sha256 && NF == 3 { print }
    ' "$release")
    [[ ${#sha256_entries[@]} -eq 2 ]] || {
        printf 'repository Release has an unexpected SHA256 index set\n' >&2
        return 1
    }
    for entry in "${sha256_entries[@]}"; do
        read -r expected_hash expected_size relative <<< "$entry"
        case "$relative" in
            main/binary-amd64/Packages)
                packages_seen=1
                ;;
            main/binary-amd64/Packages.gz)
                packages_gz_seen=1
                ;;
            *)
                printf 'repository Release references an unexpected index: %s\n' \
                    "$relative" >&2
                return 1
                ;;
        esac
        [[ $expected_hash =~ ^[0-9a-fA-F]{64}$ \
            && $expected_size =~ ^[0-9]+$ ]] || {
            printf 'repository Release has invalid index metadata: %s\n' \
                "$relative" >&2
            return 1
        }
        index="$release_root/$relative"
        [[ -f $index && ! -L $index ]] || {
            printf 'repository index is missing or unsafe: %s\n' "$index" >&2
            return 1
        }
        actual_hash=$(sha256sum "$index" | awk '{print $1}')
        actual_size=$(stat -c %s "$index")
        [[ ${expected_hash,,} == "$actual_hash" \
            && $expected_size == "$actual_size" ]] || {
            printf 'repository Release does not match index: %s\n' "$relative" >&2
            return 1
        }
    done
    [[ $packages_seen -eq 1 && $packages_gz_seen -eq 1 ]] || {
        printf 'repository Release omits a required package index\n' >&2
        return 1
    }
}

verify_repository "$stage" || fail "staged repository metadata did not verify"

restore_repository() {
    if [[ $repo_exists -eq 0 ]]; then
        rm -rf -- "$repo_abs"
    else
        rsync -a --checksum --delete --exclude '.git/' "$backup/" "$repo_abs/"
    fi
}

if [[ $repo_exists -eq 0 ]]; then
    mkdir -- "$repo_abs"
else
    rsync -a --checksum --exclude '.git/' "$repo_abs/" "$backup/"
fi
if ! rsync -a --checksum --delete --exclude '.git/' "$stage/" "$repo_abs/"; then
    printf 'error: repository update failed; restoring previous contents\n' >&2
    if ! restore_repository; then
        fail "repository update and rollback both failed"
    fi
    fail "repository update failed and was rolled back"
fi
if ! verify_repository "$repo_abs"; then
    printf 'error: published repository validation failed; restoring previous contents\n' >&2
    if ! restore_repository; then
        fail "repository validation and rollback both failed"
    fi
    fail "repository validation failed and was rolled back"
fi
