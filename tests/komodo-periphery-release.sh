#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034 # Shared result variables are consumed by sourced helpers.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source lib/common.sh
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
declare -F gh_exact_asset >/dev/null || fail 'exact release verification is missing'
printf 'verified fixture\n' > "$WORK/asset"
digest=$(sha256sum "$WORK/asset" | cut -d ' ' -f1)
metadata=$(jq -nc --arg digest "sha256:$digest" '{assets:[{name:"periphery-x86_64",digest:$digest,browser_download_url:"https://github.com/moghtech/komodo/releases/download/v2.3.3/periphery-x86_64"}]}')
GH_JSON=$metadata
gh_exact_asset periphery-x86_64 || fail 'valid exact asset rejected'
verify_sha256 "$WORK/asset" "$GH_ASSET_SHA256" || fail 'matching hash rejected'
for filter in '.assets += .assets' '.assets=[]' '.assets[0].digest=null' '.assets[0].digest="md5:abc"' '.assets[0].digest="sha256:no"' '.assets[0].browser_download_url="http://unsafe"' '.assets[0].name="periphery-aarch64"'; do
    GH_JSON=$(jq "$filter" <<<"$metadata")
    if gh_exact_asset periphery-x86_64; then fail "bad asset accepted: $filter"; fi
    [[ -z $GH_ASSET_URL && -z $GH_ASSET_SHA256 ]] || fail 'stale asset returned'
done
printf 'damaged' >> "$WORK/asset"
if verify_sha256 "$WORK/asset" "$digest"; then fail 'damaged download accepted'; fi
ln -s "$WORK/asset" "$WORK/link"
if verify_sha256 "$WORK/link" "$digest"; then fail 'symlink accepted'; fi
GH_JSON=invalid
if gh_exact_asset periphery-x86_64; then fail 'invalid JSON accepted'; fi
printf 'ok exact release assets and SHA-256 checks fail closed\n'
