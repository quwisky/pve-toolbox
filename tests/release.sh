#!/usr/bin/env bash
# Verify deterministic, fail-closed Debian changelog synchronization.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

version=$(<VERSION)
[[ $(dpkg-parsechangelog -S Version) == "$version" ]] \
    || fail "VERSION and Debian changelog differ"
[[ $(jq -r '."."' .release-please-manifest.json) == "$version" ]] \
    || fail "VERSION and Release Please manifest differ"
jq -e '
    .draft == true and
    .["force-tag-creation"] == true and
    .prerelease == false and
    .["bump-minor-pre-major"] == true and
    .["bump-patch-for-minor-pre-major"] == false and
    .packages["."].["release-type"] == "simple" and
    .packages["."].["version-file"] == "VERSION"
' release-please-config.json >/dev/null \
    || fail "Release Please safety policy changed"
grep -Eq "^## \\[?$version([][( ]|$)" CHANGELOG.md \
    || fail "CHANGELOG.md does not contain the current version"

while IFS= read -r action; do
    action=${action%% *}
    [[ $action == ./.github/workflows/* ]] && continue
    [[ $action =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}$ ]] \
        || fail "workflow action is not pinned by full SHA: $action"
done < <(sed -n 's/^[[:space:]]*uses:[[:space:]]*//p' .github/workflows/*.yml)
pass "release metadata and workflow pins are consistent"

WORK=$(mktemp -d)
cleanup() {
    status=$?
    trap - EXIT
    if ! rm -rf -- "$WORK"; then
        printf 'FAIL could not remove release-test workspace: %s\n' "$WORK" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT

version_file="$WORK/VERSION"
markdown="$WORK/CHANGELOG.md"
debian="$WORK/changelog"
printf '0.4.2\n' > "$version_file"
cat > "$markdown" <<'EOF'
# Changelog

## [1.0.0](https://example.invalid/compare) (2026-08-30)

* support a stable major release

## [0.4.2](https://example.invalid/compare) (2026-08-30)

### Bug Fixes

* reject an unsafe release input
* retain three package versions

## 0.4.1

* old notes
EOF
cp debian/changelog "$debian"

run_sync() {
    VERSION_FILE="$version_file" \
    MARKDOWN_CHANGELOG="$markdown" \
    DEBIAN_CHANGELOG="$debian" \
    DEBIAN_CHANGELOG_DATE='Sun, 30 Aug 2026 18:00:00 +0000' \
        ./scripts/sync-debian-changelog.sh
}

run_sync
[[ $(dpkg-parsechangelog -l"$debian" -S Version) == 0.4.2 ]] \
    || fail "synchronizer did not set the release version"
grep -q '^  \* reject an unsafe release input$' "$debian" \
    || fail "synchronizer omitted generated notes"
grep -q '^pve-toolbox (0.4.1) ' "$debian" \
    || fail "synchronizer discarded release history"
grep -q '^ -- Bence Nagy <quwisky@qwky.eu>  Sun, 30 Aug 2026 18:00:00 +0000$' \
    "$debian" || fail "synchronizer emitted the wrong trailer"
cp "$debian" "$WORK/first-run"
run_sync
cmp -s "$WORK/first-run" "$debian" || fail "synchronizer is not idempotent"
[[ $(grep -c '^pve-toolbox (0.4.2) ' "$debian") -eq 1 ]] \
    || fail "synchronizer duplicated the current release"
pass "Debian changelog synchronization is deterministic"

printf '0.4.0\n' > "$version_file"
cp "$debian" "$WORK/before-downgrade"
if run_sync >/dev/null 2>&1; then
    fail "synchronizer accepted a version downgrade"
fi
cmp -s "$WORK/before-downgrade" "$debian" \
    || fail "failed synchronization changed the Debian changelog"
pass "Debian changelog synchronization fails closed"

printf '1.0.0\n' > "$version_file"
run_sync
[[ $(dpkg-parsechangelog -l"$debian" -S Version) == 1.0.0 ]] \
    || fail "synchronizer rejected a stable major version"
grep -q '^  \* support a stable major release$' "$debian" \
    || fail "synchronizer omitted stable major release notes"
pass "Debian changelog synchronization accepts stable semantic versions"
