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

# ask <varname> <prompt> <default>
ask() {
    local __var=$1 __prompt=$2 __default=$3 __reply
    if [[ -n ${!__var:-} ]]; then __default=${!__var}; fi
    if [[ $ASSUME_YES -eq 1 ]]; then
        printf -v "$__var" '%s' "$__default"
        return 0
    fi
    read -r -p "$(printf '%s [%s]: ' "$__prompt" "$c_dim$__default$c_reset")" __reply || true
    printf -v "$__var" '%s' "${__reply:-$__default}"
}

# ask_secret <varname> <prompt>
ask_secret() {
    local __var=$1 __prompt=$2 __reply
    if [[ $ASSUME_YES -eq 1 || -n ${!__var:-} ]]; then return 0; fi
    read -r -s -p "$(printf '%s: ' "$__prompt")" __reply || true
    echo
    printf -v "$__var" '%s' "$__reply"
}

# ask_yn <varname> <prompt> <y|n>
ask_yn() {
    local __var=$1 __prompt=$2 __default=$3 __reply
    if [[ -n ${!__var:-} ]]; then __default=${!__var}; fi
    if [[ $ASSUME_YES -eq 1 ]]; then
        printf -v "$__var" '%s' "$__default"
        return 0
    fi
    while true; do
        read -r -p "$(printf '%s (y/n) [%s]: ' "$__prompt" "$c_dim$__default$c_reset")" __reply || true
        __reply=${__reply:-$__default}
        case ${__reply,,} in
            y|yes) printf -v "$__var" 'y'; return 0 ;;
            n|no)  printf -v "$__var" 'n'; return 0 ;;
            *) warn "please answer y or n" ;;
        esac
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

# gh_fetch_checksums -> sets CHECKSUM_FILE (may be empty)
gh_fetch_checksums() {
    local url
    CHECKSUM_FILE=""
    url=$(gh_checksums)
    [[ -z $url ]] && { warn "release has no checksum file"; return 0; }
    CHECKSUM_FILE=$(mktemp)
    curl -fsSL -o "$CHECKSUM_FILE" "$url" || CHECKSUM_FILE=""
}

verify_checksum() { # verify_checksum <file> <asset-name>
    [[ -n ${CHECKSUM_FILE:-} && -s ${CHECKSUM_FILE:-} ]] || return 0
    local expected actual
    expected=$(awk -v n="$2" 'index($2, n) || index($2, "*"n) {print $1}' "$CHECKSUM_FILE" | head -n1)
    [[ -z $expected ]] && { warn "no checksum entry for $2"; return 0; }
    actual=$(sha256sum "$1" | awk '{print $1}')
    [[ $expected == "$actual" ]] || return 1
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

# is_newer <candidate> <current> -> 0 if candidate sorts strictly above current
is_newer() {
    [[ $1 == "$2" ]] && return 1
    [[ -z $2 || $2 == unknown ]] && return 0
    local top
    top=$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -V | tail -n1)
    [[ $top == "${1#v}" ]]
}

# ------------------------------------------------------------------ state --

_state_file() { printf '%s/%s.state' "$TOOLBOX_STATE_DIR" "$1"; }

state_set() { # state_set <module> <key> <value>
    local f; f=$(_state_file "$1")
    mkdir -p "$TOOLBOX_STATE_DIR"
    touch "$f"; chmod 0644 "$f"
    if grep -q "^$2=" "$f" 2>/dev/null; then
        sed -i "s|^$2=.*|$2=$3|" "$f"
    else
        printf '%s=%s\n' "$2" "$3" >> "$f"
    fi
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
