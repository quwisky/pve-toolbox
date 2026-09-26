# shellcheck shell=bash
#
# lib/common.sh - shared helpers for pve-toolbox modules.
#
# Sourced by bin/pve-toolbox and by every module. Defines no side effects
# beyond variable and function definitions, so it is safe to source when
# only module metadata is wanted.
#
[[ -n ${_TOOLBOX_COMMON_LOADED:-} ]] && return 0
_TOOLBOX_COMMON_LOADED=1

TOOLBOX_BIN_DIR="${TOOLBOX_BIN_DIR:-/usr/local/bin}"
TOOLBOX_STATE_DIR="${TOOLBOX_STATE_DIR:-/var/lib/pve-toolbox}"
TOOLBOX_SYSTEMD_DIR="${TOOLBOX_SYSTEMD_DIR:-/etc/systemd/system}"
TOOLBOX_CONF_DIR="${TOOLBOX_CONF_DIR:-/etc/pve-toolbox}"
TOOLBOX_LIB_DIR="${TOOLBOX_LIB_DIR:-/usr/local/lib/pve-toolbox}"
TOOLBOX_BASH_COMPLETION_DIR="${TOOLBOX_BASH_COMPLETION_DIR:-/usr/share/bash-completion/completions}"
TOOLBOX_ZSH_COMPLETION_DIR="${TOOLBOX_ZSH_COMPLETION_DIR:-/usr/share/zsh/vendor-completions}"
ASSUME_YES="${ASSUME_YES:-0}"

# Reporting helpers, also installed into TOOLBOX_LIB_DIR for the standalone
# runners that modules drop into TOOLBOX_BIN_DIR.
# shellcheck source=lib/discord.sh
source "${BASH_SOURCE[0]%/*}/discord.sh"

# ---------------------------------------------------------------- output --

if [[ -t 1 ]]; then
    c_reset=$'\e[0m'; c_bold=$'\e[1m'; c_dim=$'\e[2m'
    c_red=$'\e[31m'; c_green=$'\e[32m'; c_yellow=$'\e[33m'; c_blue=$'\e[34m'
else
    c_reset=""; c_bold=""; c_dim=""
    c_red=""; c_green=""; c_yellow=""; c_blue=""
fi

info() { printf '%s==>%s %s\n' "$c_blue$c_bold" "$c_reset" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$c_green" "$c_reset" "$*"; }
warn() { printf '%s  !!%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()  { printf '%s error:%s %s\n' "$c_red$c_bold" "$c_reset" "$*" >&2; exit 1; }
step() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_reset"; }
dim()  { printf '%s%s%s\n' "$c_dim" "$*" "$c_reset"; }

# ----------------------------------------------------------------- input --
#
# Every prompt goes through _ask_read, so its rules hold everywhere:
#   - a value already in <var> (preset in the environment, or loaded from
#     conf) is the default, which is how -y installs are driven;
#   - under ASSUME_YES the default is validated and nothing is read;
#   - a read that fails is an error, never a silent default. Piped answers
#     work; running out of them must not quietly configure a host.
#
# A validator is called as `fn <value>` in this shell. It returns 0 to accept,
# optionally setting ASK_NORMALIZED to the form to store, or sets ASK_REASON
# and returns 1. The reason is shown to the operator, so a validator used for
# a secret must never put the value in it.
ASK_REASON=""
ASK_NORMALIZED=""
ASK_VALUE=""
ASK_LINE=""

# Name the variable only when an operator could have preset it.
_ask_hint() { # _ask_hint <var>
    if [[ $1 =~ ^[A-Z][A-Z0-9_]*$ ]]; then
        printf 'run it in a terminal, or use -y and set %s' "$1"
    else
        printf 'run it in a terminal'
    fi
}

_ask_check() { # _ask_check <validator|""> <value> -> ASK_VALUE, or 1 with ASK_REASON
    ASK_REASON="" ASK_NORMALIZED="" ASK_VALUE=$2
    [[ -n $1 ]] || return 0
    if ! "$1" "$2"; then
        ASK_REASON=${ASK_REASON:-value not accepted}
        return 1
    fi
    [[ -z $ASK_NORMALIZED ]] || ASK_VALUE=$ASK_NORMALIZED
}

# A last line without a newline still counts as an answer.
_ask_line() { # _ask_line <prompt> [secret] -> ASK_LINE
    local -a __flags=(-r)
    [[ ${2:-} != secret ]] || __flags+=(-s)
    ASK_LINE=""
    read "${__flags[@]}" -p "$1" ASK_LINE || [[ -n $ASK_LINE ]]
}

_ask_read() { # _ask_read <var> <prompt> <default> [validator]
    local __var=$1 __prompt=$2 __default=$3 __fn=${4:-}
    if [[ -n ${!__var:-} ]]; then __default=${!__var}; fi
    if [[ $ASSUME_YES -eq 1 ]]; then
        _ask_check "$__fn" "$__default" \
            || die "invalid value for $__var: $ASK_REASON"
        printf -v "$__var" '%s' "$ASK_VALUE"
        return 0
    fi
    while true; do
        _ask_line "$(printf '%s [%s]: ' "$__prompt" "$c_dim$__default$c_reset")" \
            || die "no answer for \"$__prompt\" (input closed); $(_ask_hint "$__var")"
        if _ask_check "$__fn" "${ASK_LINE:-$__default}"; then
            printf -v "$__var" '%s' "$ASK_VALUE"
            return 0
        fi
        warn "$ASK_REASON"
    done
}

ask() { _ask_read "$1" "$2" "$3"; }                # ask <var> <prompt> <default>
ask_valid() { _ask_read "$1" "$2" "$3" "$4"; }     # ask_valid <var> <prompt> <default> <fn>

# Stored as y or n. 1/0 and true/false are accepted because older conf files
# and env presets spell booleans that way.
_ask_yn_valid() {
    case ${1,,} in
        y|yes|1|true)  ASK_NORMALIZED=y ;;
        n|no|0|false)  ASK_NORMALIZED=n ;;
        *) ASK_REASON="please answer y or n"; return 1 ;;
    esac
}
ask_yn() { _ask_read "$1" "$2 (y/n)" "$3" _ask_yn_valid; }   # ask_yn <var> <prompt> <y|n>

