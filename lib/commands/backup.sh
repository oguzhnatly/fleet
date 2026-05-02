#!/bin/bash
# fleet backup / fleet restore: safe config backup and restoration

cmd_backup() {
    local include_auth=false include_secrets=false assume_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --include-auth) include_auth=true; shift ;;
            --include-secrets) include_secrets=true; shift ;;
            --yes|-y) assume_yes=true; shift ;;
            --help|-h)
                cat <<'HELP'
  Usage: fleet backup [--include-secrets] [--include-auth] [--yes]

  By default, fleet backup creates a sanitized backup with token values redacted
  and excludes OpenClaw login profile files. Use the include flags only after operator
  approval.
HELP
                return 0 ;;
            *) shift ;;
        esac
    done

    if [ "$include_auth" = "true" ] || [ "$include_secrets" = "true" ]; then
        fleet_confirm_action "backup credential-bearing files" "This may copy reusable tokens or OpenClaw login profile files into ~/.fleet/backups." "$assume_yes" || return 1
    fi

    local backup_root backup_dir
    backup_root="$HOME/.fleet/backups"
    backup_dir="$backup_root/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    chmod 700 "$backup_root" "$backup_dir" 2>/dev/null || true

    out_header "Backup"

    local count=0

    # OpenClaw config
    if [ -f "$HOME/.openclaw/openclaw.json" ]; then
        cp "$HOME/.openclaw/openclaw.json" "$backup_dir/"
        chmod 600 "$backup_dir/openclaw.json" 2>/dev/null || true
        out_ok "openclaw.json"
        count=$((count + 1))
    fi

    # Cron jobs
    if [ -f "$HOME/.openclaw/cron/jobs.json" ]; then
        mkdir -p "$backup_dir/cron"
        cp "$HOME/.openclaw/cron/jobs.json" "$backup_dir/cron/"
        chmod 600 "$backup_dir/cron/jobs.json" 2>/dev/null || true
        out_ok "cron/jobs.json"
        count=$((count + 1))
    fi

    # Fleet config
    if [ -f "$FLEET_CONFIG_PATH" ]; then
        if [ "$include_secrets" = "true" ]; then
            cp "$FLEET_CONFIG_PATH" "$backup_dir/fleet-config.json"
            out_warn "fleet config copied with secrets"
        else
            python3 - "$FLEET_CONFIG_PATH" "$backup_dir/fleet-config.json" <<'PY_SANITIZE_CONFIG'
import json, sys
src, dst = sys.argv[1:3]
with open(src) as f:
    cfg = json.load(f)
for section in ("agents", "runtimes"):
    for item in cfg.get(section, []) if isinstance(cfg.get(section, []), list) else []:
        if item.get("token"):
            item["token"] = ""
            item["tokenRedacted"] = True
if isinstance(cfg.get("gateway"), dict) and cfg["gateway"].get("token"):
    cfg["gateway"]["token"] = ""
    cfg["gateway"]["tokenRedacted"] = True
with open(dst, "w") as f:
    json.dump(cfg, f, indent=2)
PY_SANITIZE_CONFIG
            out_ok "fleet config sanitized"
        fi
        chmod 600 "$backup_dir/fleet-config.json" 2>/dev/null || true
        count=$((count + 1))
    fi

    # OpenClaw login profile files are excluded unless explicitly requested.
    if [ "$include_auth" = "true" ]; then
        local auth_dir="$HOME/.openclaw/agents"
        if [ -d "$auth_dir" ]; then
            find "$auth_dir" -name "auth-profiles.json" -exec sh -c '
                rel=$(echo "$1" | sed "s|^'"$auth_dir"'/||")
                dir=$(dirname "$rel")
                mkdir -p "'"$backup_dir"'/auth/$dir"
                cp "$1" "'"$backup_dir"'/auth/$rel"
                chmod 600 "'"$backup_dir"'/auth/$rel" 2>/dev/null || true
            ' _ {} \;
            out_warn "OpenClaw login profile files included"
            count=$((count + 1))
        fi
    else
        out_dim "OpenClaw login profile files excluded by default"
    fi

    find "$backup_dir" -type d -exec chmod 700 {} \; 2>/dev/null || true
    find "$backup_dir" -type f -exec chmod 600 {} \; 2>/dev/null || true

    echo ""
    out_info "Backed up $count item(s) to $backup_dir"
}

cmd_restore() {
    local assume_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) assume_yes=true; shift ;;
            --help|-h)
                echo "  Usage: fleet restore [--yes]"
                return 0 ;;
            *) shift ;;
        esac
    done

    local latest
    latest=$(python3 - "$HOME/.fleet/backups" <<'PY_LATEST_BACKUP'
import os, sys
root = sys.argv[1]
best = ""
best_mtime = -1
try:
    for name in os.listdir(root):
        path = os.path.join(root, name)
        if os.path.isdir(path):
            mtime = os.path.getmtime(path)
            if mtime > best_mtime:
                best = path
                best_mtime = mtime
except Exception:
    pass
print(best)
PY_LATEST_BACKUP
)

    if [ -z "$latest" ]; then
        out_header "Restore"
        out_fail "No backups found in ~/.fleet/backups/"
        return 1
    fi

    fleet_confirm_action "restore latest Fleet backup" "Source: $latest" "$assume_yes" || return 1

    out_header "Restore from $(basename "$latest")"

    if [ -f "$latest/openclaw.json" ]; then
        cp "$latest/openclaw.json" "$HOME/.openclaw/"
        out_ok "openclaw.json"
    fi

    if [ -f "$latest/cron/jobs.json" ]; then
        mkdir -p "$HOME/.openclaw/cron"
        cp "$latest/cron/jobs.json" "$HOME/.openclaw/cron/"
        out_ok "cron/jobs.json"
    fi

    if [ -f "$latest/fleet-config.json" ]; then
        mkdir -p "$(dirname "$FLEET_CONFIG_PATH")"
        cp "$latest/fleet-config.json" "$FLEET_CONFIG_PATH"
        chmod 600 "$FLEET_CONFIG_PATH" 2>/dev/null || true
        out_ok "fleet config"
    fi

    echo ""
    out_warn "Restart gateway to apply: openclaw gateway restart"
}
