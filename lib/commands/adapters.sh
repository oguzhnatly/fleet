#!/bin/bash
# fleet adapters: list registered adapters with verification status and bindings.

cmd_adapters() {
    fleet_adapter_load_all
    out_header "Fleet Adapters"

    local types=()
    while IFS= read -r t; do types+=("$t"); done < <(fleet_adapter_types)

    if [ "${#types[@]}" -eq 0 ]; then
        out_fail "No adapters registered"
        echo "       Reinstall fleet or set FLEET_ADAPTERS_DIR to a valid directory."
        return 1
    fi

    printf "  ${CLR_DIM}%-10s  %-10s  %-8s  %s${CLR_RESET}\n" "TYPE" "MODE" "ORIGIN" "DESCRIPTION"
    printf "  ${CLR_DIM}%s${CLR_RESET}\n" "$(printf '%.0s─' {1..62})"

    local t origin desc verified label color
    local verified_count=0 inferred_count=0
    for t in "${types[@]}"; do
        origin="${FLEET_ADAPTER_ORIGIN[$t]:-builtin}"
        desc="$(adapter_"${t}"_describe 2>/dev/null || echo "no description")"
        verified="$(adapter_"${t}"_verified 2>/dev/null || echo "unknown")"
        if [ "$verified" = "verified" ]; then
            color="${CLR_GREEN}"; label="verified "; verified_count=$((verified_count+1))
        elif [ "$verified" = "inferred" ]; then
            color="${CLR_YELLOW}"; label="inferred "; inferred_count=$((inferred_count+1))
        else
            color="${CLR_DIM}"; label="unknown  "
        fi
        printf "  ${CLR_BOLD}%-10s${CLR_RESET}  ${color}%-10s${CLR_RESET}  ${CLR_DIM}%-8s${CLR_RESET}  %s\n" \
            "$t" "$label" "$origin" "$desc"
    done

    echo ""
    out_dim "$(printf '%d adapter%s registered  %d verified  %d inferred' \
        "${#types[@]}" "$([ "${#types[@]}" -ne 1 ] && echo s)" \
        "$verified_count" "$inferred_count")"

    if fleet_has_config; then
        echo ""
        out_section "Bindings"
        printf "  ${CLR_DIM}%-8s  %-20s  %s${CLR_RESET}\n" "KIND" "NAME" "ADAPTER"
        printf "  ${CLR_DIM}%s${CLR_RESET}\n" "$(printf '%.0s─' {1..44})"
        local has_any=false
        local kind line entry name a_type
        local agent_count=0 runtime_count=0
        while IFS= read -r line; do
            kind="${line%%$'\t'*}"
            entry="${line#*$'\t'}"
            name="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('name',''))" "$entry" 2>/dev/null)"
            a_type="$(fleet_adapter_resolve "$entry")"
            if fleet_adapter_exists "$a_type"; then
                printf "  ${CLR_DIM}%-8s${CLR_RESET}  %-20s  ${CLR_CYAN}%s${CLR_RESET}\n" "$kind" "$name" "$a_type"
            else
                printf "  ${CLR_DIM}%-8s${CLR_RESET}  %-20s  ${CLR_RED}%s (missing adapter)${CLR_RESET}\n" "$kind" "$name" "$a_type"
            fi
            [ "$kind" = "agent" ]   && agent_count=$((agent_count+1))
            [ "$kind" = "runtime" ] && runtime_count=$((runtime_count+1))
            has_any=true
        done < <(fleet_adapter_iter_entries)
        if $has_any; then
            echo ""
            out_dim "$(printf '%d agent%s  %d runtime%s' \
                "$agent_count" "$([ "$agent_count" -ne 1 ] && echo s)" \
                "$runtime_count" "$([ "$runtime_count" -ne 1 ] && echo s)")"
        else
            out_dim "No agents or runtimes configured."
        fi
    fi

    echo ""
    out_section "Legend"
    out_dim "verified   adapter probed the runtime and got a real response"
    out_dim "inferred   adapter detected presence without a protocol handshake"
    out_dim "user adapters: drop a <type>.sh into ${FLEET_ADAPTERS_DIR_USER}"
    echo ""
}