# Bounds for the validator: bash has no closures, and one prompt runs at a time.
_ASK_INT_MIN="" _ASK_INT_MAX=""
_ask_int_valid() {
    local range=""
    if [[ -n $_ASK_INT_MIN && -n $_ASK_INT_MAX ]]; then range=" from $_ASK_INT_MIN to $_ASK_INT_MAX"
    elif [[ -n $_ASK_INT_MIN ]]; then range=" of at least $_ASK_INT_MIN"
    elif [[ -n $_ASK_INT_MAX ]]; then range=" of at most $_ASK_INT_MAX"
    fi
    ASK_REASON="enter a whole number$range"
    # 18 digits keeps the comparisons below inside bash's 64-bit arithmetic.
    [[ $1 =~ ^(0|[1-9][0-9]{0,17})$ ]] || return 1
    [[ -z $_ASK_INT_MIN || $1 -ge $_ASK_INT_MIN ]] || return 1
    [[ -z $_ASK_INT_MAX || $1 -le $_ASK_INT_MAX ]] || return 1
    ASK_REASON=""
}
ask_int() { # ask_int <var> <prompt> <default> [min] [max]
    _ASK_INT_MIN=${4:-} _ASK_INT_MAX=${5:-}
    _ask_read "$1" "$2" "$3" _ask_int_valid
}

