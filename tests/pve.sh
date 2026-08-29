#!/usr/bin/env bash
# Contract tests for shared read-only Proxmox VE API helpers.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
ROOT=$PWD
FIXTURES="$ROOT/tests/fixtures/pve9"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PVE_CALL_LOG="$WORK/calls"

pass() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

# shellcheck source=lib/pve.sh
source "$ROOT/lib/pve.sh"

PVE_TEST_MODE=success
pvesh() {
    local action=${1:-} endpoint=${2:-}
    shift 2
    [[ $action == get ]] || fail "PVE helper attempted a mutating action: $action"
    [[ $* == '--typefilter vzdump --limit 500 --output-format json' ]] \
        || fail "PVE helper used unsupported task options: $*"
    printf '%s\n' "$endpoint" >> "$PVE_CALL_LOG"
    case "$PVE_TEST_MODE:$endpoint" in
        success:/nodes/pve1/tasks)
            awk '1' "$FIXTURES/tasks-pve1.json" ;;
        success:/nodes/pve2/tasks)
            awk '1' "$FIXTURES/tasks-pve2.json" ;;
        failure:/nodes/pve1/tasks)
            awk '1' "$FIXTURES/tasks-pve1.json" ;;
        failure:/nodes/pve2/tasks)
            printf 'permission denied\n' >&2
            return 7 ;;
        malformed:/nodes/pve1/tasks)
            printf '{"not":"an array"}\n' ;;
        *)
            fail "PVE helper used unsupported endpoint: $endpoint" ;;
    esac
}

node_fixture_json=$(<"$FIXTURES/nodes.json")
pve_collect_node_tasks "$node_fixture_json" --typefilter vzdump --limit 500 \
    || fail "valid PVE 9 task fixtures were rejected: $PVE_TASKS_ERROR"
[[ $(paste -sd ' ' "$PVE_CALL_LOG") == '/nodes/pve1/tasks /nodes/pve2/tasks' ]] \
    || fail "nodes were not queried once in deterministic order"
[[ $(jq -r 'length' <<<"$PVE_TASKS_JSON") == 2 ]] \
    || fail "per-node task arrays were not aggregated"
[[ $(jq -r '.[0].node' <<<"$PVE_TASKS_JSON") == pve1 ]] \
    || fail "task rows without a node were not attributed to their endpoint"
pass "PVE 9 node task histories are aggregated with strict options"

PVE_TEST_MODE=failure
: > "$PVE_CALL_LOG"
if pve_collect_node_tasks "$node_fixture_json" --typefilter vzdump --limit 500; then
    fail "a failed node task request was accepted"
fi
[[ $PVE_TASKS_ERROR == *pve2*permission\ denied* ]] \
    || fail "node task failure omitted actionable context: $PVE_TASKS_ERROR"
[[ -z $PVE_TASKS_JSON ]] || fail "partial task history escaped after a node failure"
pass "task aggregation fails closed when any node request fails"

PVE_TEST_MODE=malformed
if pve_collect_node_tasks '[{"node":"pve1"}]' --typefilter vzdump --limit 500; then
    fail "a malformed node task response was accepted"
fi
[[ $PVE_TASKS_ERROR == *'not a JSON array of objects'* ]] \
    || fail "malformed response error was not specific"
pass "malformed task responses fail closed"

for invalid in '[]' '[{"node":"../escape"}]' '[{"node":null}]' '{"node":"pve1"}'; do
    pve_collect_node_tasks "$invalid" --typefilter vzdump --limit 500 \
        && fail "invalid node inventory was accepted: $invalid"
done
pass "empty, unsafe, and malformed node inventories are rejected"
