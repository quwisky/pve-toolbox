# shellcheck shell=bash
#
# Read-only PVE web/API certificate and ACME task health.
# shellcheck disable=SC2034
MODULE_NAME="certificate-watch"
MODULE_TITLE="Certificate watch"
MODULE_DESC="read-only cluster TLS expiry, hostname, chain, and ACME renewal health"
MODULE_TAGS="monitoring tls certificate acme notify"
MODULE_HOST_ONLY=1

CW_CONF_KEYS=(CW_WARN_DAYS CW_FAIL_DAYS CW_ACME_STALE_DAYS)
CW_JSON=""
CW_ERROR=""

_cw_defaults() {
    : "${CW_WARN_DAYS:=30}"
    : "${CW_FAIL_DAYS:=7}"
    : "${CW_ACME_STALE_DAYS:=45}"
}

_cw_validate() {
    CW_ERROR=""
    [[ $CW_WARN_DAYS =~ ^[1-9][0-9]*$ && $CW_FAIL_DAYS =~ ^[1-9][0-9]*$ \
        && $CW_FAIL_DAYS -lt $CW_WARN_DAYS ]] \
        || { CW_ERROR="expiry thresholds must satisfy 0 < failure < warning days"; return 1; }
    [[ $CW_ACME_STALE_DAYS =~ ^[1-9][0-9]*$ ]] \
        || { CW_ERROR="ACME stale age must be a positive number of days"; return 1; }
}

_cw_load() {
    _cw_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    _cw_validate
}

_cw_pve_dir() { printf '%s' "${CW_PVE_DIR:-/etc/pve}"; }
_cw_ca_bundle() { printf '%s' "${CW_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"; }

