# shellcheck shell=bash
#
# Scrutiny collector binaries + systemd timers on a Proxmox host.
# The Scrutiny web UI and InfluxDB are expected to run elsewhere.
#
# The launcher reads this metadata indirectly, in meta().
# shellcheck disable=SC2034
MODULE_NAME="scrutiny-collectors"
MODULE_TITLE="Scrutiny collectors"
MODULE_DESC="SMART / ZFS / MDADM collectors reporting to a remote Scrutiny web instance"
MODULE_TAGS="storage monitoring smart zfs"
MODULE_HOST_ONLY=1        # must run on the PVE host, not in an LXC

REPO="Starosdev/scrutiny"
CONFIG_DIR="/opt/scrutiny/config"
UNIT_PREFIX="scrutiny-collector"

declare -A SC_BIN=(
    [metrics]=scrutiny-collector-metrics
    [zfs]=scrutiny-collector-zfs
    [mdadm]=scrutiny-collector-mdadm
    [performance]=scrutiny-collector-performance
)
declare -A SC_ASSET=(
    [metrics]='collector-metrics'
    [zfs]='collector-zfs'
    [mdadm]='collector-mdadm'
    [performance]='collector-performance'
)
declare -A SC_CONFIG=(
    [metrics]=collector.yaml
    [zfs]=collector-zfs.yaml
    [mdadm]=collector-mdadm.yaml
    [performance]=collector-performance.yaml
)
declare -A SC_DESC=(
    [metrics]="Scrutiny SMART collector"
    [zfs]="Scrutiny ZFS pool collector"
    [mdadm]="Scrutiny MDADM collector"
    [performance]="Scrutiny performance collector"
)
SC_ORDER=(metrics zfs mdadm performance)

# ------------------------------------------------------------- internals --

_sc_defaults() {
    : "${SCRUTINY_API_ENDPOINT:=}"
    : "${SCRUTINY_API_TOKEN:=}"
    : "${SCRUTINY_HOST_ID:=$(hostname -s)}"
    : "${SCRUTINY_VERSION:=latest}"
    : "${SCRUTINY_SCHEDULE_METRICS:=*-*-* 04:00:00}"
    : "${SCRUTINY_SCHEDULE_ZFS:=*:0/15}"
    : "${SCRUTINY_SCHEDULE_MDADM:=*:0/15}"
    : "${SCRUTINY_SCHEDULE_PERFORMANCE:=Sun *-*-* 02:00:00}"
}

_sc_installed() {
    SC_PRESENT=()
    local s
    for s in "${SC_ORDER[@]}"; do
        if [[ -x "$TOOLBOX_BIN_DIR/${SC_BIN[$s]}" ]]; then SC_PRESENT+=("$s"); fi
    done
    return 0
}

# _sc_compare <installed> <tag> -> same | upgrade | downgrade
#
# Pure, so the decision `update` and `check` share can be tested without a
# release API or an installed collector.
_sc_compare() {
    [[ $(version_bare "$1") == "$(version_bare "$2")" ]] && { printf 'same'; return 0; }
    if is_newer "$2" "$1"; then printf 'upgrade'; else printf 'downgrade'; fi
}

_sc_version() {
    local v
    v=$(state_get "$MODULE_NAME" VERSION)
    if [[ -z $v ]]; then
        local s bin
        for s in "${SC_ORDER[@]}"; do
            bin="$TOOLBOX_BIN_DIR/${SC_BIN[$s]}"
            [[ -x $bin ]] || continue
            v=$("$bin" --version 2>/dev/null | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1) || true
            [[ -n $v ]] && break
        done
    fi
    printf '%s' "${v:-unknown}"
}

_sc_write_config() { # _sc_write_config <suffix>
    local file="$CONFIG_DIR/${SC_CONFIG[$1]}"
    backup_file "$file"
    {
        echo "# managed by pve-toolbox / $MODULE_NAME"
        echo "host:"
        echo "  id: \"$SCRUTINY_HOST_ID\""
        echo "api:"
        echo "  endpoint: \"$SCRUTINY_API_ENDPOINT\""
        echo "  timeout: 60"
        [[ -n $SCRUTINY_API_TOKEN ]] && echo "  token: \"$SCRUTINY_API_TOKEN\""
        echo "log:"
        echo "  level: INFO"
        if [[ $1 == performance ]]; then
            echo "performance:"
            echo "  enabled: true"
            echo "  profile: quick"
        fi
    } > "$file"
    chmod 0640 "$file"
    ok "wrote $file"
}

_sc_schedule_for() {
    local var="SCRUTINY_SCHEDULE_${1^^}"
    printf '%s' "${!var}"
}

# --------------------------------------------------------------- install --

