#!/bin/bash
set -eu
case ${0##*/} in
    cp)
        if [[ -f /fail-destination-copy && ${*: -1} == */.periphery.* ]]; then exit 1; fi
        exec /usr/bin/cp-real "$@" ;;
    chmod)
        if [[ -f /fail-key-mode && ${*: -1} == /etc/komodo/keys ]]; then exit 1; fi
        exec /usr/bin/chmod-real "$@" ;;
    mv)
        if [[ -f /fail-commit && $* == *'/.record.'* && ${*: -1} == /var/lib/pve-toolbox/komodo-periphery/pending.json ]] && grep -q '"phase": "committed"' "${*: -2:1}"; then exit 1; fi
        exec /usr/bin/mv-real "$@" ;;
    sleep) exit 0 ;;
    readlink)
        if [[ -f /health-mode && $* == *'/proc/123/exe'* ]]; then
            mode=$(cat /health-mode)
            sample=$(cat /health-sample)
            case $mode in
                delayed-exec) if ((sample <= 2)); then printf '/usr/lib/systemd/systemd\n'; exit; fi ;;
                unreadable-exe) exit 1 ;;
                wrong-exe) printf '/usr/bin/other-service\n'; exit ;;
                lost-exe) if ((sample >= 3)); then exit 1; fi ;;
            esac
        fi
        if [[ -f /health-mode && $(cat /health-mode) == delayed-wrapper && $* == *'/proc/124/exe'* ]] && (($(cat /health-sample) <= 2)); then
            printf '/usr/bin/other-service\n'; exit
        fi
        if [[ -f /wrapper-main ]]; then
            case $* in
                *'/proc/123/exe'|'-f /bin/sh') printf '/usr/bin/dash\n'; exit ;;
                *'/proc/124/exe') printf '/usr/local/bin/periphery\n'; exit ;;
            esac
        fi
        if [[ $* == *'/proc/123/exe'* || $* == *'/proc/124/exe'* ]]; then
            if [[ -f '/opt/custom path/periphery' ]]; then printf '/opt/custom path/periphery\n'; else printf '/usr/local/bin/periphery\n'; fi
        else exec /usr/bin/readlink-real "$@"; fi ;;
    uname) printf 'x86_64\n' ;;
    dpkg-query) [[ -f /package-owned ]] ;;
    journalctl)
        [[ $* == '-u periphery.service --since @'*' -n 20 --no-pager --output=json --output-fields=MESSAGE' ]] || exit 98
        [[ ! -f /fail-diagnostics ]] || exit 1
        [[ -f /startup-failed || -f /health-mode ]] || exit 98
        cat /startup-journal ;;
    systemctl)
        case $1 in
            show)
                if [[ -f /health-mode && $* == 'show periphery.service --property=ActiveState,MainPID,NRestarts' ]]; then
                    sample=0
                    [[ ! -f /health-sample ]] || sample=$(cat /health-sample)
                    sample=$((sample+1)); printf '%s\n' "$sample" > /health-sample
                    active=active; pid=123; restarts=0
                    case $(cat /health-mode) in
                        activating) if ((sample <= 2)); then active=activating; fi ;;
                        zero-pid) if ((sample <= 2)); then pid=0; fi ;;
                        restart) if ((sample >= 3)); then restarts=1; fi ;;
                        pid-change) if ((sample >= 3)); then pid=124; fi ;;
                    esac
                    printf 'ActiveState=%s\nMainPID=%s\nNRestarts=%s\n' "$active" "$pid" "$restarts"
                    exit
                fi
                if [[ $* == *'--property=ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,NRestarts,MainPID' ]]; then
                    [[ ! -f /fail-diagnostics ]] || exit 1
                    if [[ -f /health-mode ]]; then
                        printf 'ActiveState=active\nSubState=running\nResult=success\nExecMainCode=0\nExecMainStatus=0\nNRestarts=0\nMainPID=123\n'
                        exit
                    fi
                    [[ -f /startup-failed ]] || exit 98
                    printf 'ActiveState=failed\nSubState=failed\nResult=exit-code\nExecMainCode=1\nExecMainStatus=203\nNRestarts=3\nMainPID=123\n'
                    exit
                fi
                if [[ ! -f /etc/systemd/system/periphery.service ]]; then printf 'LoadState=not-found\n'; exit; fi
                if [[ -f /stale-unit ]]; then cat /stale-unit; else printf 'NeedDaemonReload=no\n'; fi
                printf 'LoadState=loaded\nFragmentPath=/etc/systemd/system/periphery.service\nUser=root\nType=simple\nEnvironmentFiles=\n'
                if [[ -f /with-dropin ]]; then printf 'DropInPaths=/etc/systemd/system/periphery.service.d/priority.conf\n'; else printf 'DropInPaths=\n'; fi
                printf 'ActiveState=%s\nUnitFileState=%s\nMainPID=123\nNRestarts=0\n' "$(cat /active)" "$(cat /enabled)"
                config_path=/etc/komodo/periphery.config.toml
                [[ ! -f /custom-config ]] || config_path=/opt/periphery/config.toml
                if [[ -f '/opt/custom path/periphery' ]]; then
                    printf 'ExecStart={ path=/opt/custom path/periphery ; argv[]=/opt/custom path/periphery --config-path %s ; ignore_errors=no ; }\n' "$config_path"
                    exit
                fi
                if [[ $(sed -n 's/^ExecStart=//p' /etc/systemd/system/periphery.service) == /usr/local/bin/periphery* ]]; then
                    printf 'ExecStart={ path=/usr/local/bin/periphery ; argv[]=/usr/local/bin/periphery --config-path %s ; ignore_errors=no ; }\n' "$config_path"; exit
                fi
                printf 'ExecStart={ path=/bin/sh ; argv[]=/bin/sh -lc /usr/local/bin/periphery --config-path %s ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }\n' "$config_path"
                ;;
            start)
                if [[ -f /crash-start ]]; then kill -KILL "$PPID"; exit 1; fi
                printf '%s\n' "$*" >> /calls
                if [[ -f /fail-old-start ]] && /usr/local/bin/periphery --version | grep -q 2.3.2; then exit 1; fi
                if { [[ -f /fail-new-start || -f /fail-new-health ]] && /usr/local/bin/periphery --version | grep -q 2.3.3; } ||
                    { [[ -f /fail-config-start ]] && grep -Fq 'connect_as = "new-name"' /etc/komodo/periphery.config.toml; }; then
                    : > /startup-failed
                    printf 'failed\n' > /active
                    [[ -f /fail-new-health ]] && exit 0
                    if [[ ! -f /silent-start-failure ]]; then printf 'Job for periphery.service failed: Permission denied\n' >&2; fi
                    exit 1
                fi
                rm -f /startup-failed
                printf 'active\n' > /active ;;
            stop) [[ -f /etc/systemd/system/periphery.service ]] || exit 5; rm -f /startup-failed; printf '%s\n' "$*" >> /calls; printf 'inactive\n' > /active ;;
            enable)
                printf '%s\n' "$*" >> /calls; printf 'enabled\n' > /enabled
                if [[ -f /crash-enable ]]; then kill -KILL "$PPID"; exit 1; fi ;;
            disable) printf '%s\n' "$*" >> /calls; printf 'disabled\n' > /enabled ;;
            daemon-reload) printf '%s\n' "$*" >> /calls ;;
            *) printf '%s\n' "$*" >> /calls; exit 99 ;;
        esac ;;
    *) exit 99 ;;
esac