_cw_id() {
    tr '[:upper:]' '[:lower:]' <<<"$1" \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

_cw_array() { # _cw_array <description> <endpoint> [options...]
    local description=$1 endpoint=$2 output
    shift 2
    CW_JSON=""
    if ! output=$(pvesh get "$endpoint" "$@" --output-format json 2>&1); then
        doctor_result warn "api.$(_cw_id "$description")" "could not read $description" "$output"
        return 1
    fi
    if ! jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
        doctor_result warn "api.$(_cw_id "$description")" "$description response was not a JSON array"
        return 1
    fi
    CW_JSON=$output
}

_cw_object() { # _cw_object <description> <endpoint>
    local description=$1 endpoint=$2 output
    CW_JSON=""
    if ! output=$(pvesh get "$endpoint" --output-format json 2>&1); then
        doctor_result warn "api.$(_cw_id "$description")" "could not read $description" "$output"
        return 1
    fi
    if ! jq -e 'type == "object"' <<<"$output" >/dev/null 2>&1; then
        doctor_result warn "api.$(_cw_id "$description")" "$description response was not a JSON object"
        return 1
    fi
    CW_JSON=$output
}

_cw_cert_path() { # _cw_cert_path <node> -> path and source separated by tab
    local base node=$1
    base="$(_cw_pve_dir)/nodes/$node"
    if [[ -r $base/pveproxy-ssl.pem ]]; then
        printf '%s\tcustom' "$base/pveproxy-ssl.pem"
    elif [[ -r $base/pve-ssl.pem ]]; then
        printf '%s\tinternal' "$base/pve-ssl.pem"
    else
        return 1
    fi
}

_cw_split_bundle() { # _cw_split_bundle <bundle> <directory>
    awk -v dir="$2" '
        /-----BEGIN CERTIFICATE-----/ { n++; file=sprintf("%s/cert.%03d.pem", dir, n) }
        n > 0 { print > file }
        END { if (n == 0) exit 1 }
    ' "$1"
}

_cw_expiry_state() { # _cw_expiry_state <not-after-epoch> <now>
    local expiry=$1 now=$2
    if [[ $expiry -le $now ]]; then
        printf 'expired'
    elif [[ $expiry -le $((now + CW_FAIL_DAYS * 86400)) ]]; then
        printf 'fail'
    elif [[ $expiry -le $((now + CW_WARN_DAYS * 86400)) ]]; then
        printf 'warn'
    else
        printf 'pass'
    fi
}

_cw_verify_chain() { # _cw_verify_chain <source> <workdir>
    local source=$1 work=$2 ca untrusted=""
    if find "$work" -maxdepth 1 -name 'cert.*.pem' | grep -q 'cert.002.pem'; then
        untrusted="$work/intermediates.pem"
        find "$work" -maxdepth 1 -name 'cert.*.pem' ! -name 'cert.001.pem' -print0 \
            | sort -z | xargs -0 cat > "$untrusted"
    fi
    if [[ $source == internal ]]; then
        ca="$(_cw_pve_dir)/pve-root-ca.pem"
    else
        ca=$(_cw_ca_bundle)
    fi
    [[ -r $ca ]] || return 64
    if [[ -n $untrusted ]]; then
        openssl verify -CAfile "$ca" -untrusted "$untrusted" "$work/cert.001.pem" >/dev/null 2>&1
    else
        openssl verify -CAfile "$ca" "$work/cert.001.pem" >/dev/null 2>&1
    fi
}

_cw_check_certificate() { # _cw_check_certificate <node>
    local node=$1 resolved path source work leaf end_text expiry now state days
    local issuer subject sans chain_rc host_check
    if ! resolved=$(_cw_cert_path "$node"); then
        doctor_result fail "node.$(_cw_id "$node").certificate" \
            "active PVE certificate file is missing" "node=$node"
        return 0
    fi
    IFS=$'\t' read -r path source <<<"$resolved"
    work=$(mktemp -d)
    if ! _cw_split_bundle "$path" "$work"; then
        rm -rf -- "$work"
        doctor_result fail "node.$(_cw_id "$node").certificate" \
            "certificate bundle contains no PEM certificate" "node=$node path=$path"
        return 0
    fi
    leaf="$work/cert.001.pem"
    if ! end_text=$(openssl x509 -in "$leaf" -noout -enddate 2>/dev/null); then
        rm -rf -- "$work"
        doctor_result fail "node.$(_cw_id "$node").certificate" \
            "active certificate could not be parsed" "node=$node path=$path"
        return 0
    fi
    expiry=$(date -u -d "${end_text#notAfter=}" +%s 2>/dev/null || printf 0)
    now=${CW_NOW_EPOCH:-$(date -u +%s)}
    issuer=$(openssl x509 -in "$leaf" -noout -issuer 2>/dev/null | sed 's/^issuer=//')
    subject=$(openssl x509 -in "$leaf" -noout -subject 2>/dev/null | sed 's/^subject=//')
    sans=$(openssl x509 -in "$leaf" -noout -ext subjectAltName 2>/dev/null \
        | tail -n +2 | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' || true)
    if [[ $expiry -le 0 ]]; then
        doctor_result fail "node.$(_cw_id "$node").expiry" \
            "certificate expiry could not be parsed" "node=$node notAfter=${end_text#notAfter=}"
    else
        state=$(_cw_expiry_state "$expiry" "$now")
        days=$(((expiry - now) / 86400))
        case $state in
            expired) doctor_result fail "node.$(_cw_id "$node").expiry" \
                "certificate expired $((-days)) day(s) ago" "node=$node expiry_epoch=$expiry UTC" ;;
            fail) doctor_result fail "node.$(_cw_id "$node").expiry" \
                "certificate expires in $days day(s)" "node=$node expiry_epoch=$expiry UTC fail_at=${CW_FAIL_DAYS}d" ;;
            warn) doctor_result warn "node.$(_cw_id "$node").expiry" \
                "certificate expires in $days day(s)" "node=$node expiry_epoch=$expiry UTC warn_at=${CW_WARN_DAYS}d" ;;
            pass) doctor_result pass "node.$(_cw_id "$node").expiry" \
                "certificate expires in $days day(s)" "node=$node expiry_epoch=$expiry UTC" ;;
        esac
    fi
    # Some OpenSSL builds return success when -checkhost parsed the certificate
    # even though its result text says the hostname does not match. Require the
    # unambiguous positive result rather than trusting that inconsistent status.
    host_check=$(openssl x509 -in "$leaf" -noout -checkhost "$node" 2>&1 || true)
    if [[ $host_check == *"does match certificate"* \
        && $host_check != *"does NOT match certificate"* ]]; then
        doctor_result pass "node.$(_cw_id "$node").hostname" \
            "certificate covers node hostname" "node=$node SAN=$sans"
    else
        doctor_result fail "node.$(_cw_id "$node").hostname" \
            "certificate does not cover node hostname" "node=$node SAN=$sans"
    fi
    chain_rc=0
    _cw_verify_chain "$source" "$work" || chain_rc=$?
    case $chain_rc in
        0) doctor_result pass "node.$(_cw_id "$node").chain" \
            "certificate chain validates" "node=$node source=$source issuer=$issuer subject=$subject" ;;
        64) doctor_result unsupported "node.$(_cw_id "$node").chain" \
            "certificate trust anchor is unavailable" "node=$node source=$source" ;;
        *) doctor_result fail "node.$(_cw_id "$node").chain" \
            "certificate chain validation failed" "node=$node source=$source issuer=$issuer subject=$subject" ;;
    esac
    rm -rf -- "$work"
}

