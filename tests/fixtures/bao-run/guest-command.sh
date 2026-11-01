#!/bin/bash
# Guest commands inside the chroot, one per name. Every call is logged so tests can inspect argv.
[[ ${0##*/} != curl || ${1:-} != --version ]] || exit 0 # A tool check, not a network call.
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
        # /docker-inspect is the world: every container, running or stopped, as docker inspect shows it.
        [[ ! -f /docker-down ]] || { printf 'Cannot connect to the Docker daemon\n' >&2; exit 1; }
        case $1 in
            ps)
                [[ ! -f /docker-ps-raw ]] || { cat /docker-ps-raw; exit 0; }
                [[ -f /docker-inspect ]] || exit 0
                case $2 in
                    -aq) jq -r '.[].Id' /docker-inspect ;;
                    -q) jq -r '.[] | select(.State.Running).Id' /docker-inspect ;;
                    *) exit 99 ;;
                esac
                exit ;;
            inspect)
                [[ ! -f /docker-inspect-down ]] || exit 1
                [[ ! -f /docker-inspect-raw ]] || { cat /docker-inspect-raw; exit 0; }
                [[ $* == "inspect --type container $(jq -r 'map(.Id) | join(" ")' /docker-inspect)" ]] || exit 99
                cat /docker-inspect
                exit ;;
        esac
        [[ $1 == exec ]] || exit 99
        shift 2
        case $* in
            'sh -c :') ;;
            'sh -c bash -c : '*) [[ ! -f /docker-missing ]] || cat /docker-missing ;;
            'test -r /etc/bao-run/addr') ;;
            'sha256sum /usr/local/bin/bao-run') printf '%s  /usr/local/bin/bao-run\n' "$(</docker-sha)" ;;
            '/usr/local/bin/bao-run --check'*) printf 'ok\n' ;;
            *) exit 99 ;;
        esac ;;
    *) exit 99 ;;
esac
