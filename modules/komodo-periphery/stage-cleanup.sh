#!/usr/bin/env bash
set -euo pipefail
dir=${1:-}
machine=${2:-}
[[ $# == 2 && $dir =~ ^/run/pve-toolbox-komodo-[a-f0-9]{32}$ && $machine =~ ^[a-f0-9]{32}$ ]] || exit 1
IFS= read -r actual < /etc/machine-id || exit 1
[[ $actual == "$machine" ]] || exit 1
[[ ! -e $dir ]] && exit 0
[[ -d $dir && ! -L $dir && $(stat -c %u -- "$dir") == 0 && $(stat -c %a -- "$dir") == 700 ]] || exit 1
for item in receiver.sh guest.sh periphery request.json; do
    file=$dir/$item
    [[ ! -L $file && ( ! -e $file || ( -f $file && $(stat -c %u -- "$file") == 0 ) ) ]] || exit 1
done
rm -f -- "$dir/receiver.sh" "$dir/guest.sh" "$dir/periphery" "$dir/request.json"
rmdir -- "$dir"
