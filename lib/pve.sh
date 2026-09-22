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

# Shared local LXC inspection; these helpers never start, unlock or modify a CT.
pve_lxc_inventory() { # <node> -> PVE_LXC_JSON, PVE_LXC_ERROR
    PVE_LXC_JSON="" PVE_LXC_ERROR="invalid local node"
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || return 1
    local result
    PVE_LXC_ERROR="could not read local LXC inventory"
    result=$(pvesh get "/nodes/$1/lxc" --output-format json 2>/dev/null) || return 1
    PVE_LXC_ERROR="invalid or ambiguous local LXC inventory"
    jq -e 'type == "array" and all(.[];
        (.vmid | type == "number" and floor == . and . >= 100 and . <= 999999999)
        and (.status == "running" or .status == "stopped"))
        and (([.[].vmid] | unique | length) == length)' <<<"$result" >/dev/null 2>&1 || return 1
    PVE_LXC_JSON=$result PVE_LXC_ERROR=""
}

pve_lxc_ready() { # <local-node> <ctid> -> PVE_LXC_CONFIG_JSON, PVE_LXC_ERROR
    PVE_LXC_CONFIG_JSON="" PVE_LXC_ERROR="invalid local node or container ID"
    [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ && $2 =~ ^[1-9][0-9]{2,8}$ ]] || return 1
    local config status
    PVE_LXC_ERROR="local container configuration unavailable"
    config=$(pvesh get "/nodes/$1/lxc/$2/config" --output-format json 2>/dev/null) || return 1
    PVE_LXC_ERROR="container is locked, a template, or not Debian"
    jq -e 'type == "object" and (.template // 0) == 0 and
        (.lock // "") == "" and .ostype == "debian"' <<<"$config" >/dev/null 2>&1 || return 1
    PVE_LXC_ERROR="container is not running on this node"
    status=$(pvesh get "/nodes/$1/lxc/$2/status/current" --output-format json 2>/dev/null) || return 1
    jq -e 'type == "object" and .status == "running"' <<<"$status" >/dev/null 2>&1 || return 1
    PVE_LXC_CONFIG_JSON=$config PVE_LXC_ERROR=""
}
