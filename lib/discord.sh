# shellcheck shell=bash
#
# lib/discord.sh - Discord webhook reporting, shared by modules and by the
# helper scripts they install.
#
# Deliberately standalone: lib/common.sh sources it for modules, and a runner
# dropped into TOOLBOX_BIN_DIR sources it straight from TOOLBOX_LIB_DIR
# without pulling in the rest of the toolbox. Needs only curl and jq.
#
#   discord_notify <webhook> <color> <title> <description> [name value ...]
#
# Returns 1 if nothing was delivered, so a caller that cares (a --test mode)
# can fail loudly while a caller that does not can ignore it.
#
[[ -n ${_TOOLBOX_DISCORD_LOADED:-} ]] && return 0
_TOOLBOX_DISCORD_LOADED=1

# Callers pick one of these; shellcheck cannot see across the source boundary.
# shellcheck disable=SC2034
{
    DISCORD_INFO=3447003      # blue
    DISCORD_OK=3066993        # green
    DISCORD_WARN=15844367     # yellow
    DISCORD_ERR=15158332      # red
}

# Shown under every embed. Override before calling if a module wants its own.
DISCORD_FOOTER="${DISCORD_FOOTER:-pve-toolbox on $(hostname -s 2>/dev/null || hostname)}"

# Discord's own limits, applied here so a long log tail truncates instead of
# getting the whole POST rejected.
DISCORD_MAX_TITLE=250
DISCORD_MAX_DESC=3800
DISCORD_MAX_FIELD=1000

discord_log() { printf '%s\n' "$*"; }

# discord_fields [name value ...] -> compact JSON array
# Pairs are separate arguments, so a value may contain quotes, backticks,
# backslashes or newlines without any escaping of our own.
discord_fields() {
    jq -n -c --argjson max "$DISCORD_MAX_FIELD" '
        [ range(0; ($ARGS.positional | length); 2)
          | { name:   ($ARGS.positional[.] // "-"),
              value:  (($ARGS.positional[. + 1] // "") as $v
                       | if $v == "" then "-" else $v[0:$max] end),
              inline: true } ]' --args "$@"
}

# discord_payload <color> <title> <description> [name value ...] -> JSON
discord_payload() {
    local color=$1 title=$2 desc=$3
    shift 3
    local fields
    fields=$(discord_fields "$@")
    jq -n -c \
        --arg title "$title" \
        --arg desc "$desc" \
        --arg footer "$DISCORD_FOOTER" \
        --argjson color "$color" \
        --argjson fields "$fields" \
        --argjson maxt "$DISCORD_MAX_TITLE" \
        --argjson maxd "$DISCORD_MAX_DESC" \
        '{ embeds: [ { title:       $title[0:$maxt],
                       description: $desc[0:$maxd],
                       color:       $color,
                       fields:      $fields,
                       footer:      { text: $footer } } ] }'
}

# discord_notify <webhook> <color> <title> <description> [name value ...]
discord_notify() {
    local webhook=$1 color=$2 title=$3 desc=$4
    shift 4
    if [[ -z $webhook ]]; then
        discord_log "no Discord webhook configured - not sending: $title"
        return 1
    fi
    local payload
    payload=$(discord_payload "$color" "$title" "$desc" "$@")
    if curl -sS -f -m 20 --retry 3 --retry-connrefused \
            -H 'Content-Type: application/json' \
            -X POST -d "$payload" "$webhook" >/dev/null 2>&1; then
        discord_log "notified: $title"
        return 0
    fi
    discord_log "warning: POST to the Discord webhook failed ($title)"
    return 1
}

# discord_fence <text> -> text wrapped in a code block, trimmed to fit a
# description alongside whatever preamble the caller adds.
discord_fence() {
    local t=$1 room=${2:-3000}
    [[ ${#t} -gt $room ]] && t=${t: -room}
    printf '```\n%s\n```' "$t"
}
