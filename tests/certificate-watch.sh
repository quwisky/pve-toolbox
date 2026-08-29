#!/usr/bin/env bash
# Generated certificate and cluster fixtures for the read-only certificate audit.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/conf" "$WORK/state" "$WORK/pve/nodes"

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

TOOLBOX_CONF_DIR="$WORK/conf"
TOOLBOX_STATE_DIR="$WORK/state"
CW_PVE_DIR="$WORK/pve"
export TOOLBOX_CONF_DIR TOOLBOX_STATE_DIR CW_PVE_DIR

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/pve.sh
source "$ROOT/lib/pve.sh"
# shellcheck source=lib/report.sh
source "$ROOT/lib/report.sh"
# shellcheck source=lib/doctor.sh
source "$ROOT/lib/doctor.sh"
# shellcheck source=modules/certificate-watch/module.sh
source "$ROOT/modules/certificate-watch/module.sh"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj /CN=Test-Root \
    -keyout "$WORK/root.key" -out "$WORK/root.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=Test-Intermediate \
    -keyout "$WORK/intermediate.key" -out "$WORK/intermediate.csr" >/dev/null 2>&1
printf '%s\n' 'basicConstraints=critical,CA:TRUE' \
    'keyUsage=critical,keyCertSign,cRLSign' > "$WORK/intermediate.ext"
openssl x509 -req -in "$WORK/intermediate.csr" -CA "$WORK/root.crt" \
    -CAkey "$WORK/root.key" -CAcreateserial -days 180 \
    -extfile "$WORK/intermediate.ext" -out "$WORK/intermediate.crt" >/dev/null 2>&1

make_leaf() { # make_leaf <node> <san-host> <days> <include-intermediate> [common-name]
    local node=$1 san=$2 days=$3 include_intermediate=$4 common_name=${5:-$1}
    local dir="$WORK/pve/nodes/$1"
    mkdir -p "$dir"
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$common_name" \
        -keyout "$WORK/$node.key" -out "$WORK/$node.csr" >/dev/null 2>&1
    printf '%s\n' "subjectAltName=DNS:$san" 'extendedKeyUsage=serverAuth' > "$WORK/$node.ext"
    openssl x509 -req -in "$WORK/$node.csr" -CA "$WORK/intermediate.crt" \
        -CAkey "$WORK/intermediate.key" -CAcreateserial -days "$days" \
        -extfile "$WORK/$node.ext" -out "$WORK/$node.crt" >/dev/null 2>&1
    if [[ $include_intermediate == yes ]]; then
        awk '1' "$WORK/$node.crt" "$WORK/intermediate.crt" > "$dir/pveproxy-ssl.pem"
    else
        cp -- "$WORK/$node.crt" "$dir/pveproxy-ssl.pem"
    fi
}

make_leaf pve1 pve1 60 yes
make_leaf pve2 other.example 60 yes other.example
make_leaf pve3 pve3 60 no
make_leaf pve4 pve4 1 yes
CW_CA_BUNDLE="$WORK/root.crt"
CW_NOW_EPOCH=$(( $(date -u -d "$(openssl x509 -in "$WORK/pve4.crt" -noout -enddate | cut -d= -f2-)" +%s) + 1 ))
export CW_CA_BUNDLE CW_NOW_EPOCH
CW_TASK_FAILURE_NODE=""

