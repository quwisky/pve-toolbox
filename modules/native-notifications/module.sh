# shellcheck shell=bash
#
# Idempotent native PVE notification endpoint and matcher provisioning.
# Secrets live only in the root-only module config and PVE's protected config.
# shellcheck disable=SC2034
MODULE_NAME="native-notifications"
MODULE_TITLE="Native PVE notifications"
MODULE_DESC="provision owned webhook, Discord, Gotify, or SMTP targets and matchers"
MODULE_TAGS="monitoring notify webhook smtp gotify"
MODULE_HOST_ONLY=1

NT_MARKER="managed by pve-toolbox/native-notifications"
NT_HELPER="pve-toolbox-native-notify"
NT_TEMPLATE_FILES=(
    pve-toolbox-subject.txt.hbs
    pve-toolbox-body.txt.hbs
    pve-toolbox-body.html.hbs
)
NT_CONF_KEYS=(
    NT_KIND NT_TARGET_NAME NT_MATCHER_NAME NT_MATCH_SEVERITY NT_MATCH_FIELD NT_MATCH_MODE
    NT_WEBHOOK_URL NT_WEBHOOK_METHOD NT_WEBHOOK_BODY NT_WEBHOOK_HEADER_NAME
    NT_WEBHOOK_HEADER_VALUE NT_WEBHOOK_SECRET_NAME NT_WEBHOOK_SECRET_VALUE
    NT_DISCORD_WEBHOOK NT_GOTIFY_SERVER NT_GOTIFY_TOKEN NT_SMTP_SERVER NT_SMTP_PORT
    NT_SMTP_MODE NT_SMTP_USERNAME NT_SMTP_PASSWORD NT_SMTP_MAILTO NT_SMTP_FROM
)
NT_JSON=""
NT_ERROR=""

_nt_dir() { printf '%s/modules/%s' "${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}" "$MODULE_NAME"; }
_nt_src() { printf '%s/%s' "$(_nt_dir)" "$1"; }
_nt_helper_src() {
    local root=${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}
    if [[ -f $root/scripts/$NT_HELPER ]]; then
        printf '%s/scripts/%s' "$root" "$NT_HELPER"
    else
        printf '/usr/bin/%s' "$NT_HELPER"
    fi
}
_nt_template_src() {
    local root=${TOOLBOX_ROOT:-/usr/lib/pve-toolbox}
    if [[ -f $root/share/notification-templates/$1 ]]; then
        printf '%s/share/notification-templates/%s' "$root" "$1"
    else
        printf '/usr/share/pve-toolbox/notification-templates/%s' "$1"
    fi
}
_nt_template_dir() { printf '%s' "${NT_TEMPLATE_DIR:-/etc/pve/notification-templates/default}"; }
_nt_pve_dir() { printf '%s' "${NT_PVE_DIR:-/etc/pve}"; }

_nt_defaults() {
    : "${NT_KIND:=discord}"
    : "${NT_TARGET_NAME:=pve-toolbox-$NT_KIND}"
    : "${NT_MATCHER_NAME:=pve-toolbox-$NT_KIND}"
    : "${NT_MATCH_SEVERITY:=warning,error}"
    : "${NT_MATCH_FIELD:=}"
    : "${NT_MATCH_MODE:=all}"
    : "${NT_WEBHOOK_URL:=}"
    : "${NT_WEBHOOK_METHOD:=post}"
    : "${NT_WEBHOOK_BODY:={\"title\":\"{{ escape title }}\",\"message\":\"{{ escape message }}\",\"severity\":\"{{ severity }}\"}}"
    : "${NT_WEBHOOK_HEADER_NAME:=Content-Type}"
    : "${NT_WEBHOOK_HEADER_VALUE:=application/json}"
    : "${NT_WEBHOOK_SECRET_NAME:=}"
    : "${NT_WEBHOOK_SECRET_VALUE:=}"
    : "${NT_DISCORD_WEBHOOK:=}"
    : "${NT_GOTIFY_SERVER:=}"
    : "${NT_GOTIFY_TOKEN:=}"
    : "${NT_SMTP_SERVER:=}"
    : "${NT_SMTP_PORT:=587}"
    : "${NT_SMTP_MODE:=starttls}"
    : "${NT_SMTP_USERNAME:=}"
    : "${NT_SMTP_PASSWORD:=}"
    : "${NT_SMTP_MAILTO:=}"
    : "${NT_SMTP_FROM:=}"
}

