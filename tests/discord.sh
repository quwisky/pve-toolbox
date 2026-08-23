#!/usr/bin/env bash
#
# Tests for lib/discord.sh.
#
# Only the payload builders, which are pure. discord_notify's delivery path
# needs a webhook and is not exercised here; its no-webhook branch is, since
# that is the one every module hits on a host that was never configured.
#
# The point of assembling the payload with jq rather than by hand is that a
# value holding quotes, backticks, backslashes or newlines survives instead of
# breaking the JSON. That claim is what most of this file checks.
#
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

command -v jq >/dev/null 2>&1 || { printf 'skip discord tests, no jq\n'; exit 0; }

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# shellcheck source=lib/discord.sh
source "$ROOT/lib/discord.sh"

# jq field accessors, so a failure names the path that was wrong.
at() { jq -r "$1" <<<"$2"; }

# --- the payload is JSON at all ----------------------------------------------

payload=$(discord_payload "$DISCORD_OK" "Title" "Body" "Pool" "rpool")
jq -e . >/dev/null 2>&1 <<<"$payload" || fail "payload is not valid JSON: $payload"
[[ $(at '.embeds | length' "$payload") == 1 ]] || fail "expected one embed"
[[ $(at '.embeds[0].title' "$payload") == Title ]] || fail "title did not survive"
[[ $(at '.embeds[0].description' "$payload") == Body ]] || fail "description did not survive"
pass "discord_payload builds one embed"

# The colour is --argjson, so it has to arrive as a number. Discord rejects a
# string, and it would only be noticed on a live webhook.
[[ $(at '.embeds[0].color | type' "$payload") == number ]] || fail "color is not a number"
[[ $(at '.embeds[0].color' "$payload") == "$DISCORD_OK" ]] || fail "color did not survive"
pass "colour is a number"

[[ -n $(at '.embeds[0].footer.text' "$payload") ]] || fail "footer is empty"
pass "footer is set"

# --- values that would break hand-built JSON ---------------------------------

AWKWARD=(
    'say "hi"'
    "it's"
    'a\b'
    'back`tick`'
    'brace}and{brace'
    'new
line'
    'tab	separated'
    'emoji ✅ and ümlaut'
    '{"looks":"like json"}'
    '$(whoami) `id`'
)

for v in "${AWKWARD[@]}"; do
    p=$(discord_payload "$DISCORD_ERR" "$v" "$v" "Field" "$v")
    jq -e . >/dev/null 2>&1 <<<"$p" || fail "payload broke on [$v]"
    [[ $(at '.embeds[0].title' "$p")           == "$v" ]] || fail "title mangled [$v]"
    [[ $(at '.embeds[0].description' "$p")     == "$v" ]] || fail "description mangled [$v]"
    [[ $(at '.embeds[0].fields[0].value' "$p") == "$v" ]] || fail "field value mangled [$v]"
done
pass "quotes, newlines, backslashes and unicode survive the round trip"

# --- fields ------------------------------------------------------------------

p=$(discord_payload "$DISCORD_INFO" t d "One" "1" "Two" "2")
[[ $(at '.embeds[0].fields | length' "$p") == 2 ]] || fail "expected two fields"
[[ $(at '.embeds[0].fields[0].name' "$p")  == One ]] || fail "first field name"
[[ $(at '.embeds[0].fields[1].value' "$p") == 2 ]] || fail "second field value"
[[ $(at '.embeds[0].fields[0].inline' "$p") == true ]] || fail "fields are not inline"
pass "field pairs map to name and value"

p=$(discord_payload "$DISCORD_INFO" t d)
[[ $(at '.embeds[0].fields | length' "$p") == 0 ]] || fail "no pairs should mean no fields"
pass "no field pairs is an empty array"

# An empty value would render as a blank box, and an odd trailing name has no
# value at all; both become a dash rather than nothing.
p=$(discord_payload "$DISCORD_INFO" t d "Empty" "" "Dangling")
[[ $(at '.embeds[0].fields[0].value' "$p") == - ]] || fail "empty value is not a dash"
[[ $(at '.embeds[0].fields[1].value' "$p") == - ]] || fail "missing value is not a dash"
[[ $(at '.embeds[0].fields[1].name' "$p") == Dangling ]] || fail "dangling name was dropped"
pass "empty and missing field values become a dash"

# --- Discord's limits --------------------------------------------------------

long=$(printf 'x%.0s' $(seq 1 5000))
p=$(discord_payload "$DISCORD_WARN" "$long" "$long" "Field" "$long")
[[ $(at '.embeds[0].title' "$p" | wc -c) -le $((DISCORD_MAX_TITLE + 1)) ]] \
    || fail "title was not truncated to $DISCORD_MAX_TITLE"
[[ $(at '.embeds[0].description' "$p" | wc -c) -le $((DISCORD_MAX_DESC + 1)) ]] \
    || fail "description was not truncated to $DISCORD_MAX_DESC"
[[ $(at '.embeds[0].fields[0].value' "$p" | wc -c) -le $((DISCORD_MAX_FIELD + 1)) ]] \
    || fail "field value was not truncated to $DISCORD_MAX_FIELD"
jq -e . >/dev/null 2>&1 <<<"$p" || fail "truncated payload is not valid JSON"
pass "title, description and fields are truncated to Discord's limits"

# --- discord_fence -----------------------------------------------------------

fenced=$(discord_fence "line one")
[[ $fenced == '```'* ]] || fail "fence does not open with a code block"
[[ $fenced == *'```' ]] || fail "fence does not close with a code block"
[[ $fenced == *"line one"* ]] || fail "fence lost its content"
pass "discord_fence wraps in a code block"

# A log tail is what gets fenced, so an over-long one must keep the end.
fenced=$(discord_fence "$(printf 'HEAD%s TAIL' "$(printf 'x%.0s' $(seq 1 200))")" 50)
[[ $fenced == *TAIL* ]] || fail "fence trimmed the tail instead of the head"
[[ $fenced != *HEAD* ]] || fail "fence kept the head, so it trimmed the wrong end"
pass "discord_fence keeps the tail when it has to trim"

# --- discord_notify without a webhook ----------------------------------------

# The path every module takes on a host nobody configured. It must not attempt
# delivery, must say so, and must report failure so a --test mode can be loud.
out=$(discord_notify "" "$DISCORD_OK" "Some title" "body" 2>&1) && rc=0 || rc=$?
[[ $rc -eq 1 ]] || fail "discord_notify with no webhook returned $rc, wanted 1"
[[ $out == *"no Discord webhook configured"* ]] || fail "no explanation given: $out"
[[ $out == *"Some title"* ]] || fail "the message that went unsent was not named: $out"
pass "discord_notify without a webhook fails loudly and sends nothing"