pvesh() {
    [[ ${1:-} == get ]] || fail "certificate audit attempted a mutating PVE call: $*"
    local endpoint=${2:-}
    shift 2
    if [[ $endpoint == "/nodes/$CW_TASK_FAILURE_NODE/tasks" ]]; then
        printf 'task history unavailable\n' >&2
        return 7
    fi
    case $endpoint in
        /nodes) printf '%s\n' '[{"node":"pve1"},{"node":"pve2"},{"node":"pve3"},{"node":"pve4"}]' ;;
        /nodes/pve1/tasks|/nodes/pve2/tasks|/nodes/pve3/tasks|/nodes/pve4/tasks)
            [[ $* == '--limit 200 --output-format json' ]] \
                || fail "unsupported ACME task options: $*"
            case $endpoint in
                /nodes/pve1/tasks)
                    jq -n --argjson now "$CW_NOW_EPOCH" \
                        '[{type:"acmerenew",status:"OK",endtime:($now-86400)}]' ;;
                /nodes/pve3/tasks)
                    jq -n --argjson now "$CW_NOW_EPOCH" '[
                      {type:"acmenewcert",status:"OK",endtime:($now-172800)},
                      {type:"acmerenew",status:"certificate order failed",endtime:($now-3600)}
                    ]' ;;
                *) printf '[]\n' ;;
            esac ;;
        /nodes/pve2/status) return 1 ;;
        /nodes/*/status) printf '%s\n' '{"status":"online"}' ;;
        /nodes/pve1/config|/nodes/pve3/config) printf '%s\n' '{"acme":"account=default","acmedomain0":"domain=example.test"}' ;;
        /nodes/pve2/config|/nodes/pve4/config) printf '%s\n' '{}' ;;
        *) fail "unexpected PVE fixture endpoint: $endpoint" ;;
    esac
}

result_state() {
    local wanted=$1 i
    for ((i = 0; i < ${#REPORT_IDS[@]}; i++)); do
        [[ ${REPORT_IDS[$i]} == "$wanted" ]] && { printf '%s' "${REPORT_STATES[$i]}"; return 0; }
    done
    return 1
}

conf_set certificate-watch CW_WARN_DAYS 30
conf_set certificate-watch CW_FAIL_DAYS 7
conf_set certificate-watch CW_ACME_STALE_DAYS 45
doctor_reset
module_doctor
[[ $(report_exit_code) == 1 ]] || fail "critical certificate fixture did not fail"
[[ $(result_state node.pve1.expiry) == pass ]] || fail "valid certificate expiry failed"
[[ $(result_state node.pve1.hostname) == pass ]] || fail "valid hostname failed"
[[ $(result_state node.pve1.chain) == pass ]] || fail "complete chain failed"
[[ $(result_state node.pve1.acme) == pass ]] || fail "recent ACME success failed"
[[ $(result_state node.pve2.reachability) == warn ]] || fail "unreachable node was not warned"
[[ $(result_state node.pve2.hostname) == fail ]] || fail "hostname mismatch was not failed"
[[ $(result_state node.pve3.chain) == fail ]] || fail "incomplete chain was not failed"
[[ $(result_state node.pve3.acme) == fail ]] || fail "latest failed ACME task was not failed"
[[ $(result_state node.pve4.expiry) == fail ]] || fail "expired generated certificate was not failed"
pass "valid, expired, mismatched, incomplete-chain, and unreachable fixtures"

doctor_reset
CW_TASK_FAILURE_NODE=pve3
module_doctor
[[ $(result_state api.acme-task-history) == fail ]] \
    || fail "partial ACME task history did not fail closed"
[[ ${#REPORT_STATES[@]} -eq 1 ]] || fail "certificate audit continued after task history failure"
CW_TASK_FAILURE_NODE=""
pass "certificate audit rejects partial per-node task history"

CW_FAIL_DAYS=7 CW_WARN_DAYS=30
now=1000000
[[ $(_cw_expiry_state "$now" "$now") == expired ]] || fail "expiry instant boundary"
[[ $(_cw_expiry_state $((now + 7 * 86400)) "$now") == fail ]] || fail "failure boundary"
[[ $(_cw_expiry_state $((now + 30 * 86400)) "$now") == warn ]] || fail "warning boundary"
[[ $(_cw_expiry_state $((now + 30 * 86400 + 1)) "$now") == pass ]] || fail "healthy boundary"
pass "UTC expiry boundaries are inclusive and predictable"

CW_FAIL_DAYS=30 CW_WARN_DAYS=7 CW_ACME_STALE_DAYS=45
_cw_validate && fail "reversed expiry thresholds were accepted"
CW_FAIL_DAYS=7 CW_WARN_DAYS=30 CW_ACME_STALE_DAYS=0
_cw_validate && fail "zero ACME stale threshold was accepted"
pass "certificate thresholds fail closed"
