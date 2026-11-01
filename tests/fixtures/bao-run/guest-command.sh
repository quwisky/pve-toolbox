#!/bin/bash
# Guest commands inside the chroot, one per name. Every call is logged so tests can inspect argv.
printf '%s %s\n' "${0##*/}" "$*" >> /calls
case ${0##*/} in
    uname) printf 'x86_64\n' ;;
    hostname) printf '192.0.2.50 198.51.100.7\n' ;;
    curl)
        IFS= read -r -d '' _ || true
        [[ $* != *revoke-self* ]] || exit 0
        case $(</curl-mode) in
            ok) printf '{"auth":{"client_token":"token"}}\n200' ;;
            rejected) printf '{"errors":["denied"]}\n400'; exit 22 ;;
            sealed) printf '{"errors":["sealed"]}\n503'; exit 22 ;;
            down) exit 7 ;;
        esac ;;
    systemctl)
        [[ $1 == show ]] || exit 99
        cat /unit ;;
    runuser)
        [[ -f /runuser-can-read ]] ;;
    docker)
        [[ $1 == exec ]] || exit 99
        shift 2
        case $* in
            'sh -c :') ;;
            'sh -c command -v bash && command -v curl && command -v jq') printf '/bin/x\n/bin/y\n/bin/z\n' ;;
            'test -r /etc/bao-run/addr') ;;
            'sha256sum /usr/local/bin/bao-run') printf '%s  /usr/local/bin/bao-run\n' "$(</docker-sha)" ;;
            '/usr/local/bin/bao-run --check'*) printf 'ok\n' ;;
            *) exit 99 ;;
        esac ;;
    *) exit 99 ;;
esac
