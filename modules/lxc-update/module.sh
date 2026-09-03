# shellcheck shell=bash
# Module discovery must not probe or modify guests.
# shellcheck disable=SC2034
MODULE_NAME="lxc-update"
MODULE_TITLE="LXC package updates"
MODULE_DESC="confirmed local Debian/Ubuntu container package updates"
MODULE_TAGS="lxc upgrade apt notify"
MODULE_HOST_ONLY=1

module_install() {
    require_root
    local LX_EXCLUDE="" DISCORD_WEBHOOK="" id replacement=""
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    ask LX_EXCLUDE "Excluded container IDs, space-separated (use none to clear)" "${LX_EXCLUDE:-none}"
    [[ $LX_EXCLUDE != none ]] || LX_EXCLUDE=""
    for id in $LX_EXCLUDE; do
        [[ $id =~ ^[1-9][0-9]{2,8}$ ]] || { warn "invalid container ID: $id"; return 1; }
    done
    if [[ $ASSUME_YES == 0 ]]; then
        ask_secret replacement "Discord webhook URL (blank keeps existing; none clears)"
        [[ -z $replacement ]] || DISCORD_WEBHOOK=$replacement
    fi
    [[ $DISCORD_WEBHOOK != none ]] || DISCORD_WEBHOOK=""
    conf_set "$MODULE_NAME" LX_EXCLUDE "$LX_EXCLUDE"
    conf_set "$MODULE_NAME" DISCORD_WEBHOOK "$DISCORD_WEBHOOK"
    ok "configured; run pve-toolbox lxc-update --dry-run to preview"
}

module_update() {
    # Updating the toolbox must never start guest maintenance.
    info "LXC updater follows the installed toolbox version; guest packages unchanged"
}

module_status() {
    conf_exists "$MODULE_NAME" || { printf 'not installed'; return 1; }
    printf 'configured (manual updates)'
}

module_status_long() {
    module_status || return 1
    printf '\nExcluded IDs: %s\n' "$(conf_get "$MODULE_NAME" LX_EXCLUDE)"
    if [[ -n $(conf_get "$MODULE_NAME" DISCORD_WEBHOOK) ]]; then
        printf 'Discord webhook: configured (send only with --notify)\n'
    fi
    printf 'Last run: %s\n' "$(state_get "$MODULE_NAME" last_summary)"
    printf 'Last report: %s/lxc-update.state\n' "$TOOLBOX_STATE_DIR"
    if state_exists "$MODULE_NAME"; then
        awk '/^ct_[0-9]+=/ {id=$0; sub(/=.*/, "", id); sub(/^[^=]*=/, ""); print id " " $0}' \
            "$(_state_file "$MODULE_NAME")"
    fi
}

module_uninstall() {
    require_root
    conf_clear "$MODULE_NAME"
    # Retain the last report and the lock inode; neither is an installed helper.
    ok "removed LXC updater configuration; last report retained"
}