module_install() {
    require_root
    require_pve
    _sc_defaults

    local arch; arch="linux-$(detect_arch)"
    ok "architecture: $arch"
    pkg_ensure curl:curl jq:jq smartctl:smartmontools

    step "Scrutiny web instance"
    while [[ -z $SCRUTINY_API_ENDPOINT ]]; do
        ask SCRUTINY_API_ENDPOINT "API endpoint of the Scrutiny web container" "http://10.0.0.10:8080"
    done
    SCRUTINY_API_ENDPOINT=${SCRUTINY_API_ENDPOINT%/}
    ask_secret SCRUTINY_API_TOKEN "collector API token (blank if auth is off)"
    ask SCRUTINY_HOST_ID "host id shown in the dashboard" "$SCRUTINY_HOST_ID"

    if curl -fsS --max-time 8 "$SCRUTINY_API_ENDPOINT/api/health" >/dev/null 2>&1; then
        ok "web API reachable"
    else
        warn "could not reach $SCRUTINY_API_ENDPOINT/api/health"
        confirm "continue anyway?" "y" || return 1
    fi

    step "Which collectors?"
    local want=() pick
    pick=y; ask_yn pick "SMART metrics collector" "y"; [[ $pick == y ]] && want+=(metrics)

    if have_zfs; then
        ok "pools: $(zpool list -H -o name 2>/dev/null | tr '\n' ' ')"
        pick=y; ask_yn pick "ZFS pool collector" "y"; [[ $pick == y ]] && want+=(zfs)
    else
        warn "no zpool binary - skipping ZFS collector"
    fi

    if have_mdadm; then
        pick=y; ask_yn pick "MDADM collector" "y"; [[ $pick == y ]] && want+=(mdadm)
    fi

    pick=n; ask_yn pick "fio performance collector (adds real disk load)" "n"
    [[ $pick == y ]] && want+=(performance)

    [[ ${#want[@]} -eq 0 ]] && { warn "nothing selected"; return 1; }

    local s var
    for s in "${want[@]}"; do
        var="SCRUTINY_SCHEDULE_${s^^}"
        ask "$var" "  $s schedule (systemd OnCalendar)" "${!var}"
    done
    ask SCRUTINY_VERSION "release tag" "$SCRUTINY_VERSION"

    step "Download"
    gh_release "$REPO" "$SCRUTINY_VERSION"
    ok "release: $GH_TAG"
    gh_fetch_checksums
    mkdir -p "$CONFIG_DIR"

    local got=()
    for s in "${want[@]}"; do
        install_release_binary "${SC_ASSET[$s]}" "$arch" "${SC_BIN[$s]}" && got+=("$s")
    done
    [[ -n ${CHECKSUM_FILE:-} ]] && rm -f "$CHECKSUM_FILE"
    [[ ${#got[@]} -eq 0 ]] && die "no matching release assets found in $GH_TAG"

    step "Config and systemd units"
    for s in "${got[@]}"; do
        _sc_write_config "$s"
        systemd_oneshot "$UNIT_PREFIX-$s" "${SC_DESC[$s]}" \
            "$TOOLBOX_BIN_DIR/${SC_BIN[$s]} run --config $CONFIG_DIR/${SC_CONFIG[$s]}" \
            "$(_sc_schedule_for "$s")"
    done

    step "Verification"
    local run=y
    ask_yn run "run each collector once now?" "y"
    if [[ $run == y ]]; then
        for s in "${got[@]}"; do
            [[ $s == performance ]] && { warn "skipping fio test run (heavy I/O)"; continue; }
            run_unit "$UNIT_PREFIX-$s" || true
        done
    fi

    state_set "$MODULE_NAME" VERSION "$GH_TAG"
    state_set "$MODULE_NAME" ARCH "$arch"
    state_set "$MODULE_NAME" COLLECTORS "${got[*]}"
    state_set "$MODULE_NAME" ENDPOINT "$SCRUTINY_API_ENDPOINT"
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"

    step "Done - $GH_TAG"
    dim "  systemctl list-timers '$UNIT_PREFIX-*'"
    dim "  ZED still beats any polling interval; keep your ZED -> Discord hook."
}

# ---------------------------------------------------------------- update --

# module_update [--check]
module_update() {
    require_root
    local check_only=0
    [[ ${1:-} == --check ]] && check_only=1

    pkg_ensure curl:curl jq:jq
    local arch; arch="linux-$(detect_arch)"
    _sc_installed
    [[ ${#SC_PRESENT[@]} -eq 0 ]] && die "no collectors installed"

    local current; current=$(_sc_version)
    gh_release "$REPO" "${SCRUTINY_VERSION:-latest}"

    printf '  installed  %s (%s)\n' "$current" "${SC_PRESENT[*]}"
    printf '  available  %s\n' "$GH_TAG"

    local rel; rel=$(_sc_compare "$current" "$GH_TAG")

    # -f means "reinstall anyway", not "report differently", so check answers
    # before FORCE is consulted - otherwise `-f check` claims an update to the
    # release already installed.
    if [[ $check_only -eq 1 ]]; then
        case $rel in
            same)      ok "up to date"; return 0 ;;
            upgrade)   info "update available: $current -> $GH_TAG" ;;
            downgrade) warn "$GH_TAG is older than the installed $current" ;;
        esac
        dim "  https://github.com/$REPO/releases/tag/$GH_TAG"
        return 0
    fi
    if [[ $rel == same && ${FORCE:-0} -eq 0 ]]; then
        ok "up to date"
        return 0
    fi
    if [[ $rel == downgrade && ${FORCE:-0} -eq 0 ]]; then
        warn "$GH_TAG is not newer than $current - this would be a downgrade"
        confirm "proceed anyway?" "n" || return 0
    fi
    confirm "update ${#SC_PRESENT[@]} collector(s) to $GH_TAG?" "y" || return 0

    gh_fetch_checksums

    step "Pausing timers"
    local s
    for s in "${SC_PRESENT[@]}"; do
        systemctl stop "$UNIT_PREFIX-$s.timer" 2>/dev/null || true
        wait_for_idle "$UNIT_PREFIX-$s"
    done

    step "Replacing binaries"
    local updated=()
    for s in "${SC_PRESENT[@]}"; do
        install_release_binary "${SC_ASSET[$s]}" "$arch" "${SC_BIN[$s]}" && updated+=("$s")
    done
    [[ -n ${CHECKSUM_FILE:-} ]] && rm -f "$CHECKSUM_FILE"

    if [[ ${#updated[@]} -eq 0 ]]; then
        for s in "${SC_PRESENT[@]}"; do systemctl start "$UNIT_PREFIX-$s.timer" 2>/dev/null || true; done
        die "no binaries replaced - no matching assets in $GH_TAG"
    fi

    step "Smoke test"
    local broken=()
    for s in "${updated[@]}"; do
        [[ $s == performance ]] && { warn "skipping fio test run"; continue; }
        run_unit "$UNIT_PREFIX-$s" || broken+=("$s")
    done

    if [[ ${#broken[@]} -gt 0 ]]; then
        step "Rollback"
        for s in "${broken[@]}"; do
            if rollback_binary "${SC_BIN[$s]}"; then
                run_unit "$UNIT_PREFIX-$s" >/dev/null 2>&1 \
                    && ok "$s healthy again on the previous build" \
                    || warn "$s still failing after rollback - check its config"
            fi
        done
    fi

    step "Resuming timers"
    for s in "${SC_PRESENT[@]}"; do systemctl start "$UNIT_PREFIX-$s.timer" 2>/dev/null || true; done

    if [[ ${#broken[@]} -eq 0 ]]; then
        state_set "$MODULE_NAME" VERSION "$GH_TAG"
        state_set "$MODULE_NAME" UPDATED_AT "$(date -Is)"
        for s in "${updated[@]}"; do rm -f "$TOOLBOX_BIN_DIR/${SC_BIN[$s]}.prev"; done
        step "Updated to $GH_TAG"
    else
        warn "state kept at $current because these rolled back: ${broken[*]}"
    fi
}

# ---------------------------------------------------------------- status --

module_status() {
    _sc_installed
    if [[ ${#SC_PRESENT[@]} -eq 0 ]]; then
        printf 'not installed'
        return 1
    fi
    printf '%s  [%s]' "$(_sc_version)" "${SC_PRESENT[*]}"
}

module_status_long() {
    _sc_installed
    if [[ ${#SC_PRESENT[@]} -eq 0 ]]; then
        warn "not installed"
        return 1
    fi
    printf '  version    %s\n' "$(_sc_version)"
    printf '  endpoint   %s\n' "$(state_get "$MODULE_NAME" ENDPOINT)"
    printf '  collectors %s\n' "${SC_PRESENT[*]}"
    echo
    systemctl list-timers "$UNIT_PREFIX-*" --no-pager 2>/dev/null || true
}

# ------------------------------------------------------------- uninstall --

module_uninstall() {
    require_root
    _sc_installed
    local s
    for s in "${SC_ORDER[@]}"; do
        systemd_remove "$UNIT_PREFIX-$s"
        rm -f "$TOOLBOX_BIN_DIR/${SC_BIN[$s]}" "$TOOLBOX_BIN_DIR/${SC_BIN[$s]}.prev"
    done
    state_clear "$MODULE_NAME"
    ok "binaries and units removed"
    warn "config left in place: $CONFIG_DIR"
}
