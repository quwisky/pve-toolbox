# shellcheck shell=bash
#
# Template module. Copy the directory, rename it, edit the metadata, fill
# in the four functions. Directories starting with _ are skipped by the
# launcher, so this file is never offered in the menu.
#
# Contract
# --------
#   Metadata (evaluated at source time - keep this file side-effect free):
#     MODULE_NAME       machine name, must equal the directory name
#     MODULE_TITLE      short human name for the menu
#     MODULE_DESC       one line describing what it does
#     MODULE_TAGS       space separated, used by `pve-toolbox list <tag>`
#     MODULE_HOST_ONLY  1 if it must run on the PVE host rather than an LXC
#
#   Functions:
#     module_install      interactive install / reconfigure
#     module_update       [--check] update in place; honours $FORCE
#     module_status       one line for the menu; print exactly 'not installed'
#                         and exit 1 if it is not. That string is compared
#                         exactly to decide what update/uninstall/ui act on,
#                         so a longer line merely containing the words counts
#                         as installed.
#     module_status_long  detailed status (optional, falls back to status)
#     module_uninstall    remove what install created
#
# Everything in lib/common.sh is already sourced: info/ok/warn/die/step,
# ask/ask_yn/ask_secret/confirm, require_root/require_pve, detect_arch,
# pkg_ensure, gh_release/install_release_binary/rollback_binary,
# state_get/state_set, conf_get/conf_set, systemd_oneshot/systemd_remove,
# run_unit, backup_file, discord_notify, install_toolbox_lib.
#
# Two places to persist things, and the difference matters:
#   state_set  /var/lib/pve-toolbox/<module>.state  0644, what the module knows
#   conf_set   /etc/pve-toolbox/<module>.conf       0600, what the operator set
# Anything secret - a token, a webhook URL, a password - belongs in conf.
# Conf files are KEY='value' and stay sourceable, so a helper script you drop
# into TOOLBOX_BIN_DIR can read one without this library.
#
# The launcher reads this metadata indirectly, in meta().
# shellcheck disable=SC2034
MODULE_NAME="_template"
MODULE_TITLE="Template"
MODULE_DESC="copy this directory to start a new module"
MODULE_TAGS="example"
MODULE_HOST_ONLY=0

module_install() {
    require_root

    local answer=""
    ask answer "some setting" "default-value"

    # ... do the work ...
    dim "  you picked: $answer"

    conf_set  "$MODULE_NAME" SOME_TOKEN "$answer"        # 0600, secrets
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"  # 0644, facts
    ok "installed"
}

module_update() {
    local check_only=0
    [[ ${1:-} == --check ]] && check_only=1
    [[ $check_only -eq 1 ]] && { ok "nothing to check"; return 0; }
    ok "nothing to update"
}

module_status() {
    state_exists "$MODULE_NAME" || { printf 'not installed'; return 1; }
    printf 'installed'
}

module_uninstall() {
    require_root
    conf_clear "$MODULE_NAME"
    state_clear "$MODULE_NAME"
    ok "removed"
}
