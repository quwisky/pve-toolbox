#!/usr/bin/env bash
# Fail unless a tag is the latest published stable release at the expected SHA.
set -Eeuo pipefail

[[ $# -eq 2 ]] || {
    printf 'usage: %s <release-tag> <release-sha>\n' "$0" >&2
    exit 2
}

release_tag=$1
release_sha=$2

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

[[ ${GITHUB_REPOSITORY:-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
    || fail "GITHUB_REPOSITORY is invalid"
[[ $release_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "release tag is not stable semantic versioning"
[[ $release_sha =~ ^[0-9a-f]{40}$ ]] || fail "release SHA is invalid"

tag_sha=$(git rev-list -n 1 "$release_tag") \
    || fail "release tag is unavailable: $release_tag"
[[ $tag_sha == "$release_sha" ]] \
    || fail "release tag does not point to the expected commit"

release=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$release_tag") \
    || fail "could not read back release: $release_tag"
jq -e --arg tag "$release_tag" '
    .tag_name == $tag and
    .draft == false and
    .prerelease == false and
    (.published_at | type == "string" and length > 0)
' <<< "$release" >/dev/null || fail "release is not published and stable"

latest_tag=$(gh api "repos/$GITHUB_REPOSITORY/releases/latest" --jq .tag_name) \
    || fail "could not determine the latest published release"
[[ $latest_tag == "$release_tag" ]] \
    || fail "a newer published release supersedes $release_tag"

printf 'verified latest published release %s at %s\n' \
    "$release_tag" "$release_sha"
