#!/bin/bash
# fleet/lib/core/state.sh — State persistence for delta tracking (SITREP, audits)

FLEET_STATE_DIR="${FLEET_STATE_DIR:-$HOME/.fleet/state}"

state_dir() {
    mkdir -p "$FLEET_STATE_DIR"
    echo "$FLEET_STATE_DIR"
}

state_save() {
    local key="$1" data="$2"
    mkdir -p "$FLEET_STATE_DIR"
    echo "$data" > "$FLEET_STATE_DIR/$key.json"
}

state_load() {
    local key="$1"
    local file="$FLEET_STATE_DIR/$key.json"
    if [ -f "$file" ]; then
        cat "$file"
    else
        echo "{}"
    fi
}

state_timestamp() {
    local key="$1"
    local file="$FLEET_STATE_DIR/$key.json"
    if [ -f "$file" ]; then
        stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}