_nt_load_conf() {
    _nt_defaults
    conf_load "$MODULE_NAME"
}

_nt_prepare_install() {
    local key
    local -A supplied=()
    for key in "${NT_CONF_KEYS[@]}"; do
        if [[ -v $key ]]; then supplied[$key]=${!key}; fi
    done
    _nt_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    for key in "${!supplied[@]}"; do
        printf -v "$key" '%s' "${supplied[$key]}"
    done
}

_nt_api_type() {
    case $NT_KIND in
        discord|webhook) printf 'webhook' ;;
        gotify|smtp) printf '%s' "$NT_KIND" ;;
    esac
}

_nt_validate_name() {
    [[ $1 =~ ^[A-Za-z][A-Za-z0-9._-]*$ && $1 == pve-toolbox-* ]]
}

_nt_validate_url() {
    [[ $1 =~ ^https?://[^[:space:]]+$ && ! $1 =~ ^https?://[^/@]+@ ]]
}

_nt_validate() {
    NT_ERROR=""
    case $NT_KIND in discord|webhook|gotify|smtp) ;; *) NT_ERROR="unsupported target kind"; return 1 ;; esac
    _nt_validate_name "$NT_TARGET_NAME" \
        || { NT_ERROR="target name must start with pve-toolbox- and be a valid PVE config ID"; return 1; }
    _nt_validate_name "$NT_MATCHER_NAME" \
        || { NT_ERROR="matcher name must start with pve-toolbox- and be a valid PVE config ID"; return 1; }
    [[ $NT_MATCH_MODE == all || $NT_MATCH_MODE == any ]] \
        || { NT_ERROR="matcher mode must be all or any"; return 1; }
    local severity
    local -a severities=()
    IFS=',' read -r -a severities <<<"$NT_MATCH_SEVERITY"
    [[ ${#severities[@]} -gt 0 ]] || { NT_ERROR="at least one severity is required"; return 1; }
    for severity in "${severities[@]}"; do
        case $severity in info|notice|warning|error|unknown) ;; *) NT_ERROR="invalid matcher severity"; return 1 ;; esac
    done
    if [[ -n $NT_MATCH_FIELD && ! $NT_MATCH_FIELD =~ ^(exact|regex):[a-z0-9-]+=.+$ ]]; then
        NT_ERROR="match field must use exact:<field>=<value> or regex:<field>=<value>"
        return 1
    fi
    case $NT_KIND in
        discord)
            [[ $NT_DISCORD_WEBHOOK =~ ^https://(discord(app)?[.]com|ptb[.]discord[.]com)/api/webhooks/[0-9]+/[^[:space:]/]+$ ]] \
                || { NT_ERROR="Discord webhook URL is invalid"; return 1; }
            ;;
        webhook)
            _nt_validate_url "$NT_WEBHOOK_URL" \
                || { NT_ERROR="webhook URL must be HTTP(S) without embedded credentials"; return 1; }
            case $NT_WEBHOOK_METHOD in post|put|get) ;; *) NT_ERROR="webhook method must be post, put, or get"; return 1 ;; esac
            [[ $NT_WEBHOOK_SECRET_NAME =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] \
                || { NT_ERROR="webhook secret name is invalid"; return 1; }
            [[ -n $NT_WEBHOOK_SECRET_VALUE ]] \
                || { NT_ERROR="webhook secret value is required"; return 1; }
            [[ $NT_WEBHOOK_URL == *"{{ secrets.$NT_WEBHOOK_SECRET_NAME }}"* \
                || $NT_WEBHOOK_HEADER_VALUE == *"{{ secrets.$NT_WEBHOOK_SECRET_NAME }}"* \
                || $NT_WEBHOOK_BODY == *"{{ secrets.$NT_WEBHOOK_SECRET_NAME }}"* ]] \
                || { NT_ERROR="webhook URL, header, or body must reference its protected secret"; return 1; }
            ;;
        gotify)
            _nt_validate_url "$NT_GOTIFY_SERVER" \
                || { NT_ERROR="Gotify server URL must be HTTP(S) without embedded credentials"; return 1; }
            [[ -n $NT_GOTIFY_TOKEN ]] || { NT_ERROR="Gotify token is required"; return 1; }
            ;;
        smtp)
            [[ $NT_SMTP_SERVER =~ ^[A-Za-z0-9._:-]+$ ]] \
                || { NT_ERROR="SMTP server is invalid"; return 1; }
            [[ $NT_SMTP_PORT =~ ^[0-9]+$ && $NT_SMTP_PORT -ge 1 && $NT_SMTP_PORT -le 65535 ]] \
                || { NT_ERROR="SMTP port must be between 1 and 65535"; return 1; }
            case $NT_SMTP_MODE in insecure|starttls|tls) ;; *) NT_ERROR="SMTP mode is invalid"; return 1 ;; esac
            [[ $NT_SMTP_MAILTO == *@* && $NT_SMTP_FROM == *@* ]] \
                || { NT_ERROR="SMTP recipient and from address are required"; return 1; }
            [[ -z $NT_SMTP_USERNAME || -n $NT_SMTP_PASSWORD ]] \
                || { NT_ERROR="SMTP password is required with a username"; return 1; }
            ;;
    esac
}