_cw_acme_configured() { # _cw_acme_configured <node-config-json>
    jq -e '((.acme // "") | tostring | length) > 0
        or any(to_entries[]; (.key | startswith("acmedomain")) and ((.value | tostring | length) > 0))' \
        <<<"$1" >/dev/null
}

_cw_check_acme() { # _cw_check_acme <node> <node-config-json> <tasks-json-or-empty>
    local node=$1 config=$2 tasks=$3 stats now cutoff latest_success latest_failure age
    if ! _cw_acme_configured "$config"; then
        doctor_result skipped "node.$(_cw_id "$node").acme" "ACME is not configured for node"
        return 0
    fi
    if [[ -z $tasks ]]; then
        doctor_result warn "node.$(_cw_id "$node").acme" \
            "ACME task history is unavailable" "node=$node"
        return 0
    fi
    now=${CW_NOW_EPOCH:-$(date -u +%s)}
    cutoff=$((now - CW_ACME_STALE_DAYS * 86400))
    stats=$(jq -cn --argjson tasks "$tasks" --arg node "$node" '
        [ $tasks[] | select(.node == $node and (.type == "acmerenew" or .type == "acmenewcert")) ] as $all
        | {
            latest_success: ([ $all[] | select(.status == "OK") | (.endtime // .starttime // 0) ] | max // 0),
            latest_failure: ([ $all[] | select((.status // "") != "" and .status != "OK")
                               | (.endtime // .starttime // 0) ] | max // 0)
          }
    ')
    latest_success=$(jq -r '.latest_success' <<<"$stats")
    latest_failure=$(jq -r '.latest_failure' <<<"$stats")
    if [[ $latest_failure -gt $latest_success ]]; then
        doctor_result fail "node.$(_cw_id "$node").acme" \
            "latest ACME certificate task failed" \
            "node=$node failure_epoch=$latest_failure last_success_epoch=$latest_success"
    elif [[ $latest_success -le 0 ]]; then
        doctor_result warn "node.$(_cw_id "$node").acme" \
            "ACME is configured but no successful certificate task was found" "node=$node"
    elif [[ $latest_success -lt $cutoff ]]; then
        age=$(((now - latest_success) / 86400))
        doctor_result warn "node.$(_cw_id "$node").acme" \
            "last successful ACME task is ${age} days old" \
            "node=$node success_epoch=$latest_success stale_at=${CW_ACME_STALE_DAYS}d"
    else
        age=$(((now - latest_success) / 86400))
        doctor_result pass "node.$(_cw_id "$node").acme" \
            "last successful ACME task is ${age} days old" "node=$node success_epoch=$latest_success"
    fi
}

_cw_audit() {
    local nodes tasks="" node config
    if ! command -v pvesh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 \
        || ! command -v openssl >/dev/null 2>&1; then
        doctor_result unsupported prerequisites "pvesh, jq, and openssl are required"
        return 0
    fi
    if ! _cw_load; then
        doctor_result fail configuration "certificate watch thresholds are invalid" "$CW_ERROR"
        return 0
    fi
    _cw_array "cluster node inventory" /nodes || return 0
    nodes=$CW_JSON
    if ! pve_collect_node_tasks "$nodes" --limit 200; then
        doctor_result fail api.acme-task-history "could not read ACME task history" \
            "$PVE_TASKS_ERROR"
        return 0
    fi
    tasks=$PVE_TASKS_JSON
    while IFS= read -r node; do
        if _cw_object "node $node reachability" "/nodes/$node/status"; then
            doctor_result pass "node.$(_cw_id "$node").reachability" "node API is reachable"
        else
            doctor_result warn "node.$(_cw_id "$node").reachability" \
                "node API is unreachable; inspecting replicated certificate files" "node=$node"
        fi
        _cw_check_certificate "$node"
        if _cw_object "node $node ACME config" "/nodes/$node/config"; then
            config=$CW_JSON
            _cw_check_acme "$node" "$config" "$tasks"
        else
            doctor_result warn "node.$(_cw_id "$node").acme" \
                "ACME configuration could not be inspected" "node=$node"
        fi
    done < <(jq -r '.[].node' <<<"$nodes")
    if command -v pve-toolbox-native-notify >/dev/null 2>&1; then
        doctor_result pass notification "native notification helper is available for certificate alerts"
    else
        doctor_result skipped notification "native notification helper is not installed"
    fi
}

module_install() {
    require_root
    require_pve
    _cw_defaults
    if conf_exists "$MODULE_NAME"; then conf_load "$MODULE_NAME"; fi
    pkg_ensure jq:jq openssl:openssl
    ask CW_WARN_DAYS "certificate warning threshold (days)" "$CW_WARN_DAYS"
    ask CW_FAIL_DAYS "certificate failure threshold (days)" "$CW_FAIL_DAYS"
    ask CW_ACME_STALE_DAYS "ACME task stale threshold (days)" "$CW_ACME_STALE_DAYS"
    _cw_validate || die "$CW_ERROR"
    local key
    for key in "${CW_CONF_KEYS[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    state_set "$MODULE_NAME" INSTALLED_AT "$(date -Is)"
    ok "configured read-only certificate watch"
}

module_update() {
    local check_only=0 key missing=()
    [[ ${1:-} == --check ]] && check_only=1
    conf_exists "$MODULE_NAME" || die "not installed"
    _cw_defaults
    for key in "${CW_CONF_KEYS[@]}"; do
        [[ -n $(conf_get "$MODULE_NAME" "$key") ]] || missing+=("$key")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then ok "certificate watch configuration is up to date"; return 0; fi
    if [[ $check_only -eq 1 ]]; then warn "update available: missing settings ${missing[*]}"; return 0; fi
    for key in "${missing[@]}"; do conf_set "$MODULE_NAME" "$key" "${!key}"; done
    ok "added missing certificate watch settings"
}

module_status() {
    conf_exists "$MODULE_NAME" || { printf 'not installed'; return 1; }
    printf 'configured, read-only'
}

module_status_long() {
    module_status || return 1
    printf '\n'
    if _cw_load; then
        printf '  expiry  warn %sd, fail %sd\n' "$CW_WARN_DAYS" "$CW_FAIL_DAYS"
        printf '  ACME    stale after %sd\n' "$CW_ACME_STALE_DAYS"
        printf '  renewal never triggered\n'
    else
        printf '  configuration invalid\n'
        return 1
    fi
}

module_doctor() { _cw_audit; }

module_uninstall() {
    require_root
    conf_clear "$MODULE_NAME"
    state_clear "$MODULE_NAME"
    ok "removed certificate watch configuration; no certificate was changed"
}
