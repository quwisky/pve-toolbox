#!/usr/bin/env bash
# Runs inside the selected LXC. No production path-redirection overrides.
set -Eeuo pipefail
export LC_ALL=C
KG_STORE=/var/lib/pve-toolbox/komodo-periphery
KG_UNIT=periphery.service
KG_REASON="" KG_LAYOUT=unsupported KG_VERSION="" KG_BINARY="" KG_UNIT_PATH=""
KG_CONFIGS=() KG_FILES=() KG_WORDS=()
KG_ACTIVE=unknown KG_ENABLED=unknown KG_USER=root KG_FINGERPRINT="" KG_MACHINE=""
KG_TRANSACTION=none
KG_DIAGNOSTICS=null
KG_CONFIG_FINGERPRINT=""
kg_fail() { KG_REASON=$1; return 1; }
kg_safe_path() { # Absolute canonical path, root-owned and not writable by others.
    local path=$1 mode
    [[ ! $path =~ [[:cntrl:]] ]] || return 1
    [[ $path == /* && $path != *$'\n'* && $path != *$'\r'* && $path != *'/../'* && $path != *'/./'* && $path != *'//'* && $path != */ && $path != / ]] || return 1
    [[ $(realpath -m -- "$path") == "$path" ]] || return 1
    while [[ $path != / ]]; do
        [[ ! -L $path ]] || return 1
        if [[ -e $path ]]; then
            [[ $(stat -c %u -- "$path") == 0 ]] || return 1
            mode=$(stat -c %a -- "$path") || return 1
            (( (8#$mode & 0022) == 0 )) || return 1
        fi
        path=${path%/*}; [[ -n $path ]] || path=/
    done
}
kg_regular() { [[ -f $1 && ! -L $1 ]] && kg_safe_path "$1"; }
kg_hash() { local value; value=$(sha256sum -- "$1") || return 1; printf '%s' "${value%% *}"; }
kg_prop() { sed -n "s/^$1=//p" <<<"$KG_SHOW"; }
kg_words() { # Restricted systemd command lexer. Never evaluate shell text.
    local text=$1 c quote="" word="" escape=0 present=0 i
    KG_WORDS=()
    for ((i=0; i<${#text}; i++)); do
        c=${text:i:1}
        [[ $c != ['$`%;|&<>()'] && $c != $'\n' && $c != $'\r' ]] || return 1
        if ((escape)); then
            # Deliberately exclude C/hex/octal escape interpretation.
            [[ $c == ['\"'\'\ ] ]] || return 1
            word+=$c; escape=0; present=1
        elif [[ $c == '\' ]]; then escape=1
        elif [[ -n $quote ]]; then
            if [[ $c == "$quote" ]]; then quote=""; else word+=$c; fi
            present=1
        elif [[ $c == '"' || $c == "'" ]]; then quote=$c; present=1
        elif [[ $c == ' ' || $c == $'\t' ]]; then
            if ((present)); then KG_WORDS+=("$word"); word=""; present=0; fi
        else word+=$c; present=1
        fi
    done
    [[ -z $quote && $escape == 0 ]] || return 1
    if ((present)); then KG_WORDS+=("$word"); fi
    ((${#KG_WORDS[@]} > 0))
}
kg_inspect_inner() {
    local cmd os arch raw="" file line section="" count=0 drop version type exec_path config effective_args
    for cmd in jq stat sha256sum dirname readlink realpath cat mkdir chmod cp mv rm mktemp sync flock timeout sleep sort date find head tr cmp env sed systemctl dpkg-query uname; do
        command -v "$cmd" >/dev/null || { kg_fail "missing guest prerequisite: $cmd"; return 1; }
    done
    [[ $EUID == 0 && -d /run/systemd/system ]] || { kg_fail 'guest root and systemd required'; return 1; }
    # Do not source guest-supplied shell configuration to inspect its OS.
    os=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
    version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
    arch=$(uname -m)
    [[ $os == debian && $version == 13 && $arch == x86_64 ]] || { kg_fail 'requires Debian 13 amd64 guest'; return 1; }
    IFS= read -r KG_MACHINE < /etc/machine-id
    [[ $KG_MACHINE =~ ^[0-9a-f]{32}$ && $KG_MACHINE != 00000000000000000000000000000000 ]] || { kg_fail 'invalid guest machine-id'; return 1; }
    KG_SHOW=$(systemctl show "$KG_UNIT" --no-pager --property=LoadState,FragmentPath,DropInPaths,User,Type,EnvironmentFiles,Environment,ActiveState,UnitFileState,MainPID,NRestarts,ExecStart,NeedDaemonReload) || { kg_fail 'cannot inspect systemd service'; return 1; }
    if [[ $(kg_prop LoadState) == not-found ]]; then
        [[ ! -e /usr/local/bin/periphery && ! -L /usr/local/bin/periphery && ! -e /etc/systemd/system/periphery.service && ! -L /etc/systemd/system/periphery.service ]] || { kg_fail 'unmanaged files without service'; return 1; }
        KG_LAYOUT=absent; KG_FINGERPRINT=absent
        return 0
    fi
    [[ $(kg_prop LoadState) == loaded ]] || { kg_fail 'service is masked or not loaded'; return 1; }
    [[ $(kg_prop NeedDaemonReload) == no ]] || { kg_fail 'unit files differ from the loaded service; daemon-reload required'; return 1; }
    KG_UNIT_PATH=$(kg_prop FragmentPath)
    [[ $KG_UNIT_PATH == /etc/systemd/system/periphery.service ]] || { kg_fail 'only local system periphery.service is supported'; return 1; }
    KG_ACTIVE=$(kg_prop ActiveState); KG_ENABLED=$(kg_prop UnitFileState)
    [[ $KG_ACTIVE == active || $KG_ACTIVE == inactive || $KG_ACTIVE == failed ]] || { kg_fail 'service is transitioning'; return 1; }
    [[ $KG_ENABLED == enabled || $KG_ENABLED == disabled ]] || { kg_fail 'unsupported service enablement state'; return 1; }
    type=$(kg_prop Type)
    [[ $type == simple || $type == exec ]] || { kg_fail 'unsupported service type'; return 1; }
    [[ -z $(kg_prop EnvironmentFiles) ]] || { kg_fail 'EnvironmentFile service requires manual review'; return 1; }
    [[ $(kg_prop Environment) != *PERIPHERY_* ]] || { kg_fail 'environment overrides require manual review'; return 1; }
    KG_USER=$(kg_prop User); KG_USER=${KG_USER:-root}
    KG_FILES=("$KG_UNIT_PATH")
    drop=$(kg_prop DropInPaths)
    # systemd path lists with escaped whitespace cannot be resolved safely here.
    [[ $drop != *'\'* ]] || { kg_fail 'ambiguous drop-in paths'; return 1; }
    for file in $drop; do KG_FILES+=("$file"); done # Intentional systemd path-list splitting.
    for file in "${KG_FILES[@]}"; do
        kg_regular "$file" || { kg_fail 'unsafe service file'; return 1; }
        section=""
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line != *'\' ]] || { kg_fail 'continued unit lines require manual review'; return 1; }
            line="${line#"${line%%[![:space:]]*}"}"
            case $line in
                \[*\]) section=$line ;;
                ExecStart=*)
                    [[ $section == '[Service]' ]] || continue
                    raw=${line#ExecStart=}
                    if [[ -z $raw ]]; then count=0; else count=$((count+1)); fi ;;
            esac
        done < "$file"
    done
    [[ $count == 1 ]] && kg_words "$raw" || { kg_fail 'ambiguous service command'; return 1; }
    exec_path=${KG_WORDS[0]}
    effective_args=$(IFS=' '; printf '%s' "${KG_WORDS[*]}")
    if [[ $exec_path == /bin/sh && ${KG_WORDS[1]:-} == -lc && ${#KG_WORDS[@]} == 3 ]]; then
        kg_words "${KG_WORDS[2]}" || { kg_fail 'unsupported shell wrapper'; return 1; }
    fi
    KG_BINARY=${KG_WORDS[0]}
    [[ ${#KG_WORDS[@]} -ge 3 ]] && (( ${#KG_WORDS[@]} % 2 == 1 )) || { kg_fail 'explicit configuration paths required'; return 1; }
    [[ $(kg_prop ExecStart) == "{ path=$exec_path ; argv[]=$effective_args ; ignore_errors=no ;"* ]] || { kg_fail 'effective command differs from unit; daemon-reload required'; return 1; }
    for ((count=1; count<${#KG_WORDS[@]}; count+=2)); do
        [[ ${KG_WORDS[count]} == --config-path || ${KG_WORDS[count]} == -c ]] || { kg_fail 'unsupported command arguments'; return 1; }
        config=${KG_WORDS[count+1]}
        kg_regular "$config" || { kg_fail 'unsafe or missing configuration file'; return 1; }
        KG_CONFIGS+=("$config")
    done
    kg_regular "$KG_BINARY" && [[ -x $KG_BINARY ]] || { kg_fail 'unsafe executable path'; return 1; }
    if dpkg-query -S "$KG_BINARY" >/dev/null 2>&1; then kg_fail 'package-owned binary requires package-manager update'; return 1; fi
    version=$(timeout 5 "$KG_BINARY" --version 2>/dev/null | head -c 128) || { kg_fail 'could not read agent version'; return 1; }
    [[ $version =~ ^periphery[[:space:]]+v?(2\.[0-9]+\.[0-9]+)$ ]] || { kg_fail 'only stable Periphery v2 installations are supported'; return 1; }
    KG_VERSION=${BASH_REMATCH[1]}
    KG_CONFIG_FINGERPRINT=$(sha256sum -- "${KG_CONFIGS[@]}" | sha256sum | cut -d ' ' -f1) || { kg_fail 'cannot fingerprint configuration'; return 1; }
    KG_FINGERPRINT=$({ printf '%s\n' "$KG_BINARY" "$KG_USER" "$type" "$raw"; sha256sum -- "$KG_BINARY" "${KG_FILES[@]}"; } | sha256sum | cut -d ' ' -f1)
    KG_LAYOUT=supported
}
kg_inspect() {
    KG_REASON="" KG_LAYOUT=unsupported KG_CONFIGS=() KG_FILES=()
    KG_VERSION="" KG_BINARY="" KG_UNIT_PATH="" KG_FINGERPRINT="" KG_CONFIG_FINGERPRINT="" KG_ACTIVE=unknown KG_ENABLED=unknown
    kg_inspect_inner || true
    local record="" transaction_id="" last_action="" owned=false retained=false
    if [[ -f $KG_STORE/owner.json && ! -L $KG_STORE/owner.json ]]; then owned=true; fi
    if [[ -f $KG_STORE/retained.json && ! -L $KG_STORE/retained.json ]]; then retained=true; fi
    if [[ -e $KG_STORE/pending.json ]]; then KG_TRANSACTION=pending
    elif [[ -f $KG_STORE/committed.json ]]; then KG_TRANSACTION=committed; fi
    case $KG_TRANSACTION in pending) record=$KG_STORE/pending.json ;; committed) record=$KG_STORE/committed.json ;; esac
    if [[ -n $record ]] && kg_regular "$record"; then
        transaction_id=$(jq -r '.transaction_id // ""' "$record")
        last_action=$(jq -r '.action // ""' "$record")
    fi
    jq -nc --arg id "$transaction_id" --arg action "$last_action" --argjson owned "$owned" --argjson retained "$retained" --arg layout "$KG_LAYOUT" --arg reason "$KG_REASON" --arg machine_id "$KG_MACHINE" \
        --arg version "$KG_VERSION" --arg binary "$KG_BINARY" --arg unit "$KG_UNIT_PATH" \
        --arg user "$KG_USER" --arg active "$KG_ACTIVE" --arg enabled "$KG_ENABLED" \
        --arg fingerprint "$KG_FINGERPRINT" --arg config_fingerprint "$KG_CONFIG_FINGERPRINT" --arg transaction "$KG_TRANSACTION" \
        --argjson configs "$(printf '%s\n' "${KG_CONFIGS[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')" \
        '{schema:1,transaction_id:$id,last_action:$action,owned:$owned,retained:$retained,layout:$layout,reason:$reason,machine_id:$machine_id,os_id:"debian",os_version:"13",arch:"amd64",
          version:$version,binary:$binary,unit:$unit,config_paths:$configs,service_user:$user,
          active:$active,enabled:$enabled,masked:false,fingerprint:$fingerprint,config_fingerprint:$config_fingerprint,transaction:$transaction}'
}

kg_atomic() { # <protected JSON path>, data on stdin
    local path=$1 tmp
    kg_safe_path "$path" || return 1
    [[ ! -e $path || -f $path ]] || return 1
    tmp=$(mktemp "${path%/*}/.record.XXXXXXXX") || return 1
    chmod 0600 "$tmp" && cat > "$tmp" && sync -f "$tmp" && mv -fT -- "$tmp" "$path" && sync -f "${path%/*}" || { rm -f -- "$tmp"; return 1; }
}
kg_store() {
    kg_safe_path "$KG_STORE" || return 1
    mkdir -p -- "$KG_STORE" && chmod 0700 "$KG_STORE" || return 1
    kg_safe_path "$KG_STORE/lock" || return 1
    [[ ! -e $KG_STORE/lock || -f $KG_STORE/lock ]] || return 1
    exec {KG_LOCK}>"$KG_STORE/lock"
    flock -n "$KG_LOCK" || { kg_fail 'another guest transaction is active'; return 1; }
}
kg_version() {
    local text
    text=$(timeout 5 "$1" --version 2>/dev/null | head -c 128) || return 1
    [[ $text =~ ^periphery[[:space:]]+v?(2\.[0-9]+\.[0-9]+)$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}
kg_agent_pid() { # <MainPID> <binary>; known upstream shell wrapper or direct agent
    local pid=$1 binary=$2 child children found="" exe
    exe=$(readlink -- "/proc/$pid/exe") || return 1
    if [[ $exe == "$binary" ]]; then printf '%s' "$pid"; return 0; fi
    [[ $exe == "$(readlink -f /bin/sh)" ]] || return 1
    children=$(cat "/proc/$pid/task/$pid/children") || return 1
    for child in $children; do # Kernel format: whitespace-separated numeric PIDs.
        [[ $child =~ ^[1-9][0-9]*$ ]] || return 1
        if [[ $(readlink -- "/proc/$child/exe") == "$binary" ]]; then
            [[ -z $found && $(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$child/status") == "$pid" ]] || return 1
            found=$child
        fi
    done
    [[ -n $found ]] || return 1
    printf '%s' "$found"
}
kg_service_health() { # expected binary
    local i props pid restarts agent previous=""
    for ((i=0;i<10;i++)); do
        props=$(systemctl show "$KG_UNIT" --property=ActiveState,MainPID,NRestarts) || return 1
        [[ $props == *'ActiveState=active'* ]] || return 1
        pid=$(sed -n 's/^MainPID=//p' <<<"$props")
        restarts=$(sed -n 's/^NRestarts=//p' <<<"$props")
        [[ $pid =~ ^[1-9][0-9]*$ && $restarts =~ ^[0-9]+$ ]] || return 1
        agent=$(kg_agent_pid "$pid" "$1") || return 1
        [[ -z $previous || $previous == "$pid:$agent:$restarts" ]] || return 1
        previous=$pid:$agent:$restarts
        sleep 1
    done
}
kg_startup_diagnostics() { # <start time> <start output>; before rollback changes it
    local since=$1 start_output=$2 status journal
    status=$(timeout 5 systemctl show "$KG_UNIT" --no-pager \
        --property=ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,NRestarts \
        2>/dev/null | head -c 1024) || status='service status unavailable'
    journal=$(timeout 5 journalctl -u "$KG_UNIT" --since "@$since" -n 20 \
        --no-pager --output=json --output-fields=MESSAGE 2>/dev/null | head -c 8192) || journal=''
    # Refuse partial JSON if a very large journal entry exceeds the byte limit.
    journal=$(printf '%s' "$journal" | jq -cs '[.[] | .MESSAGE | select(type=="string")]
        | if length == 0 then ["startup journal unavailable or empty"] else . end' 2>/dev/null) \
        || journal='["startup journal unavailable or exceeds the diagnostic limit"]'
    # Journal text may contain credentials: keep it on stdin, never in argv.
    KG_DIAGNOSTICS=$({ printf '%s' "$start_output" | jq -Rs .; printf '%s' "$journal"; } \
        | jq -cs --arg service "$status" '{service:$service,journal:([.[0]] + .[1] | map(select(length>0)))}') \
        || KG_DIAGNOSTICS=null
}
kg_toml() { # Validated strings; output one TOML string literal.
    local value=$1
    value=${value//\\/\\\\}; value=${value//\"/\\\"}
    printf '"%s"' "$value"
}
kg_prepare_configuration() { # <TOML path>; edit a staged copy, verify all other values.
    local config=$1
    command -v python3 >/dev/null && python3 -c 'import tomllib' >/dev/null 2>&1 || { kg_fail 'configuration editing requires Python 3.11 or newer in the guest'; return 1; }
    kg_regular "$config" && [[ $config == *.toml && $(stat -c %s "$config") -le 1048576 ]] || { kg_fail 'configuration editing requires one protected TOML file up to 1 MiB'; return 1; }
    KG_CONFIG_STAGED=$(mktemp "${config%/*}/.periphery-config.XXXXXXXX") || return 1
    if ! python3 - "$config" "$KG_REQUEST" "$KG_CONFIG_STAGED" <<'PY'
import json
import re
import sys

def trailing_comment(line):
    # Locate a comment outside TOML basic/literal strings, including # in values.
    index, delimiter = 0, None
    while index < len(line):
        if delimiter:
            if delimiter.startswith('"') and line[index] == "\\":
                index += 2
            elif line.startswith(delimiter, index):
                index += len(delimiter)
                delimiter = None
            else:
                index += 1
        elif line[index] in "\"'":
            delimiter = line[index] * (3 if line.startswith(line[index] * 3, index) else 1)
            index += len(delimiter)
        elif line[index] == "#":
            while index > 0 and line[index - 1] in " \t":
                index -= 1
            return line[index:].rstrip("\r\n")
        else:
            index += 1
    return ""

try:
    import tomllib

    with open(sys.argv[1], encoding="utf-8", newline="") as stream:
        source = stream.read()
    with open(sys.argv[2], encoding="utf-8") as stream:
        request = json.load(stream)
    original = tomllib.loads(source)
    expected = original.copy()
    edits = {}
    for source_key, config_key in (("core_url", "core_address"), ("server_name", "connect_as")):
        if request[source_key]:
            edits[config_key] = request[source_key]
    if request["onboarding_key_action"] == "replace":
        edits["onboarding_key"] = request["onboarding_key"]
    elif request["onboarding_key_action"] == "remove":
        edits["onboarding_key"] = None
    for key, value in edits.items():
        if value is None:
            expected.pop(key, None)
        else:
            expected[key] = value
        if original.get(key) == value:
            continue
        replacement = "" if value is None else f"{key} = {json.dumps(value)}\n"
        if key in original:
            pattern = re.compile(r"^[ \t]*(?:" + key + r"|\"" + key + r"\"|'" + key + r"')[ \t]*=.*(?:\n|$)", re.MULTILINE)
            def replace_assignment(match):
                line = match.group()
                comment = trailing_comment(line)
                ending = "\r\n" if line.endswith("\r\n") else "\n" if line.endswith("\n") else ""
                indent = re.match(r"[ \t]*", line).group()
                if value is None:
                    return indent + comment + ending if comment else ""
                return indent + replacement.rstrip("\n") + comment + ending
            source, count = pattern.subn(replace_assignment, source)
            if count != 1:
                raise ValueError("ambiguous assignment")
        elif value is not None:
            source = replacement + source
    # Reject multiline/ambiguous assignments instead of altering other settings.
    if tomllib.loads(source) != expected:
        raise ValueError("unrelated configuration changed")
    with open(sys.argv[3], "w", encoding="utf-8", newline="") as stream:
        stream.write(source)
except Exception:
    # Parser exceptions can include secrets from the configuration source.
    sys.exit(1)
PY
    then kg_fail 'cannot safely edit configuration; requires valid TOML and unambiguous single-line connection settings'; return 1; fi
    chown --reference="$config" "$KG_CONFIG_STAGED" && chmod --reference="$config" "$KG_CONFIG_STAGED" && sync -f "$KG_CONFIG_STAGED" || return 1
}
kg_request() {
    KG_REQUEST=$1
    kg_regular "$KG_REQUEST" && [[ $(stat -c %a "$KG_REQUEST") == 600 && $(stat -c %s "$KG_REQUEST") -le 65536 ]] || { kg_fail 'unsafe request file'; return 1; }
    KG_REQUEST_JSON=$(cat -- "$KG_REQUEST") || return 1
    jq -e 'type=="object" and .schema==1 and
      (.action=="install" or .action=="update" or .action=="uninstall" or .action=="configure") and
      (.transaction_id | type=="string" and test("^[a-f0-9]{32}$")) and
      (.machine_id | type=="string" and test("^[a-f0-9]{32}$")) and
      (.expected_fingerprint | type=="string" and (.=="absent" or test("^[a-f0-9]{64}$"))) and
      (.adopt | type=="boolean") and
      (.version | type=="string" and test("^2\\.[0-9]+\\.[0-9]+$")) and
      (.asset_sha256 | type=="string" and test("^[a-f0-9]{64}$")) and
      (.staged_binary | type=="string")' <<<"$KG_REQUEST_JSON" >/dev/null 2>&1 || { kg_fail 'invalid request'; return 1; }
    KG_ID=$(jq -r .transaction_id <<<"$KG_REQUEST_JSON")
    [[ $KG_REQUEST == "/run/pve-toolbox-komodo-$KG_ID/request.json" && $(jq -r .staged_binary <<<"$KG_REQUEST_JSON") == "/run/pve-toolbox-komodo-$KG_ID/periphery" ]] || { kg_fail 'invalid staging paths'; return 1; }
    KG_ACTION=$(jq -r .action <<<"$KG_REQUEST_JSON")
    KG_DESIRED=$(jq -r .version <<<"$KG_REQUEST_JSON")
    if [[ $KG_ACTION == configure ]]; then
        jq -e '(.config_fingerprint | type=="string" and test("^[a-f0-9]{64}$")) and
            all(.core_url,.server_name,.onboarding_key; type=="string" and (explode|all(.>=32 and .!=127))) and
            (.core_url=="" or (.core_url|test("^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[^\\s?#]*)?$") and (contains("@")|not))) and
            (.onboarding_key_action=="keep" or .onboarding_key_action=="remove" or
                (.onboarding_key_action=="replace" and (.onboarding_key|length>0)))' <<<"$KG_REQUEST_JSON" >/dev/null 2>&1 || { kg_fail 'invalid configuration update'; return 1; }
    fi
}
kg_backup() { # <file> <backup leaf>
    if [[ -e $1 ]]; then
        kg_regular "$1" || return 1
        cp -a -- "$1" "$KG_STORE/transaction/$2" && sync -f "$KG_STORE/transaction/$2"
    else
        kg_safe_path "$1"
    fi
}
kg_mark() {
    jq --arg phase "$1" '.phase=$phase' "$KG_STORE/pending.json" | kg_atomic "$KG_STORE/pending.json"
}
kg_restore() {
    local record binary unit active enabled path leaf expected tmp loaded
    kg_regular "$KG_STORE/pending.json" || return 1
    record=$(cat "$KG_STORE/pending.json")
    [[ $(jq -r .machine_id <<<"$record") == "$KG_MACHINE" ]] || return 1
    binary=$(jq -r .binary <<<"$record"); unit=$(jq -r .unit <<<"$record")
    [[ $unit == /etc/systemd/system/periphery.service ]] || return 1
    kg_safe_path "$binary" && kg_safe_path "$unit" || return 1
    for leaf in binary unit config owner; do
        case $leaf in
            owner) path=$KG_STORE/owner.json ;;
            binary) path=$binary ;;
            unit) path=$unit ;;
            config) [[ $(jq -r .config_changed <<<"$record") == true ]] || continue
                    path=$(jq -r '.config_path // "/etc/komodo/periphery.config.toml"' <<<"$record") ;;
        esac
        kg_safe_path "$path" || return 1
        [[ ! -e $path || -f $path ]] || return 1
        expected=$(jq -r --arg leaf "$leaf" '.backups[$leaf] // ""' <<<"$record")
        if [[ $expected =~ ^[a-f0-9]{64}$ ]]; then
            kg_regular "$KG_STORE/transaction/$leaf" || return 1
            [[ $(kg_hash "$KG_STORE/transaction/$leaf") == "$expected" ]] || return 1
        elif [[ -z $expected ]]; then
            [[ ! -e $KG_STORE/transaction/$leaf && ! -L $KG_STORE/transaction/$leaf ]] || return 1
        else return 1; fi
    done
    kg_mark restoring || return 1
    loaded=$(systemctl show "$KG_UNIT" --property=LoadState) || return 1
    if [[ $loaded == *'LoadState=not-found'* && ! -e $unit && $(jq -r '.backups.unit // ""' <<<"$record") == "" ]]; then
        : # Fresh install failed before its service existed; nothing can be stopped.
    else
        systemctl stop "$KG_UNIT" >/dev/null 2>&1 || return 1
        if [[ $(jq -r '.backups.unit // ""' <<<"$record") == "" ]]; then
            systemctl disable "$KG_UNIT" >/dev/null 2>&1 || return 1
        fi
    fi
    for leaf in binary unit config owner; do
        case $leaf in
            owner) path=$KG_STORE/owner.json ;;
            binary) path=$binary ;;
            unit) path=$unit ;;
            config) [[ $(jq -r .config_changed <<<"$record") == true ]] || continue
                    path=$(jq -r '.config_path // "/etc/komodo/periphery.config.toml"' <<<"$record") ;;
        esac
        if [[ -f $KG_STORE/transaction/$leaf ]]; then
            tmp=$(mktemp "${path%/*}/.restore.XXXXXXXX") || return 1
            cp -a -- "$KG_STORE/transaction/$leaf" "$tmp" && sync -f "$tmp" && mv -fT -- "$tmp" "$path" && sync -f "${path%/*}" || { rm -f -- "$tmp"; return 1; }
        else
            rm -f -- "$path" || return 1
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    active=$(jq -r .active <<<"$record"); enabled=$(jq -r .enabled <<<"$record")
    if [[ -f $unit ]]; then
        if [[ $enabled == enabled ]]; then systemctl enable "$KG_UNIT" >/dev/null 2>&1 || return 1
        else systemctl disable "$KG_UNIT" >/dev/null 2>&1 || return 1; fi
        if [[ $active == active ]]; then
            systemctl start "$KG_UNIT" >/dev/null 2>&1 && kg_service_health "$binary" || return 1
        fi
    fi
    kg_mark restored && mv -fT "$KG_STORE/pending.json" "$KG_STORE/last-failure.json" && sync -f "$KG_STORE" || return 1
}
kg_apply() {
    local inspected expected binary unit candidate digest old_version config_changed=false reuse=false backups oldhash="" startup_since start_output
    local config_path=/etc/komodo/periphery.config.toml
    kg_request "$1" && kg_store || return 1
    [[ ! -e $KG_STORE/pending.json ]] || { kg_fail 'pending transaction requires recovery'; return 1; }
    inspected=$(kg_inspect)
    KG_MACHINE=$(jq -r .machine_id <<<"$inspected")
    [[ $KG_MACHINE == "$(jq -r .machine_id <<<"$KG_REQUEST_JSON")" ]] || { kg_fail 'guest identity changed'; return 1; }
    expected=$(jq -r .expected_fingerprint <<<"$KG_REQUEST_JSON")
    [[ $(jq -r .fingerprint <<<"$inspected") == "$expected" ]] || { kg_fail 'installation changed since preview'; return 1; }
    [[ $(jq -r .layout <<<"$inspected") != unsupported ]] || { kg_fail 'unsupported installation'; return 1; }
    if [[ $expected == absent ]]; then
        [[ $KG_ACTION == install ]] || { kg_fail 'agent is not installed'; return 1; }
        binary=/usr/local/bin/periphery; unit=/etc/systemd/system/periphery.service
        if [[ -e /etc/komodo/periphery.config.toml ]]; then
            kg_regular "$KG_STORE/retained.json" && [[ $(jq -r .machine_id "$KG_STORE/retained.json") == "$KG_MACHINE" ]] || { kg_fail 'existing configuration is not owned'; return 1; }
            kg_regular /etc/komodo/periphery.config.toml || return 1
            reuse=true
        else config_changed=true; fi
    else
        binary=$(jq -r .binary <<<"$inspected"); unit=$(jq -r .unit <<<"$inspected")
        if [[ -e $KG_STORE/owner.json ]]; then
            kg_regular "$KG_STORE/owner.json" && [[ $(jq -r .fingerprint "$KG_STORE/owner.json") == "$expected" ]] && [[ $(jq -r .machine_id "$KG_STORE/owner.json") == "$KG_MACHINE" ]] || { kg_fail 'owned installation drifted'; return 1; }
        else
            [[ $KG_ACTION != uninstall && $(jq -r .adopt <<<"$KG_REQUEST_JSON") == true ]] || { kg_fail 'explicit adoption required'; return 1; }
        fi
        old_version=$(jq -r .version <<<"$inspected")
        [[ $(printf '%s\n' "$old_version" "$KG_DESIRED" | sort -V | head -1) == "$old_version" || $KG_ACTION == uninstall ]] || { kg_fail 'downgrades are unsupported'; return 1; }
        oldhash=$(kg_hash "$binary") || return 1
        if [[ $KG_ACTION == configure ]]; then
            [[ $KG_DESIRED == "$old_version" && $(jq -r .config_fingerprint <<<"$inspected") == "$(jq -r .config_fingerprint <<<"$KG_REQUEST_JSON")" ]] || { kg_fail 'configuration or version changed since preview'; return 1; }
            [[ $(jq '.config_paths|length' <<<"$inspected") == 1 ]] || { kg_fail 'configuration editing requires one explicit TOML file'; return 1; }
            config_path=$(jq -r '.config_paths[0]' <<<"$inspected")
            kg_prepare_configuration "$config_path" || return 1
            if ! cmp -s "$config_path" "$KG_CONFIG_STAGED"; then config_changed=true; fi
        fi
    fi
    kg_safe_path "$binary" && kg_safe_path "$unit" || return 1
    if [[ $KG_ACTION == install || $KG_ACTION == update ]]; then
        candidate=$(jq -r .staged_binary <<<"$KG_REQUEST_JSON"); digest=$(jq -r .asset_sha256 <<<"$KG_REQUEST_JSON")
        kg_regular "$candidate" && [[ $(kg_hash "$candidate") == "$digest" ]] || { kg_fail 'candidate checksum mismatch'; return 1; }
        chmod 0755 "$candidate" || return 1
        [[ $(kg_version "$candidate") == "$KG_DESIRED" ]] || { kg_fail 'candidate version mismatch'; return 1; }
    fi
    if [[ $config_changed == true && $expected == absent ]]; then
        jq -e 'all(.core_url,.server_name,.onboarding_key; type=="string" and length>0 and (explode|all(.>=32 and .!=127))) and
          (.core_url | test("^https?://"))' <<<"$KG_REQUEST_JSON" >/dev/null || { kg_fail 'invalid onboarding settings'; return 1; }
        kg_safe_path /etc/komodo/periphery.config.toml && kg_safe_path /etc/komodo/keys || return 1
    fi
    # Allocate and sync on the destination filesystem before stopping the agent.
    # Copy failure (including a full filesystem) leaves the service untouched.
    if [[ ( $KG_ACTION == install || $KG_ACTION == update ) && $oldhash != "$digest" ]]; then
        mkdir -p -- "${binary%/*}" || return 1
        KG_STAGED=$(mktemp "${binary%/*}/.periphery.XXXXXXXX") || return 1
        cp -- "$candidate" "$KG_STAGED" || { kg_fail 'destination staging failed; service unchanged'; return 1; }
        if [[ -f $binary ]]; then
            chown --reference="$binary" "$KG_STAGED" && chmod --reference="$binary" "$KG_STAGED" || return 1
        else chmod 0755 "$KG_STAGED" || return 1; fi
        sync -f "$KG_STAGED" || return 1
    fi
    # All replacements and removal targets are validated before durable backup.
    kg_safe_path "$KG_STORE/transaction" || return 1
    if [[ -d $KG_STORE/transaction ]]; then rm -rf -- "$KG_STORE/transaction" || return 1; fi
    mkdir -m 0700 "$KG_STORE/transaction" || return 1
    kg_backup "$binary" binary && kg_backup "$unit" unit && kg_backup "$KG_STORE/owner.json" owner || return 1
    if [[ $config_changed == true ]]; then
        if [[ $KG_ACTION == configure ]]; then
            [[ $(sha256sum -- "$config_path" | sha256sum | cut -d ' ' -f1) == "$(jq -r .config_fingerprint <<<"$KG_REQUEST_JSON")" ]] || { kg_fail 'configuration changed while preparing update'; return 1; }
        fi
        kg_backup "$config_path" config || return 1
    fi
    backups=$(find "$KG_STORE/transaction" -maxdepth 1 -type f -exec sha256sum {} + | jq -Rn '[inputs|capture("^(?<hash>[0-9a-f]{64})  (?<path>.*)$")|{key:(.path|split("/")|last),value:.hash}]|from_entries') || return 1
    if [[ $expected != absent && ! -e $KG_STORE/owner.json && ! -e $KG_STORE/adoption ]]; then
        cp -a "$KG_STORE/transaction" "$KG_STORE/adoption" && sync -f "$KG_STORE/adoption" || return 1
    fi
    jq -nc --argjson inspected "$inspected" --arg id "$KG_ID" --arg binary "$binary" --arg unit "$unit" \
        --arg action "$KG_ACTION" --arg config_path "$config_path" --argjson changed "$config_changed" --argjson backups "$backups" \
        '{schema:1,transaction_id:$id,machine_id:$inspected.machine_id,action:$action,binary:$binary,unit:$unit,
          active:$inspected.active,enabled:$inspected.enabled,config_changed:$changed,config_path:$config_path,backups:$backups,phase:"backed_up"}' | kg_atomic "$KG_STORE/pending.json" || return 1
    KG_OWN_TRANSACTION=1
    if [[ $KG_ACTION == uninstall ]]; then
        kg_mark stopping && systemctl stop "$KG_UNIT" >/dev/null 2>&1 && systemctl disable "$KG_UNIT" >/dev/null 2>&1 || { kg_fail 'could not stop/disable service'; return 1; }
        kg_mark replacing && rm -f -- "$binary" "$unit" && systemctl daemon-reload >/dev/null 2>&1 || { kg_fail 'could not remove owned files'; return 1; }
        jq -nc --arg machine "$KG_MACHINE" '{machine_id:$machine}' | kg_atomic "$KG_STORE/retained.json" || return 1
        rm -f -- "$KG_STORE/owner.json" || return 1
    else
        if [[ $KG_ACTION == configure && $config_changed == false ]] || [[ $KG_ACTION != configure && $expected != absent && $oldhash == "$digest" ]]; then
            : # Same-version adoption records ownership without restarting.
        else
            kg_mark stopping || return 1
            if [[ $expected != absent && ( $KG_ACTION != configure || $(jq -r .active <<<"$inspected") == active ) ]]; then
                systemctl stop "$KG_UNIT" >/dev/null 2>&1 || { kg_fail 'could not stop service'; return 1; }
            fi
            kg_mark replacing || return 1
            if [[ $KG_ACTION == configure ]]; then
                mv -fT -- "$KG_CONFIG_STAGED" "$config_path" && sync -f "${config_path%/*}" || return 1
                KG_CONFIG_STAGED=""
            else
                mv -fT -- "$KG_STAGED" "$binary" && sync -f "${binary%/*}" || return 1
                KG_STAGED=""
            fi
            if [[ $expected == absent ]]; then
                mkdir -p /etc/komodo/keys /etc/systemd/system || return 1
                if [[ $reuse == false ]]; then chmod 0700 /etc/komodo/keys || return 1; fi
                if [[ $config_changed == true ]]; then
                    { printf 'root_directory = "/etc/komodo"\nserver_enabled = false\n'
                      for field in core_address connect_as onboarding_key; do
                          case $field in core_address) key=core_url ;; connect_as) key=server_name ;; *) key=onboarding_key ;; esac
                          printf '%s = ' "$field"; kg_toml "$(jq -r --arg key "$key" '.[$key]' <<<"$KG_REQUEST_JSON")"; printf '\n'
                      done
                    } | (umask 077; cat > /etc/komodo/periphery.config.toml) || return 1
                fi
                cat > "$unit" <<'UNIT'
[Unit]
Description=Komodo Periphery agent
Wants=network-online.target
After=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/periphery --config-path /etc/komodo/periphery.config.toml
Restart=on-failure
UMask=0077
[Install]
WantedBy=multi-user.target
UNIT
                chmod 0644 "$unit" && sync -f "$unit" && systemctl daemon-reload >/dev/null 2>&1 && systemctl enable "$KG_UNIT" >/dev/null 2>&1 || return 1
            fi
            kg_mark starting || return 1
            if [[ $expected == absent || $(jq -r .active <<<"$inspected") == active ]]; then
                startup_since=$(date +%s)
                if ! { start_output=$(systemctl start "$KG_UNIT" 2>&1 | head -c 2048) && kg_service_health "$binary"; }; then
                    kg_startup_diagnostics "$startup_since" "$start_output" || true
                    kg_fail 'new service failed startup health check'; return 1
                fi
            fi
        fi
        local current
        current=$(kg_inspect)
        [[ $(jq -r .layout <<<"$current") == supported && $(jq -r .version <<<"$current") == "$KG_DESIRED" ]] || { kg_fail 'installed version could not be verified'; return 1; }
        jq --arg id "$KG_ID" '. + {transaction_id:$id}' <<<"$current" | kg_atomic "$KG_STORE/owner.json" || return 1
        KG_FINGERPRINT=$(jq -r .fingerprint <<<"$current")
    fi
    kg_mark committed && mv -fT "$KG_STORE/pending.json" "$KG_STORE/committed.json" && sync -f "$KG_STORE" || return 1
    KG_REASON="local operation completed; Core connectivity unverified"
    KG_SUCCESS=1
}
kg_finish() {
    local rc=$? rollback=not-needed
    trap - EXIT INT TERM HUP
    if [[ $KG_SUCCESS != 1 && $KG_OWN_TRANSACTION == 1 ]]; then
        if kg_restore; then rollback=restored; else rollback=failed; fi
    fi
    if [[ -n ${KG_STAGED:-} ]] && kg_safe_path "$KG_STAGED"; then rm -f -- "$KG_STAGED" || rc=1; fi
    if [[ -n ${KG_CONFIG_STAGED:-} ]] && kg_safe_path "$KG_CONFIG_STAGED"; then rm -f -- "$KG_CONFIG_STAGED" || rc=1; fi
    [[ $KG_SUCCESS == 1 ]] || rc=${rc:-1}
    if [[ $KG_SUCCESS != 1 && $rc == 0 ]]; then rc=1; fi
    printf '%s' "$KG_DIAGNOSTICS" | jq -c --arg result "$([[ $KG_SUCCESS == 1 ]] && printf success || printf failed)" --arg reason "${KG_REASON:-operation failed}" \
        --arg version "${KG_DESIRED:-}" --arg fingerprint "$KG_FINGERPRINT" --arg rollback "$rollback" --arg id "${KG_ID:-}" \
        '{schema:1,result:$result,reason:$reason,version:$version,fingerprint:$fingerprint,rollback:$rollback,transaction_id:$id,diagnostics:.}'
    exit "$rc"
}
case ${1:-} in
    inspect) kg_inspect ;;
    apply)
        KG_SUCCESS=0 KG_OWN_TRANSACTION=0
        trap kg_finish EXIT
        trap 'exit 130' INT TERM HUP
        kg_apply "${2:-}" || exit 1 ;;
    recover)
        KG_SUCCESS=0 KG_OWN_TRANSACTION=0 KG_ID=${2:-}
        [[ $KG_ID =~ ^[a-f0-9]{32}$ ]] || exit 64
        kg_store || exit 1
        IFS= read -r KG_MACHINE < /etc/machine-id
        [[ -f $KG_STORE/pending.json && $(jq -r .transaction_id "$KG_STORE/pending.json") == "$KG_ID" ]] || exit 1
        kg_restore ;;
    *) printf 'unsupported guest action\n' >&2; exit 64 ;;
esac
