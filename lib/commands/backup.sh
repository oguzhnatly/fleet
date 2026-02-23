#!/bin/bash
# fleet backup / fleet restore · Config backup and restoration

cmd_backup() {
    local backup_dir
    backup_dir="$HOME/.fleet/backups/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    out_header "Backup"

    local count=0

    # OpenClaw config
    if [ -f "$HOME/.openclaw/openclaw.json" ]; then
        cp "$HOME/.openclaw/openclaw.json" "$backup_dir/"
        out_ok "openclaw.json"
        count=$((count + 1))
    fi

    # Cron jobs
    if [ -f "$HOME/.openclaw/cron/jobs.json" ]; then
        mkdir -p "$backup_dir/cron"
        cp "$HOME/.openclaw/cron/jobs.json" "$backup_dir/cron/"
        out_ok "cron/jobs.json"
        count=$((count + 1))
    fi

    # Fleet config
    if [ -f "$FLEET_CONFIG_PATH" ]; then
        cp "$FLEET_CONFIG_PATH" "$backup_dir/fleet-config.json"
        out_ok "fleet config"
        count=$((count + 1))
    fi

    # Auth profiles
    local auth_dir="$HOME/.openclaw/agents"
    if [ -d "$auth_dir" ]; then
        find "$auth_dir" -name "auth-profiles.json" -exec sh -c '
            rel=$(echo "$1" | sed "s|^'"$auth_dir"'/||")
            dir=$(dirname "$rel")
            mkdir -p "'"$backup_dir"'/auth/$dir"
            cp "$1" "'"$backup_dir"'/auth/$rel"
        ' _ {} \;
        out_ok "auth profiles"
        count=$((count + 1))
    fi

    echo ""
    out_info "Backed up $count items to $backup_dir"
}

cmd_restore() {
    local latest
    latest=$(ls -dt "$HOME/.fleet/backups"/*/ 2>/dev/null | head -1)

    if [ -z "$latest" ]; then
        out_header "Restore"
        out_fail "No backups found in ~/.fleet/backups/"
        return 1
    fi

    out_header "Restore from $(basename "$latest")"

    if [ -f "$latest/openclaw.json" ]; then
        cp "$latest/openclaw.json" "$HOME/.openclaw/"
        out_ok "openclaw.json"
    fi

    if [ -f "$latest/cron/jobs.json" ]; then
        cp "$latest/cron/jobs.json" "$HOME/.openclaw/cron/"
        out_ok "cron/jobs.json"
    fi

    if [ -f "$latest/fleet-config.json" ]; then
        mkdir -p "$(dirname "$FLEET_CONFIG_PATH")"
        cp "$latest/fleet-config.json" "$FLEET_CONFIG_PATH"
        out_ok "fleet config"
    fi

    echo ""
    out_warn "Restart gateway to apply: openclaw gateway restart"
}