_nt_owned() {
    state_exists "$MODULE_NAME" \
        && [[ $(state_get "$MODULE_NAME" TARGET_NAME) == "$NT_TARGET_NAME" \
           && $(state_get "$MODULE_NAME" MATCHER_NAME) == "$NT_MATCHER_NAME" \
           && $(state_get "$MODULE_NAME" TARGET_TYPE) == "$(_nt_api_type)" ]]
}

_nt_get() { # _nt_get <endpoint>
    NT_JSON=""
    if ! NT_JSON=$(pvesh get "$1" --output-format json 2>/dev/null); then
        NT_JSON=""
        return 1
    fi
    jq -e 'type == "object"' <<<"$NT_JSON" >/dev/null 2>&1
}

_nt_endpoint_path() { printf '/cluster/notifications/endpoints/%s/%s' "$(_nt_api_type)" "$NT_TARGET_NAME"; }
_nt_matcher_path() { printf '/cluster/notifications/matchers/%s' "$NT_MATCHER_NAME"; }

_nt_exists_endpoint() { _nt_get "$(_nt_endpoint_path)"; }
_nt_exists_matcher() { _nt_get "$(_nt_matcher_path)"; }

_nt_b64() { printf '%s' "$1" | base64 -w0; }

_nt_target_args() {
    NT_ARGS=(--comment "$NT_MARKER" --disable 0)
    case $NT_KIND in
        discord)
            local token=${NT_DISCORD_WEBHOOK#*/api/webhooks/}
            NT_ARGS+=(
                --url 'https://discord.com/api/webhooks/{{ secrets.token }}'
                --method post
                --header "name=Content-Type,value=$(_nt_b64 'application/json')"
                --body "$(_nt_b64 '{"content":"**{{ escape title }}**\n{{ escape message }}"}')"
                --secret "name=token,value=$(_nt_b64 "$token")"
            )
            ;;
        webhook)
            NT_ARGS+=(--url "$NT_WEBHOOK_URL" --method "$NT_WEBHOOK_METHOD")
            [[ -z $NT_WEBHOOK_BODY ]] || NT_ARGS+=(--body "$(_nt_b64 "$NT_WEBHOOK_BODY")")
            [[ -z $NT_WEBHOOK_HEADER_NAME ]] || NT_ARGS+=(
                --header "name=$NT_WEBHOOK_HEADER_NAME,value=$(_nt_b64 "$NT_WEBHOOK_HEADER_VALUE")"
            )
            [[ -z $NT_WEBHOOK_SECRET_NAME ]] || NT_ARGS+=(
                --secret "name=$NT_WEBHOOK_SECRET_NAME,value=$(_nt_b64 "$NT_WEBHOOK_SECRET_VALUE")"
            )
            ;;
        gotify)
            NT_ARGS+=(--server "$NT_GOTIFY_SERVER" --token "$NT_GOTIFY_TOKEN")
            ;;
        smtp)
            NT_ARGS+=(--server "$NT_SMTP_SERVER" --port "$NT_SMTP_PORT" \
                --mode "$NT_SMTP_MODE" --mailto "$NT_SMTP_MAILTO" \
                --from-address "$NT_SMTP_FROM")
            [[ -z $NT_SMTP_USERNAME ]] || NT_ARGS+=(--username "$NT_SMTP_USERNAME")
            [[ -z $NT_SMTP_PASSWORD ]] || NT_ARGS+=(--password "$NT_SMTP_PASSWORD")
            ;;
    esac
}

