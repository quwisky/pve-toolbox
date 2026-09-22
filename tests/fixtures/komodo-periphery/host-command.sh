#!/bin/bash
set -euo pipefail
case ${0##*/} in
    hostname) printf 'pve1\n' ;;
    pveversion) printf 'pve-manager/9.0\n' ;;
    pvesh)
        [[ $1 == get && $3 == --output-format && $4 == json ]] || exit 98
        case $2 in
            /nodes/pve1/lxc) printf '[{"vmid":101,"name":"test","status":"running"}]' ;;
            /nodes/pve1/lxc/101/config) [[ ! -f $KP_TEST_ROOT/moved ]] || exit 1; printf '{"ostype":"debian","rootfs":"local:vm-101-disk-0"}' ;;
            /nodes/pve1/lxc/101/status/current) printf '{"status":"running"}' ;;
            *) exit 98 ;;
        esac ;;
    pct)
        action=$1; id=$2; shift 2
        [[ $id == 101 ]] || exit 98
        printf 'pct %s %s\n' "$action" "$id" >> "$KP_HOST_CALLS"
        if [[ $action == exec ]]; then
            [[ $1 == -- ]] || exit 98
            shift
            if [[ $* == *' apply '* ]]; then printf 'apply\n' >> "$KP_HOST_CALLS"; fi
            chroot "$KP_TEST_ROOT" "$@"
        elif [[ $action == push ]]; then
            [[ $3 == --perms && $4 == 0600 && $2 =~ ^/run/pve-toolbox-komodo-[a-f0-9]{32}/(guest.sh|periphery|request.json)$ ]] || exit 98
            cp -- "$1" "$KP_TEST_ROOT$2"
            chmod 0600 "$KP_TEST_ROOT$2"
            if [[ -f $KP_TEST_ROOT/move-after-push ]]; then : > "$KP_TEST_ROOT/moved"; fi
        else exit 98; fi ;;
    curl)
        url=${*: -1}
        case $url in
            https://api.github.com/repos/moghtech/komodo/releases/tags/v2.3.3)
                hash=$(sha256sum "$KP_RELEASE" | cut -d ' ' -f1)
                jq -nc --arg digest "sha256:$hash" '{tag_name:"v2.3.3",assets:[{name:"periphery-x86_64",digest:$digest,browser_download_url:"https://github.com/moghtech/komodo/releases/download/v2.3.3/periphery-x86_64"}]}' ;;
            https://github.com/moghtech/komodo/releases/download/v2.3.3/periphery-x86_64)
                while (($#)); do if [[ $1 == -o ]]; then cp "$KP_RELEASE" "$2"; exit; fi; shift; done
                exit 98 ;;
            *) exit 98 ;;
        esac ;;
    *) exit 98 ;;
esac
