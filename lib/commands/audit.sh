#!/usr/bin/env bash
# fleet audit — Check for misconfigurations and operational risks

cmd_audit() {
    out_header "Fleet Audit"

    local warnings=0
    local checks=0

    # Helper to safely increment counters (bash arithmetic returns 1 when result is 0)
    _inc_checks() { checks=$((checks + 1)); }
    _inc_warnings() { warnings=$((warnings + 1)); }

    # ── Config checks ───────────────────────────────────────────────────────
    out_section "Configuration"

    _inc_checks
    if fleet_has_config; then
        out_ok "Config file exists at $FLEET_CONFIG_PATH"
    else
        out_fail "No config file found"
        echo "       Run: fleet init"
        _inc_warnings
    fi

    if fleet_has_config; then
        # Check config permissions
        _inc_checks
        local perms
        perms=$(stat -c "%a" "$FLEET_CONFIG_PATH" 2>/dev/null || stat -f "%Lp" "$FLEET_CONFIG_PATH" 2>/dev/null)
        if [ "$perms" = "600" ] || [ "$perms" = "644" ]; then
            out_ok "Config permissions: $perms"
        else
            out_warn "Config permissions: $perms (recommend 600 if tokens present)"
            _inc_warnings
        fi

        # Check for empty tokens
        _inc_checks
        local empty_tokens
        empty_tokens=$(python3 -c "
import json
with open('$FLEET_CONFIG_PATH') as f:
    c = json.load(f)
empty = [a['name'] for a in c.get('agents', []) if not a.get('token', '').strip()]
print(len(empty))
for n in empty: print(f'  {n}')
" 2>/dev/null)
        local empty_count
        empty_count=$(echo "$empty_tokens" | head -1)
        if [ "$empty_count" = "0" ]; then
            out_ok "All agent tokens configured"
        else
            out_warn "$empty_count agent(s) have empty tokens"
            echo "$empty_tokens" | tail -n +2
            _inc_warnings
        fi

        # Check for placeholder tokens
        _inc_checks
        local placeholder_tokens
        placeholder_tokens=$(python3 -c "
import json
with open('$FLEET_CONFIG_PATH') as f:
    c = json.load(f)
placeholders = [a['name'] for a in c.get('agents', [])
    if a.get('token', '') in ('your-token-here', 'your-agent-token', 'changeme', 'TODO')]
print(len(placeholders))
for n in placeholders: print(f'  {n}')
" 2>/dev/null)
        local ph_count
        ph_count=$(echo "$placeholder_tokens" | head -1)
        if [ "$ph_count" = "0" ]; then
            out_ok "No placeholder tokens found"
        else
            out_warn "$ph_count agent(s) have placeholder tokens"
            echo "$placeholder_tokens" | tail -n +2
            _inc_warnings
        fi
    fi

    # ── Agent health checks ─────────────────────────────────────────────────
    out_section "Agents"

    if fleet_has_config; then
        local total_agents offline_agents
        total_agents=$(_json_array_len "$FLEET_CONFIG_PATH" "agents")
        offline_agents=0

        if [ "$total_agents" -gt 0 ]; then
            _inc_checks
            offline_agents=$(python3 -c "
import json, subprocess
with open('$FLEET_CONFIG_PATH') as f:
    c = json.load(f)
offline = 0
for a in c.get('agents', []):
    try:
        r = subprocess.run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
            '--max-time', '2', f'http://127.0.0.1:{a[\"port\"]}/health'],
            capture_output=True, text=True)
        if r.stdout.strip() != '200':
            offline += 1
            print(f'  {a[\"name\"]} (:{a[\"port\"]})')
    except:
        offline += 1
print(offline)
" 2>/dev/null | tail -1)

            if [ "$offline_agents" = "0" ]; then
                out_ok "All $total_agents agents online"
            else
                out_fail "$offline_agents/$total_agents agents offline"
                _inc_warnings
            fi
        else
            out_info "No agents configured"
        fi

        # Check main gateway
        _inc_checks
        local gw_port
        gw_port=$(fleet_gateway_port)
        local gw_code
        gw_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:$gw_port/health" 2>/dev/null)
        if [ "$gw_code" = "200" ]; then
            out_ok "Main gateway healthy (:$gw_port)"
        else
            out_fail "Main gateway unhealthy (:$gw_port, HTTP $gw_code)"
            _inc_warnings
        fi
    fi

    # ── CI checks ───────────────────────────────────────────────────────────
    out_section "CI"

    if command -v gh &>/dev/null; then
        _inc_checks
        out_ok "gh CLI available"

        if fleet_has_config; then
            local red_repos
            red_repos=$(python3 -c "
import json, subprocess
with open('$FLEET_CONFIG_PATH') as f:
    c = json.load(f)
red = []
for r in c.get('repos', []):
    try:
        result = subprocess.run(['gh', 'run', 'list', '--repo', r['repo'], '--limit', '1',
            '--json', 'conclusion'], capture_output=True, text=True, timeout=10)
        runs = json.loads(result.stdout) if result.stdout.strip() else []
        if runs and runs[0].get('conclusion') == 'failure':
            red.append(r.get('name', r['repo']))
    except: pass
for r in red: print(r)
" 2>/dev/null)

            _inc_checks
            if [ -z "$red_repos" ]; then
                out_ok "All CI green"
            else
                local red_count
                red_count=$(echo "$red_repos" | wc -l)
                out_fail "$red_count repo(s) with failing CI"
                echo "$red_repos" | while read -r r; do echo "       $r"; done
                _inc_warnings
            fi
        fi
    else
        _inc_checks
        out_warn "gh CLI not installed (CI checks unavailable)"
        _inc_warnings
    fi

    # ── Resource checks ─────────────────────────────────────────────────────
    out_section "Resources"

    # Memory
    _inc_checks
    local mem_pct=0
    mem_pct=$(python3 -c "
with open('/proc/meminfo') as f:
    lines = f.readlines()
total = int([l for l in lines if l.startswith('MemTotal')][0].split()[1])
avail = int([l for l in lines if l.startswith('MemAvailable')][0].split()[1])
print(int((total - avail) / total * 100))
" 2>/dev/null || echo "0")

    if [ "$mem_pct" -gt 90 ]; then
        out_fail "Memory usage: ${mem_pct}% (critical)"
        _inc_warnings
    elif [ "$mem_pct" -gt 75 ]; then
        out_warn "Memory usage: ${mem_pct}% (high)"
        _inc_warnings
    elif [ "$mem_pct" -gt 0 ]; then
        out_ok "Memory usage: ${mem_pct}%"
    fi

    # Disk
    _inc_checks
    local disk_pct
    disk_pct=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    if [ -n "$disk_pct" ]; then
        if [ "$disk_pct" -gt 90 ]; then
            out_fail "Disk usage: ${disk_pct}% (critical)"
            _inc_warnings
        elif [ "$disk_pct" -gt 75 ]; then
            out_warn "Disk usage: ${disk_pct}% (high)"
            _inc_warnings
        else
            out_ok "Disk usage: ${disk_pct}%"
        fi
    fi

    # ── Backup checks ───────────────────────────────────────────────────────
    out_section "Backups"

    _inc_checks
    local latest_backup
    latest_backup=$(ls -dt "$HOME/.fleet/backups"/*/ 2>/dev/null | head -1 || true)
    if [ -n "$latest_backup" ]; then
        local backup_age_days
        backup_age_days=$(( ($(date +%s) - $(stat -c %Y "$latest_backup" 2>/dev/null || stat -f %m "$latest_backup" 2>/dev/null || echo "0")) / 86400 ))
        if [ "$backup_age_days" -gt 7 ]; then
            out_warn "Last backup: ${backup_age_days} days ago (recommend weekly)"
            _inc_warnings
        else
            out_ok "Last backup: ${backup_age_days} day(s) ago"
        fi
    else
        out_warn "No backups found"
        echo "       Run: fleet backup"
        _inc_warnings
    fi

    # ── Summary ─────────────────────────────────────────────────────────────
    echo ""
    if [ "$warnings" -eq 0 ]; then
        echo -e "  ${CLR_GREEN}${CLR_BOLD}All clear${CLR_RESET} — $checks checks passed, 0 warnings"
    else
        echo -e "  ${CLR_YELLOW}${CLR_BOLD}${warnings} warning(s)${CLR_RESET} across $checks checks"
    fi
    echo ""
}