_nt_apply_target() { # _nt_apply_target <create|set>
    local action=$1 type
    type=$(_nt_api_type)
    _nt_target_args
    if [[ $action == create ]]; then
        pvesh create "/cluster/notifications/endpoints/$type" \
            --name "$NT_TARGET_NAME" "${NT_ARGS[@]}" >/dev/null 2>&1
    else
        case $NT_KIND in
            webhook)
                if [[ -z $NT_WEBHOOK_HEADER_NAME && -z $NT_WEBHOOK_BODY ]]; then
                    NT_ARGS+=(--delete "header,body")
                elif [[ -z $NT_WEBHOOK_HEADER_NAME ]]; then
                    NT_ARGS+=(--delete header)
                elif [[ -z $NT_WEBHOOK_BODY ]]; then
                    NT_ARGS+=(--delete body)
                fi
                ;;
            smtp)
                [[ -n $NT_SMTP_USERNAME ]] || NT_ARGS+=(--delete "username,password")
                ;;
        esac
        pvesh set "$(_nt_endpoint_path)" "${NT_ARGS[@]}" >/dev/null 2>&1
    fi
}

_nt_matcher_args() {
    NT_ARGS=(--target "$NT_TARGET_NAME" --match-severity "$NT_MATCH_SEVERITY" \
        --mode "$NT_MATCH_MODE" --comment "$NT_MARKER" --disable 0)
    [[ -z $NT_MATCH_FIELD ]] || NT_ARGS+=(--match-field "$NT_MATCH_FIELD")
}

_nt_apply_matcher() { # _nt_apply_matcher <create|set>
    local action=$1
    _nt_matcher_args
    if [[ $action == create ]]; then
        pvesh create /cluster/notifications/matchers --name "$NT_MATCHER_NAME" \
            "${NT_ARGS[@]}" >/dev/null 2>&1
    else
        # Delete an old field when reconfiguration intentionally clears it.
        [[ -n $NT_MATCH_FIELD ]] || NT_ARGS+=(--delete match-field)
        pvesh set "$(_nt_matcher_path)" "${NT_ARGS[@]}" >/dev/null 2>&1
    fi
}

_nt_remove_endpoint() { pvesh delete "$(_nt_endpoint_path)" >/dev/null 2>&1; }
_nt_remove_matcher() { pvesh delete "$(_nt_matcher_path)" >/dev/null 2>&1; }

_nt_test_target() {
    pvesh create "/cluster/notifications/targets/$NT_TARGET_NAME/test" >/dev/null 2>&1
}