_ASK_CHOICES=()
_ask_choice_valid() {
    local c
    for c in "${_ASK_CHOICES[@]}"; do
        if [[ ${1,,} == "${c,,}" ]]; then ASK_NORMALIZED=$c; return 0; fi
    done
    ASK_REASON="choose one of $(IFS=/; printf '%s' "${_ASK_CHOICES[*]}")"
    return 1
}
ask_choice() { # ask_choice <var> <prompt> <default> <choice>...
    local __var=$1 __prompt=$2 __default=$3
    shift 3
    [[ $# -gt 0 ]] || die "ask_choice needs at least one choice"
    _ASK_CHOICES=("$@")
    _ask_read "$__var" "$__prompt ($(IFS=/; printf '%s' "$*"))" "$__default" _ask_choice_valid
}

# A calendar systemd accepts but that never fires (Feb 30th) is refused too:
# the timer would install cleanly and then do nothing, forever.
valid_schedule() { # valid_schedule <OnCalendar> -> 0, or 1 with ASK_REASON
    local output
    [[ -n ${1:-} ]] || { ASK_REASON="a schedule is required"; return 1; }
    command -v systemd-analyze >/dev/null 2>&1 \
        || { ASK_REASON="systemd-analyze is needed to check schedules"; return 1; }
    output=$(LC_ALL=C systemd-analyze calendar --iterations=1 "$1" 2>/dev/null) \
        || { ASK_REASON="not a systemd OnCalendar expression: $1"; return 1; }
    [[ $output == *'Next elapse:'* && $output != *'Next elapse: never'* ]] \
        || { ASK_REASON="schedule never runs: $1"; return 1; }
}

# Re-asking cannot fix a missing systemd-analyze, so that ends the install here.
ask_schedule() { # ask_schedule <var> <prompt> <default>
    command -v systemd-analyze >/dev/null 2>&1 \
        || die "systemd-analyze is needed to check schedules"
    _ask_read "$1" "$2" "$3" valid_schedule
}

# Never echoed and never shown as a default. With a value already present,
# Enter keeps it and "none" clears it. A validator that refuses an empty value
# makes the secret required. Under -y only a value already present counts.
ask_secret() { # ask_secret <var> <prompt> [validator]
    local __var=$1 __prompt=$2 __fn=${3:-} __current __hint="" __reply
    __current=${!__var:-}
    if [[ $ASSUME_YES -eq 1 ]]; then
        _ask_check "$__fn" "$__current" \
            || die "invalid value for $__var: $ASK_REASON"
        printf -v "$__var" '%s' "$ASK_VALUE"
        ASK_LINE="" ASK_VALUE=""
        return 0
    fi
    [[ -z $__current ]] || __hint=' [set; Enter keeps, "none" clears]'
    while true; do
        if ! _ask_line "$__prompt$__hint: " secret; then
            [[ ! -t 0 ]] || printf '\n' >&2
            die "no answer for \"$__prompt\" (input closed); $(_ask_hint "$__var")"
        fi
        [[ ! -t 0 ]] || printf '\n' >&2   # read -s swallows the newline
        __reply=$ASK_LINE
        if [[ -z $__reply ]]; then __reply=$__current
        elif [[ $__reply == none ]]; then __reply=""
        fi
        if _ask_check "$__fn" "$__reply"; then
            printf -v "$__var" '%s' "$ASK_VALUE"
            ASK_LINE="" ASK_VALUE=""
            return 0
        fi
        warn "$ASK_REASON"
    done
}

confirm() { # confirm <prompt> <default y|n> -> exit status
    local __r=""
    ask_yn __r "$1" "${2:-y}"
    [[ $__r == y ]]
}

# ------------------------------------------------------------- preflight --

require_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

in_lxc() {
    [[ -f /proc/1/environ ]] && grep -qa 'container=lxc' /proc/1/environ 2>/dev/null
}

require_pve() {
    if command -v pveversion >/dev/null 2>&1; then
        ok "Proxmox VE: $(pveversion | head -n1)"
    else
        warn "pveversion not found - this does not look like a PVE host"
        confirm "continue anyway?" "n" || exit 1
    fi
    if in_lxc; then
        warn "running inside an LXC container"
        confirm "continue anyway?" "n" || exit 1
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64)  ARCH=amd64 ;;
        aarch64) ARCH=arm64 ;;
        armv7l)  ARCH=arm-7 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
    printf '%s' "$ARCH"
}

