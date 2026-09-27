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
#     MODULE_EXPLICIT_UPDATE optional 1: default off in the Update checklist;
#                          module_update must guard TOOLBOX_UPDATE_EXPLICIT.
#                          --check remains read-only regardless of selection.
#     MODULE_HOST_ONLY  1 if it must run on the PVE host rather than an LXC
#     MODULE_CONFIG_PUBLIC optional: the conf keys `pve-toolbox config show`
#                       may print the value of, space separated; shell glob
#                       patterns such as JOB_*_SRC work. Hidden by default:
#                       every key not listed shows only whether it is set, so
#                       leave out anything that could ever hold a secret -
#                       a token, a webhook URL, a password, a remote URL that
#                       can embed credentials, a key or token file path.
#                       config show parses the stored KEY='value' lines and
#                       never runs the file: a $ or " inside the quotes is
#                       shown literally, a line outside that form refuses the
#                       file, and public values go through the usual cleanup
#                       (credential URLs redacted, newlines joined, control
#                       characters replaced).
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
#     module_doctor       emit read-only health results with doctor_result
#                         (optional; called only for installed modules)
#     module_uninstall    remove what install created
#     module_config_files optional: extra conf names `config show` displays
#                         after <module>.conf, one per line, each matching
#                         ^[a-z0-9][a-z0-9-]*$. Read-only: print names and
#                         nothing else, and exit 0. Read with conf_get, which
#                         config show replaces with its own parser (conf_load
#                         is refused, stderr is discarded). For example:
#                           module_config_files() {
#                               local id
#                               for id in $(conf_get "$MODULE_NAME" MY_IDS); do
#                                   if [[ $id =~ ^[0-9]+$ ]]; then
#                                       printf '%s-%s\n' "$MODULE_NAME" "$id"
#                                   fi
#                               done
#                           }
#
# Everything in lib/common.sh is already sourced: info/ok/warn/die/step,
# ask/ask_valid/ask_int/ask_choice/ask_schedule/ask_yn/ask_secret/confirm,
# require_root/require_pve, detect_arch,
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
# KEEP_DAYS is a plain number, so config show may print it; SOME_TOKEN is
# not listed, so it shows only as "(set, hidden)".
MODULE_CONFIG_PUBLIC="KEEP_DAYS"

module_install() {
    require_root

    # Ask everything before writing anything: a prompt that cannot be
    # answered ends the module, and nothing should be half-configured.
    local answer="" keep=7
    ask answer "some setting" "default-value"
    ask_int keep "days to keep" "$keep" 1 365

    # ... do the work ...
    dim "  you picked: $answer, keeping $keep days"

    conf_set  "$MODULE_NAME" SOME_TOKEN "$answer"        # 0600, secrets
    conf_set  "$MODULE_NAME" KEEP_DAYS "$keep"           # 0600, public
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

module_doctor() {
    # IDs are automatically namespaced under module.<name> by the launcher.
    doctor_result pass service "example service is healthy"
}

module_uninstall() {
    require_root
    conf_clear "$MODULE_NAME"
    state_clear "$MODULE_NAME"
    ok "removed"
}
