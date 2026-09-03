#!/usr/bin/env bash
# Verify deterministic, fail-closed Debian changelog synchronization.
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

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

workflow_job() {
    local job=$1
    awk -v job="$job" '
        $0 == "  " job ":" { found = 1 }
        found && $0 ~ /^  [A-Za-z0-9_-]+:$/ && $0 != "  " job ":" { exit }
        found { print }
        END { if (!found) exit 1 }
    ' .github/workflows/release.yml
}

pages_writers=$(grep -El '^[[:space:]]+pages: write$' \
    .github/workflows/*.yml || true)
[[ $pages_writers == .github/workflows/release.yml ]] \
    || fail "release.yml must be the only Pages writer"
[[ $(grep -Fc 'actions/deploy-pages@' .github/workflows/release.yml) -eq 1 ]] \
    || fail "release.yml must contain exactly one Pages deployment"

publish_release_job=$(workflow_job publish-release)
pages_build_job=$(workflow_job pages-build)
pages_deploy_job=$(workflow_job pages-deploy)
grep -Fqx '    needs: [release-please, build, attest, publish-apt]' \
    <<< "$publish_release_job" \
    || fail "GitHub Release publication has unexpected prerequisites"
grep -Fqx '    needs: [release-please, publish-apt, publish-release]' \
    <<< "$pages_build_job" \
    || fail "Pages assembly does not require a published release"
grep -Fqx '    needs: [release-please, publish-release, pages-build]' \
    <<< "$pages_deploy_job" \
    || fail "Pages deployment does not require a published release"
[[ $(grep -Fc './scripts/verify-latest-release.sh "$RELEASE_TAG" "$RELEASE_SHA"' \
    .github/workflows/release.yml) -eq 3 ]] \
    || fail "release and Pages jobs do not share the latest-release guard"
grep -Fq 'APT_SHA: ${{ needs.publish-apt.outputs.apt-sha }}' \
    <<< "$pages_build_job" \
    || fail "Pages does not consume the release APT repository commit"
pass "Pages publication is release-only and ordered after publication"

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

mkdir -p "$WORK/bin" "$WORK/release-repo"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == api ]]
case $2 in
    repos/example/repo/releases/tags/v1.2.3)
        printf '{"tag_name":"v1.2.3","draft":%s,"prerelease":false,"published_at":"2026-09-03T18:00:00Z"}\n' \
            "${MOCK_RELEASE_DRAFT:-false}"
        ;;
    repos/example/repo/releases/latest)
        printf '%s\n' "${MOCK_LATEST_TAG:-v1.2.3}"
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 0755 "$WORK/bin/gh"
git -C "$WORK/release-repo" init -q
git -C "$WORK/release-repo" config user.name test
git -C "$WORK/release-repo" config user.email test@example.invalid
printf 'release\n' > "$WORK/release-repo/content"
git -C "$WORK/release-repo" add content
git -C "$WORK/release-repo" commit -qm release
git -C "$WORK/release-repo" tag v1.2.3
release_sha=$(git -C "$WORK/release-repo" rev-parse HEAD)
(
    cd "$WORK/release-repo"
    PATH="$WORK/bin:$PATH" GITHUB_REPOSITORY=example/repo \
        "$ROOT/scripts/verify-latest-release.sh" v1.2.3 "$release_sha" \
        >/dev/null
)
if (
    cd "$WORK/release-repo"
    PATH="$WORK/bin:$PATH" GITHUB_REPOSITORY=example/repo \
        MOCK_LATEST_TAG=v1.2.4 \
        "$ROOT/scripts/verify-latest-release.sh" v1.2.3 "$release_sha" \
        >/dev/null 2>&1
); then
    fail "latest-release guard accepted a stale release"
fi
if (
    cd "$WORK/release-repo"
    PATH="$WORK/bin:$PATH" GITHUB_REPOSITORY=example/repo \
        MOCK_RELEASE_DRAFT=true \
        "$ROOT/scripts/verify-latest-release.sh" v1.2.3 "$release_sha" \
        >/dev/null 2>&1
); then
    fail "latest-release guard accepted a draft release"
fi
pass "latest-release guard rejects draft and stale releases"

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
cat > "$debian" <<'EOF'
pve-toolbox (0.4.1) unstable; urgency=medium

  * Retain historical package notes.

 -- Bence Nagy <quwisky@qwky.eu>  Fri, 29 Aug 2026 19:47:00 +0200
EOF

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