# pkg_ensure <command:package> ...
pkg_ensure() {
    local missing=() spec cmd pkg
    for spec in "$@"; do
        cmd=${spec%%:*}; pkg=${spec##*:}
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    info "installing packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
}

have_zfs()   { command -v zpool >/dev/null 2>&1; }
have_mdadm() { [[ -f /proc/mdstat ]] && grep -qE '^md[0-9]' /proc/mdstat 2>/dev/null; }

# ------------------------------------------------------------ github api --

# gh_release <repo> <tag|latest> -> sets GH_JSON, GH_TAG
gh_release() {
    local repo=$1 tag=${2:-latest} url
    if [[ $tag == latest ]]; then
        url="https://api.github.com/repos/$repo/releases/latest"
    else
        url="https://api.github.com/repos/$repo/releases/tags/$tag"
    fi
    GH_JSON=$(curl -fsSL -H 'Accept: application/vnd.github+json' "$url") \
        || die "could not fetch release metadata from $url (rate limited, or bad tag?)"
    GH_TAG=$(jq -r '.tag_name' <<<"$GH_JSON")
    [[ -n $GH_TAG && $GH_TAG != null ]] || die "no tag_name in release metadata"
}

# gh_exact_asset <exact-name> -> GH_ASSET_URL, GH_ASSET_SHA256
# For releases publishing GitHub asset digests instead of a checksum manifest.
# Outputs are cleared on every error; callers must never reuse another asset.
# shellcheck disable=SC2034 # Public result variables are consumed by modules.
gh_exact_asset() {
    GH_ASSET_URL="" GH_ASSET_SHA256=""
    local asset
    asset=$(jq -ce --arg name "$1" '
        [.assets[] | select(.name == $name)]
        | if length == 1 then .[0] else error("ambiguous asset") end
        | select(.digest | type == "string" and test("^sha256:[0-9a-fA-F]{64}$"))
        | select(.browser_download_url | type == "string" and
            startswith("https://") and (explode | all(. > 32 and . != 127)))
    ' <<<"${GH_JSON:-}" 2>/dev/null) || return 1
    GH_ASSET_URL=$(jq -r '.browser_download_url' <<<"$asset")
    GH_ASSET_SHA256=$(jq -r '.digest | ltrimstr("sha256:") | ascii_downcase' <<<"$asset")
}

verify_sha256() { # <regular file> <SHA-256 hex digest>
    local actual
    [[ -f $1 && ! -L $1 && $2 =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    actual=$(sha256sum -- "$1") || return 1
    [[ ${actual%% *} == "${2,,}" ]]
}

# gh_asset <name-fragment> <arch-fragment> -> prints download url
gh_asset() {
    jq -r --arg frag "$1" --arg arch "$2" '
        .assets[]
        | select(.name | test($frag))
        | select(.name | test($arch))
        | select(.name | test("\\.(sha256|txt|sig|asc|sbom|json)$") | not)
        | .browser_download_url
    ' <<<"$GH_JSON" | head -n1
}

# gh_checksums -> prints url of a checksum file, empty if none
gh_checksums() {
    jq -r '.assets[] | select(.name | test("(?i)sha256|checksums")) | .browser_download_url' \
        <<<"$GH_JSON" | head -n1
}

# gh_fetch_checksums -> sets CHECKSUM_FILE, fails if one cannot be loaded
gh_fetch_checksums() {
    local url
    CHECKSUM_FILE=""
    url=$(gh_checksums)
    [[ -n $url ]] || { warn "release has no checksum file - refusing unverified assets"; return 1; }
    CHECKSUM_FILE=$(mktemp)
    if ! curl -fsSL --retry 3 -o "$CHECKSUM_FILE" "$url"; then
        rm -f -- "$CHECKSUM_FILE"
        CHECKSUM_FILE=""
        warn "could not download release checksums - refusing unverified assets"
        return 1
    fi
    [[ -s $CHECKSUM_FILE ]] || {
        rm -f -- "$CHECKSUM_FILE"
        CHECKSUM_FILE=""
        warn "release checksum file is empty - refusing unverified assets"
        return 1
    }
}

verify_checksum() { # verify_checksum <file> <asset-name>
    [[ -n ${CHECKSUM_FILE:-} && -s ${CHECKSUM_FILE:-} ]] || {
        warn "no release checksums loaded for $2"
        return 1
    }
    local expected actual
    expected=$(awk -v n="$2" '
        $2 == n || $2 == "*" n || $2 == "./" n || $2 == "*./" n { print $1; exit }
    ' "$CHECKSUM_FILE")
    [[ $expected =~ ^[0-9A-Fa-f]{64}$ ]] || {
        warn "no valid checksum entry for $2"
        return 1
    }
    actual=$(sha256sum "$1" | awk '{print $1}')
    [[ ${expected,,} == "$actual" ]] || return 1
    ok "checksum verified"
}

# install_release_binary <asset-fragment> <arch-fragment> <target-name>
# Keeps the previous build as <target>.prev for rollback. Returns 1 if no asset.
install_release_binary() {
    local frag=$1 arch=$2 target=$3 url tmp name
    url=$(gh_asset "$frag" "$arch")
    if [[ -z $url ]]; then
        warn "no asset matching '$frag' for $arch in $GH_TAG"
        return 1
    fi
    name=$(basename "$url")
    tmp=$(mktemp)
    info "downloading $name"
    curl -fsSL --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; die "download failed: $url"; }
    if ! verify_checksum "$tmp" "$name"; then
        rm -f "$tmp"; die "checksum mismatch for $name"
    fi
    [[ -f "$TOOLBOX_BIN_DIR/$target" ]] && cp -a "$TOOLBOX_BIN_DIR/$target" "$TOOLBOX_BIN_DIR/$target.prev"
    install -m 0755 "$tmp" "$TOOLBOX_BIN_DIR/$target"
    rm -f "$tmp"
    ok "installed $TOOLBOX_BIN_DIR/$target"
}

rollback_binary() { # rollback_binary <target-name>
    local bin="$TOOLBOX_BIN_DIR/$1"
    [[ -f "$bin.prev" ]] || { warn "no previous build for $1"; return 1; }
    mv -f "$bin.prev" "$bin"
    warn "rolled back $1"
}

# A release tag usually carries a leading v; `--version` output usually does
# not. Compare the two bare, or v1.69.1 reads as an update over 1.69.1.
version_bare() { printf '%s' "${1#[vV]}"; }

# is_newer <candidate> <current> -> 0 if candidate sorts strictly above current
is_newer() {
    local a b
    a=$(version_bare "$1"); b=$(version_bare "$2")
    [[ -z $a || $a == unknown ]] && return 1   # nothing to offer
    [[ -z $b || $b == unknown ]] && return 0   # nothing known to beat
    # sort -V puts equal versions at the tail too, so a tie has to be caught
    # here rather than left to the comparison below.
    [[ $a == "$b" ]] && return 1
    # sort -V has no notion of a prerelease: it puts 1.70.0-rc1 *above* 1.70.0,
    # so a stable release would read as a downgrade from its own candidate. It
    # does sort ~ below everything, which is the ordering wanted, so borrow it.
    a=${a//-/\~}; b=${b//-/\~}
    [[ $(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1) == "$a" ]]
}

# ------------------------------------------------------------------ state --

_state_file() { printf '%s/%s.state' "$TOOLBOX_STATE_DIR" "$1"; }

state_set() { # state_set <module> <key> <value>
    local f tmp; f=$(_state_file "$1")
    mkdir -p "$TOOLBOX_STATE_DIR"
    [[ -f $f ]] || : > "$f"
    tmp=$(mktemp)
    # Same shape as conf_set, and for the same reason. The value went through
    # `sed s|^K=.*|K=$3|` before, which read & as "the whole match", ate
    # backslashes, and died outright on a |, leaving the old value in place
    # and the error on stderr where nothing looked at it.
    _STATE_V=$3 awk -v k="$2" '
        $0 ~ "^" k "=" { print k "=" ENVIRON["_STATE_V"]; found = 1; next }
        { print }
        END { if (!found) print k "=" ENVIRON["_STATE_V"] }
    ' "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
    chmod 0644 "$f"
}

state_get() { # state_get <module> <key>
    local f; f=$(_state_file "$1")
    [[ -f $f ]] || return 0
    awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$f"
}

state_clear() { rm -f "$(_state_file "$1")"; }
state_exists() { [[ -f $(_state_file "$1") ]]; }

# ------------------------------------------------------------------- conf --
#
# State is what a module knows; conf is what an operator set. State lives in
# TOOLBOX_STATE_DIR at 0644 and is safe to print; conf lives in
# TOOLBOX_CONF_DIR at 0600 because it is where tokens, webhook URLs and
# passwords go. Conf files are plain KEY='value' and stay sourceable, so a
# helper script installed into TOOLBOX_BIN_DIR can read one directly without
# pulling in this library.

conf_file() { printf '%s/%s.conf' "$TOOLBOX_CONF_DIR" "$1"; }

# Single-quote for the shell, turning any embedded quote into '\'' .
_conf_quote() {
    local v=$1
    v=${v//\'/\'\\\'\'}
    printf "'%s'" "$v"
}

conf_set() { # conf_set <module> <key> <value>
    local f tmp q
    f=$(conf_file "$1")
    mkdir -p "$TOOLBOX_CONF_DIR"
    chmod 0750 "$TOOLBOX_CONF_DIR"
    if [[ ! -f $f ]]; then
        ( umask 077; printf '# managed by pve-toolbox / %s\n' "$1" > "$f" )
    fi
    chmod 0600 "$f"
    q=$(_conf_quote "$3")
    tmp=$(mktemp)
    # Via the environment, not -v: awk expands backslash escapes in -v values
    # and would eat the quote escaping.
    _CONF_V=$q awk -v k="$2" '
        $0 ~ "^" k "=" { print k "=" ENVIRON["_CONF_V"]; found = 1; next }
        { print }
        END { if (!found) print k "=" ENVIRON["_CONF_V"] }
    ' "$f" > "$tmp"
    # Overwrite in place so the 0600 mode and the inode survive.
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

# Read one key back by sourcing in a subshell, so the quoting round-trips.
conf_get() { # conf_get <module> <key>
    local f
    f=$(conf_file "$1")
    [[ -r $f ]] || return 0
    (
        set +u
        # shellcheck source=/dev/null
        source "$f"
        printf '%s' "${!2}"
    )
}

# Pull every key into the caller, for a module reconfiguring itself.
conf_load() { # conf_load <module>
    local f
    f=$(conf_file "$1")
    [[ -r $f ]] || return 1
    # shellcheck source=/dev/null
    source "$f"
}

conf_clear() { rm -f "$(conf_file "$1")"; }
conf_exists() { [[ -f $(conf_file "$1") ]]; }

# ---------------------------------------------------------------- systemd --

# systemd_oneshot <unit> <description> <exec> <OnCalendar>
# Writes a oneshot service plus a timer, both niced down, and enables the timer.
systemd_oneshot() {
    local unit=$1 desc=$2 exec=$3 schedule=$4

    cat > "$TOOLBOX_SYSTEMD_DIR/$unit.service" <<EOF
[Unit]
Description=$desc
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$exec
Nice=10
IOSchedulingClass=idle
# Anything a module writes without an explicit mode inherits this. Without it
# the default is 0022, so files land 0644 - which for a module that keeps a
# copy of the host's configuration means directory permissions are the only
# thing standing between that and every local user.
UMask=0077
TimeoutStartSec=900
StandardOutput=journal
StandardError=journal
EOF

    cat > "$TOOLBOX_SYSTEMD_DIR/$unit.timer" <<EOF
[Unit]
Description=$desc (timer)

[Timer]
OnCalendar=$schedule
RandomizedDelaySec=120
Persistent=true
Unit=$unit.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "$unit.timer" >/dev/null 2>&1
    ok "enabled $unit.timer  ($schedule)"
}

systemd_remove() { # systemd_remove <unit>
    if systemctl list-unit-files 2>/dev/null | grep -q "^$1.timer"; then
        systemctl disable --now "$1.timer" >/dev/null 2>&1 || true
    fi
    rm -f "$TOOLBOX_SYSTEMD_DIR/$1.service" "$TOOLBOX_SYSTEMD_DIR/$1.timer"
    systemctl daemon-reload
}

wait_for_idle() { # wait_for_idle <unit> [timeout]
    local unit=$1 limit=${2:-120} waited=0
    while systemctl is-active --quiet "$unit.service"; do
        [[ $waited -eq 0 ]] && info "$unit is running, waiting for it to finish..."
        sleep 5; waited=$((waited + 5))
        if [[ $waited -ge $limit ]]; then
            warn "$unit still running after ${limit}s - stopping it"
            systemctl stop "$unit.service" || true
            break
        fi
    done
}

run_unit() { # run_unit <unit> -> 0 on success, dumps journal on failure
    if systemctl start "$1.service"; then
        ok "$1 completed"
        return 0
    fi
    warn "$1 failed"
    journalctl -u "$1.service" -n 20 --no-pager || true
    return 1
}

# ------------------------------------------------------------------ misc --

# install_toolbox_lib <name>... - put a lib/*.sh next to the installed helper
# scripts, so a runner in TOOLBOX_BIN_DIR can source it without needing this
# checkout to still be around.
install_toolbox_lib() {
    local src n
    mkdir -p "$TOOLBOX_LIB_DIR"
    for n in "$@"; do
        src="${BASH_SOURCE[0]%/*}/$n"
        [[ -f $src ]] || die "missing shared lib: $src"
        install -m 0644 "$src" "$TOOLBOX_LIB_DIR/$n"
        ok "installed $TOOLBOX_LIB_DIR/$n"
    done
}

backup_file() {
    [[ -f $1 ]] || return 0
    local bak
    bak="$1.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$1" "$bak"
    warn "backed up existing $(basename "$1") -> $(basename "$bak")"
}
