#!/bin/bash
# fleet adapters: list registered adapters with verification status and
# any obvious problems. v4 entry point that proves the adapter layer is
# healthy on this machine.

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

    out_section "Registered"
    local t origin desc verified label color
    for t in "${types[@]}"; do
        origin="${FLEET_ADAPTER_ORIGIN[$t]:-builtin}"
        desc="$(adapter_"${t}"_describe 2>/dev/null || echo "no description")"
        verified="$(adapter_"${t}"_verified 2>/dev/null || echo "unknown")"
        if [ "$verified" = "verified" ]; then
            color="$CLR_GREEN"; label="verified"
        elif [ "$verified" = "inferred" ]; then
            color="$CLR_YELLOW"; label="inferred"
        else
            color="$CLR_DIM"; label="unknown"
        fi
        printf "  ${CLR_BOLD}%-10s${CLR_RESET} ${color}%-9s${CLR_RESET} ${CLR_DIM}%-7s${CLR_RESET} %s\n" \
            "$t" "$label" "$origin" "$desc"
    done

    # Probe each entry in config so the operator can see at a glance which
    # adapter applies to which agent or runtime.
    if fleet_has_config; then
        out_section "Bindings"
        local has_any=false
        local kind line entry name a_type
        while IFS= read -r line; do
            kind="${line%%$'\t'*}"
            entry="${line#*$'\t'}"
            name="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('name',''))" "$entry" 2>/dev/null)"
            a_type="$(fleet_adapter_resolve "$entry")"
            if fleet_adapter_exists "$a_type"; then
                printf "  ${CLR_DIM}%-7s${CLR_RESET} %-18s ${CLR_CYAN}%s${CLR_RESET}\n" "$kind" "$name" "$a_type"
            else
                printf "  ${CLR_DIM}%-7s${CLR_RESET} %-18s ${CLR_RED}%s (missing)${CLR_RESET}\n" "$kind" "$name" "$a_type"
            fi
            has_any=true
        done < <(fleet_adapter_iter_entries)
        if ! $has_any; then
            out_dim "No agents or runtimes configured."
        fi
    fi

    out_section "Notes"
    out_dim "verified  adapter actually probed the runtime and got a real response"
    out_dim "inferred  adapter detected presence (e.g. pgrep) without a handshake"
    out_dim "user adapters can be dropped into ${FLEET_ADAPTERS_DIR_USER}"
    echo ""
}
