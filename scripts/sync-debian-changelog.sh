#!/usr/bin/env bash
# Synchronize the latest Release Please notes into the Debian changelog.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
VERSION_FILE=${VERSION_FILE:-"$ROOT/VERSION"}
MARKDOWN_CHANGELOG=${MARKDOWN_CHANGELOG:-"$ROOT/CHANGELOG.md"}
DEBIAN_CHANGELOG=${DEBIAN_CHANGELOG:-"$ROOT/debian/changelog"}
DEBIAN_CHANGELOG_DATE=${DEBIAN_CHANGELOG_DATE:-}

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

for command in awk date dpkg dpkg-parsechangelog mktemp; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
for path in "$VERSION_FILE" "$MARKDOWN_CHANGELOG" "$DEBIAN_CHANGELOG"; do
    [[ -f $path && ! -L $path ]] || fail "required input is missing or unsafe: $path"
done

version=$(<"$VERSION_FILE")
[[ $version =~ ^0\.[0-9]+\.[0-9]+$ ]] \
    || fail "VERSION must be a stable pre-1.0 semantic version"
current=$(dpkg-parsechangelog -l"$DEBIAN_CHANGELOG" -S Version)
if dpkg --compare-versions "$current" gt "$version"; then
    fail "refusing to replace newer Debian changelog version $current"
fi

notes=$(awk -v version="$version" '
    BEGIN { gsub(/\./, "\\.", version) }
    $0 ~ "^## \\[?" version "([][( ]|$)" { in_release = 1; next }
    in_release && /^## / { exit }
    in_release && /^[-*] / {
        sub(/^[-*] /, "")
        print "  * " $0
        found = 1
    }
    END { if (!found) exit 1 }
' "$MARKDOWN_CHANGELOG") || fail "CHANGELOG.md has no bullet notes for $version"

maintainer=$(awk '
    /^ -- .*  / {
        sub(/^ -- /, "")
        sub(/  [A-Z][a-z][a-z],.*$/, "")
        print
        exit
    }
' "$DEBIAN_CHANGELOG")
[[ -n $maintainer ]] || fail "could not determine the Debian changelog maintainer"
if [[ -z $DEBIAN_CHANGELOG_DATE ]]; then
    DEBIAN_CHANGELOG_DATE=$(LC_ALL=C date -u -R)
fi
DEBIAN_CHANGELOG_DATE=$(LC_ALL=C date -u -d "$DEBIAN_CHANGELOG_DATE" -R) \
    || fail "DEBIAN_CHANGELOG_DATE is invalid"

tmp=$(mktemp "${DEBIAN_CHANGELOG}.XXXXXX")
cleanup() {
    status=$?
    trap - EXIT
    if [[ -e $tmp ]] && ! rm -f -- "$tmp"; then
        printf 'error: could not remove temporary changelog: %s\n' "$tmp" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT

{
    printf 'pve-toolbox (%s) unstable; urgency=medium\n\n' "$version"
    printf '%s\n' "$notes"
    printf '\n -- %s  %s\n\n' "$maintainer" "$DEBIAN_CHANGELOG_DATE"
    if [[ $current == "$version" ]]; then
        awk '
            skipped == 0 && /^ -- .*  / { skipped = 1; next }
            skipped == 1 && /^$/ { skipped = 2; next }
            skipped == 2 { print }
        ' "$DEBIAN_CHANGELOG"
    else
        cat "$DEBIAN_CHANGELOG"
    fi
} > "$tmp"

[[ $(dpkg-parsechangelog -l"$tmp" -S Version) == "$version" ]] \
    || fail "generated Debian changelog has the wrong version"
mv -- "$tmp" "$DEBIAN_CHANGELOG"
