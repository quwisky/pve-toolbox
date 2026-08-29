#!/usr/bin/env bash
# Shared, read-only Proxmox VE API helpers.
# shellcheck disable=SC2034 # Public result variables are read by callers.

[[ ${_TOOLBOX_PVE_LOADED:-0} == 1 ]] && return 0
_TOOLBOX_PVE_LOADED=1

PVE_TASKS_JSON=""
PVE_TASKS_ERROR=""

pve_collect_node_tasks() { # pve_collect_node_tasks <nodes-json> [pvesh options...]
    local nodes_json=$1 node output
    local -a nodes=() task_sets=()
    shift
    PVE_TASKS_JSON=""
    PVE_TASKS_ERROR=""

    if ! jq -e '
        type == "array" and length > 0
        and all(.[].node;
            type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*$"))
    ' <<<"$nodes_json" >/dev/null 2>&1; then
        PVE_TASKS_ERROR="Proxmox node inventory was invalid or empty"
        return 1
    fi
    mapfile -t nodes < <(jq -r '[.[].node] | unique[]' <<<"$nodes_json")

    for node in "${nodes[@]}"; do
        if ! output=$(pvesh get "/nodes/$node/tasks" "$@" --output-format json 2>&1); then
            PVE_TASKS_ERROR="could not read Proxmox task history for $node: $output"
            return 1
        fi
        if ! output=$(jq -c --arg node "$node" '
            if type == "array" and all(.[]; type == "object") then
                map(if ((.node // "") | type == "string" and length > 0)
                    then . else . + {node: $node} end)
            else
                error("not an array of objects")
            end
        ' <<<"$output" 2>/dev/null); then
            PVE_TASKS_ERROR="Proxmox task response for $node was not a JSON array of objects"
            return 1
        fi
        task_sets+=("$output")
    done

    PVE_TASKS_JSON=$(printf '%s\n' "${task_sets[@]}" | jq -cs 'add')
}
