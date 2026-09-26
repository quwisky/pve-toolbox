#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
export TOOLBOX_ROOT=$PWD
source modules/komodo-periphery/module.sh
[[ $MODULE_TAGS == *vm* ]] || fail 'VM discovery tag missing'
[[ $(./pve-toolbox list vm) == *komodo-periphery* ]] || fail 'VM list tag missing'
[[ $(./pve-toolbox _complete tags) == *$'\nvm\n'* ]] || fail 'VM completion tag missing'
_kp_load
declare -F kp_vm_change kp_vm_status kp_vm_check >/dev/null || fail 'VM lifecycle hooks missing'
printf 'ok VM module hooks registered\n'