_nt_snapshot_config() {
    local root dir file
    root="$TOOLBOX_STATE_DIR/native-notifications-backups"
    mkdir -p "$root"
    chmod 0700 "$root"
    dir=$(mktemp -d "$root/$(date +%Y%m%d%H%M%S).XXXXXX")
    chmod 0700 "$dir"
    for file in notifications.cfg priv/notifications.cfg; do
        if [[ $file == */* ]]; then mkdir -p "$dir/${file%/*}"; fi
        if [[ -f $(_nt_pve_dir)/$file ]]; then
            cp -a "$(_nt_pve_dir)/$file" "$dir/$file"
            chmod 0600 "$dir/$file"
        else
            : > "$dir/$file.absent"
            chmod 0600 "$dir/$file.absent"
        fi
    done
    printf '%s' "$dir"
}

_nt_install_assets() {
    local template_dir file
    template_dir=$(_nt_template_dir)
    mkdir -p "$TOOLBOX_BIN_DIR" "$template_dir"
    install -m 0755 "$(_nt_helper_src)" "$TOOLBOX_BIN_DIR/$NT_HELPER"
    for file in "${NT_TEMPLATE_FILES[@]}"; do
        install -m 0644 "$(_nt_template_src "$file")" "$template_dir/$file"
    done
}

_nt_backup_assets() { # _nt_backup_assets <directory>
    local backup=$1 template_dir file
    template_dir=$(_nt_template_dir)
    mkdir -p "$backup/templates"
    if [[ -f $TOOLBOX_BIN_DIR/$NT_HELPER ]]; then
        cp -a "$TOOLBOX_BIN_DIR/$NT_HELPER" "$backup/helper"
    fi
    for file in "${NT_TEMPLATE_FILES[@]}"; do
        if [[ -f $template_dir/$file ]]; then
            cp -a "$template_dir/$file" "$backup/templates/$file"
        fi
    done
}

_nt_restore_assets() { # _nt_restore_assets <directory>
    local backup=$1 template_dir file
    template_dir=$(_nt_template_dir)
    rm -f -- "$TOOLBOX_BIN_DIR/$NT_HELPER"
    for file in "${NT_TEMPLATE_FILES[@]}"; do
        rm -f -- "$template_dir/$file"
    done
    if [[ -f $backup/helper ]]; then
        install -m 0755 "$backup/helper" "$TOOLBOX_BIN_DIR/$NT_HELPER"
    fi
    for file in "${NT_TEMPLATE_FILES[@]}"; do
        if [[ -f $backup/templates/$file ]]; then
            install -m 0644 "$backup/templates/$file" "$template_dir/$file"
        fi
    done
}

_nt_installed_asset_sum() {
    local template_dir file
    template_dir=$(_nt_template_dir)
    [[ -f $TOOLBOX_BIN_DIR/$NT_HELPER ]] || return 1
    for file in "${NT_TEMPLATE_FILES[@]}"; do
        [[ -f $template_dir/$file ]] || return 1
    done
    {
        sha256sum "$TOOLBOX_BIN_DIR/$NT_HELPER"
        for file in "${NT_TEMPLATE_FILES[@]}"; do
            sha256sum "$template_dir/$file"
        done
    } | sha256sum | awk '{print $1}'
}

_nt_assets_owned_or_absent() {
    local template_dir file
    template_dir=$(_nt_template_dir)
    if ! state_exists "$MODULE_NAME"; then
        [[ ! -e $TOOLBOX_BIN_DIR/$NT_HELPER ]] || return 1
        for file in "${NT_TEMPLATE_FILES[@]}"; do
            [[ ! -e $template_dir/$file ]] || return 1
        done
    fi
}

_nt_assets_current() {
    local template_dir file
    template_dir=$(_nt_template_dir)
    cmp -s "$(_nt_helper_src)" "$TOOLBOX_BIN_DIR/$NT_HELPER" || return 1
    for file in "${NT_TEMPLATE_FILES[@]}"; do
        cmp -s "$(_nt_template_src "$file")" "$template_dir/$file" || return 1
    done
}

_nt_write_conf() {
    local key
    for key in "${NT_CONF_KEYS[@]}"; do
        conf_set "$MODULE_NAME" "$key" "${!key}"
    done
}

_nt_restore_previous() { # current globals are new; $1 old-conf or empty
    local old_conf=$1 current_kind=$NT_KIND current_target=$NT_TARGET_NAME
    local current_matcher=$NT_MATCHER_NAME target_existed=$2 matcher_existed=$3
    if [[ $matcher_existed -eq 0 ]]; then
        _nt_remove_matcher || true
    fi
    if [[ $target_existed -eq 0 ]]; then
        _nt_remove_endpoint || true
    fi
    [[ -n $old_conf && -r $old_conf ]] || return 0
    _nt_defaults
    # shellcheck source=/dev/null
    source "$old_conf"
    if [[ $target_existed -eq 1 ]]; then _nt_apply_target set || true; fi
    if [[ $matcher_existed -eq 1 ]]; then _nt_apply_matcher set || true; fi
    NT_KIND=$current_kind NT_TARGET_NAME=$current_target NT_MATCHER_NAME=$current_matcher
}

_nt_configure() {
    local target_existed=0 matcher_existed=0 target_action=create matcher_action=create
    local old_conf="" snapshot asset_backup
    asset_backup=$(mktemp -d)
    chmod 0700 "$asset_backup"
    _nt_backup_assets "$asset_backup"
    if conf_exists "$MODULE_NAME"; then
        old_conf=$(mktemp)
        cp -a "$(conf_file "$MODULE_NAME")" "$old_conf"
        chmod 0600 "$old_conf"
    fi

    if _nt_exists_endpoint; then
        target_existed=1
        _nt_owned || { [[ -z $old_conf ]] || rm -f -- "$old_conf"; rm -rf -- "$asset_backup"; die "target $NT_TARGET_NAME already exists and is not owned by this module"; }
        [[ $(jq -r '.comment // ""' <<<"$NT_JSON") == "$NT_MARKER" ]] \
            || { [[ -z $old_conf ]] || rm -f -- "$old_conf"; rm -rf -- "$asset_backup"; die "owned target marker changed; refusing to overwrite it"; }
        target_action="set"
    fi
    if _nt_exists_matcher; then
        matcher_existed=1
        _nt_owned || { [[ -z $old_conf ]] || rm -f -- "$old_conf"; rm -rf -- "$asset_backup"; die "matcher $NT_MATCHER_NAME already exists and is not owned by this module"; }
        [[ $(jq -r '.comment // ""' <<<"$NT_JSON") == "$NT_MARKER" ]] \
            || { [[ -z $old_conf ]] || rm -f -- "$old_conf"; rm -rf -- "$asset_backup"; die "owned matcher marker changed; refusing to overwrite it"; }
        matcher_action="set"
    fi
    _nt_assets_owned_or_absent \
        || { [[ -z $old_conf ]] || rm -f -- "$old_conf"; rm -rf -- "$asset_backup"; die "notification helper or template already exists without module ownership"; }

    snapshot=$(_nt_snapshot_config)
    dim "  backed up native notification config to $snapshot"
    if ! _nt_install_assets \
        || ! _nt_apply_target "$target_action" \
        || ! _nt_apply_matcher "$matcher_action" \
        || ! _nt_test_target; then
        _nt_restore_previous "$old_conf" "$target_existed" "$matcher_existed"
        _nt_restore_assets "$asset_backup"
        [[ -z $old_conf ]] || rm -f -- "$old_conf"
        rm -rf -- "$asset_backup"
        die "native notification configuration or test delivery failed; previous owned objects were restored"
    fi
    [[ -z $old_conf ]] || rm -f -- "$old_conf"
    rm -rf -- "$asset_backup"
    _nt_write_conf
    state_set "$MODULE_NAME" TARGET_TYPE "$(_nt_api_type)"
    state_set "$MODULE_NAME" TARGET_NAME "$NT_TARGET_NAME"
    state_set "$MODULE_NAME" MATCHER_NAME "$NT_MATCHER_NAME"
    state_set "$MODULE_NAME" ASSET_SUM "$(_nt_installed_asset_sum)"
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"
    ok "configured and tested $NT_KIND target $NT_TARGET_NAME"
}

module_install() {
    require_root
    require_pve
    _nt_prepare_install
    pkg_ensure jq:jq coreutils:base64

    ask NT_KIND "target kind (discord/webhook/gotify/smtp)" "$NT_KIND"
    [[ $NT_KIND == discord || $NT_KIND == webhook || $NT_KIND == gotify || $NT_KIND == smtp ]] \
        || die "unsupported target kind: $NT_KIND"
    if ! state_exists "$MODULE_NAME"; then
        [[ $NT_TARGET_NAME != pve-toolbox-discord || $NT_KIND == discord ]] \
            || NT_TARGET_NAME="pve-toolbox-$NT_KIND"
        [[ $NT_MATCHER_NAME != pve-toolbox-discord || $NT_KIND == discord ]] \
            || NT_MATCHER_NAME="pve-toolbox-$NT_KIND"
    fi
    ask NT_TARGET_NAME "owned target name" "$NT_TARGET_NAME"
    ask NT_MATCHER_NAME "owned matcher name" "$NT_MATCHER_NAME"
    ask NT_MATCH_SEVERITY "severities (comma separated)" "$NT_MATCH_SEVERITY"
    ask NT_MATCH_FIELD "optional event rule" "$NT_MATCH_FIELD"
    ask NT_MATCH_MODE "matcher mode (all/any)" "$NT_MATCH_MODE"
    if state_exists "$MODULE_NAME"; then
        [[ $NT_TARGET_NAME == "$(state_get "$MODULE_NAME" TARGET_NAME)" \
            && $NT_MATCHER_NAME == "$(state_get "$MODULE_NAME" MATCHER_NAME)" \
            && $(_nt_api_type) == "$(state_get "$MODULE_NAME" TARGET_TYPE)" ]] \
            || die "changing owned object names or target type requires uninstall first"
    fi

    case $NT_KIND in
        discord) ask_secret NT_DISCORD_WEBHOOK "Discord webhook URL" ;;
        webhook)
            ask NT_WEBHOOK_URL "webhook URL or secret template" "$NT_WEBHOOK_URL"
            ask NT_WEBHOOK_METHOD "HTTP method" "$NT_WEBHOOK_METHOD"
            ask NT_WEBHOOK_BODY "body template" "$NT_WEBHOOK_BODY"
            ask NT_WEBHOOK_HEADER_NAME "header name (blank for none)" "$NT_WEBHOOK_HEADER_NAME"
            if [[ -n $NT_WEBHOOK_HEADER_NAME ]]; then
                ask NT_WEBHOOK_HEADER_VALUE "header value" "$NT_WEBHOOK_HEADER_VALUE"
            fi
            ask NT_WEBHOOK_SECRET_NAME "secret template name (blank for none)" "$NT_WEBHOOK_SECRET_NAME"
            if [[ -n $NT_WEBHOOK_SECRET_NAME ]]; then
                ask_secret NT_WEBHOOK_SECRET_VALUE "secret value"
            fi
            ;;
        gotify)
            ask NT_GOTIFY_SERVER "Gotify server URL" "$NT_GOTIFY_SERVER"
            ask_secret NT_GOTIFY_TOKEN "Gotify application token"
            ;;
        smtp)
            ask NT_SMTP_SERVER "SMTP server" "$NT_SMTP_SERVER"
            ask NT_SMTP_PORT "SMTP port" "$NT_SMTP_PORT"
            ask NT_SMTP_MODE "SMTP mode (insecure/starttls/tls)" "$NT_SMTP_MODE"
            ask NT_SMTP_USERNAME "SMTP username (blank for none)" "$NT_SMTP_USERNAME"
            [[ -z $NT_SMTP_USERNAME ]] || ask_secret NT_SMTP_PASSWORD "SMTP password"
            ask NT_SMTP_MAILTO "recipient address" "$NT_SMTP_MAILTO"
            ask NT_SMTP_FROM "from address" "$NT_SMTP_FROM"
            ;;
    esac
    _nt_validate || die "$NT_ERROR"
    _nt_configure
}

module_update() {
    require_root
    local check_only=0
    [[ ${1:-} == --check ]] && check_only=1
    conf_exists "$MODULE_NAME" && state_exists "$MODULE_NAME" || die "not installed"
    _nt_load_conf
    _nt_validate || die "$NT_ERROR"
    if [[ $check_only -eq 1 ]]; then
        if ! _nt_assets_current || ! _nt_exists_endpoint \
            || [[ $(jq -r '.comment // ""' <<<"$NT_JSON") != "$NT_MARKER" ]] \
            || ! _nt_exists_matcher \
            || [[ $(jq -r '.comment // ""' <<<"$NT_JSON") != "$NT_MARKER" ]]; then
            warn "update available: notification assets or owned objects drifted"
        else
            ok "native notification module is up to date"
        fi
        return 0
    fi
    _nt_configure
}

module_status() {
    conf_exists "$MODULE_NAME" && state_exists "$MODULE_NAME" \
        || { printf 'not installed'; return 1; }
    printf '%s target %s' "$(state_get "$MODULE_NAME" TARGET_TYPE)" \
        "$(state_get "$MODULE_NAME" TARGET_NAME)"
}

module_status_long() {
    module_status || return 1
    printf '\n'
    _nt_load_conf
    printf '  matcher     %s\n' "$NT_MATCHER_NAME"
    printf '  severities  %s\n' "$NT_MATCH_SEVERITY"
    printf '  event rule  %s\n' "${NT_MATCH_FIELD:-all events}"
    printf '  credentials configured (values hidden)\n'
    printf '  helper      %s/%s\n' "$TOOLBOX_BIN_DIR" "$NT_HELPER"
}

module_doctor() {
    _nt_load_conf
    if ! _nt_validate; then
        doctor_result fail configuration "native notification configuration is invalid" "$NT_ERROR"
        return 0
    fi
    if ! _nt_exists_endpoint; then
        doctor_result fail target "owned notification target is missing" "$NT_TARGET_NAME"
    elif [[ $(jq -r '.comment // ""' <<<"$NT_JSON") != "$NT_MARKER" ]]; then
        doctor_result fail target "notification target ownership marker changed" "$NT_TARGET_NAME"
    elif [[ $(jq -r '(.disable // 0) | tostring' <<<"$NT_JSON") == 1 ]]; then
        doctor_result warn target "owned notification target is disabled" "$NT_TARGET_NAME"
    else
        doctor_result pass target "owned notification target is enabled" "$NT_TARGET_NAME"
    fi
    if ! _nt_exists_matcher; then
        doctor_result fail matcher "owned notification matcher is missing" "$NT_MATCHER_NAME"
    elif [[ $(jq -r '.comment // ""' <<<"$NT_JSON") != "$NT_MARKER" ]]; then
        doctor_result fail matcher "notification matcher ownership marker changed" "$NT_MATCHER_NAME"
    elif [[ $(jq -r '(.disable // 0) | tostring' <<<"$NT_JSON") == 1 ]]; then
        doctor_result warn matcher "owned notification matcher is disabled" "$NT_MATCHER_NAME"
    else
        doctor_result pass matcher "owned notification matcher is enabled" "$NT_MATCHER_NAME"
    fi
    if _nt_assets_current; then
        doctor_result pass helper "shared native notification helper is current"
    else
        doctor_result warn helper "shared native notification helper or templates drifted"
    fi
}

module_uninstall() {
    require_root
    conf_exists "$MODULE_NAME" && state_exists "$MODULE_NAME" || die "not installed"
    _nt_load_conf
    _nt_owned || die "ownership state does not match configured objects"
    local have_matcher=0 have_endpoint=0
    if _nt_exists_matcher; then
        have_matcher=1
        [[ $(jq -r '.comment // ""' <<<"$NT_JSON") == "$NT_MARKER" ]] \
            || die "matcher ownership marker changed; refusing to remove it"
    fi
    if _nt_exists_endpoint; then
        have_endpoint=1
        [[ $(jq -r '.comment // ""' <<<"$NT_JSON") == "$NT_MARKER" ]] \
            || die "target ownership marker changed; refusing to remove it"
    fi
    if [[ $have_matcher -eq 1 ]]; then
        _nt_remove_matcher || die "could not remove owned matcher"
    fi
    if [[ $have_endpoint -eq 1 ]] && ! _nt_remove_endpoint; then
        if [[ $have_matcher -eq 1 ]]; then _nt_apply_matcher create || true; fi
        die "could not remove owned target; matcher was restored"
    fi
    local template_dir file installed_sum expected_sum
    template_dir=$(_nt_template_dir)
    installed_sum=$(_nt_installed_asset_sum 2>/dev/null || true)
    expected_sum=$(state_get "$MODULE_NAME" ASSET_SUM)
    if [[ -n $installed_sum && $installed_sum == "$expected_sum" ]]; then
        rm -f -- "$TOOLBOX_BIN_DIR/$NT_HELPER"
        for file in "${NT_TEMPLATE_FILES[@]}"; do
            rm -f -- "$template_dir/$file"
        done
    else
        warn "kept modified or incomplete notification helper assets"
    fi
    conf_clear "$MODULE_NAME"
    state_clear "$MODULE_NAME"
    ok "removed only native notification objects owned by this module"
}
