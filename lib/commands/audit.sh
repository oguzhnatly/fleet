#!/usr/bin/env bash
# fleet audit: Check for misconfigurations and operational risks

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
        if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
            out_ok "Config permissions: $perms"
        else
            out_warn "Config permissions: $perms (recommend 600 because config can reference credentials)"
            _inc_warnings
        fi

        # Check token sources
        _inc_checks
        local token_report
        token_report=$(python3 - "$FLEET_CONFIG_PATH" <<'PY_TOKEN_AUDIT' 2>/dev/null
import json, os, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
missing = []
inline = []
placeholder = []
for a in c.get('agents', []):
    name = a.get('name', '?')
    token = str(a.get('token', '') or '')
    token_env = str(a.get('tokenEnv') or a.get('token_env') or '')
    if token.lower() in ('your-token-here', 'your-agent-token', 'changeme', 'todo'):
        placeholder.append(name)
    if token:
        inline.append(name)
    elif token_env and os.environ.get(token_env):
        pass
    else:
        missing.append(name)
print(json.dumps({'missing': missing, 'inline': inline, 'placeholder': placeholder}))
PY_TOKEN_AUDIT
)
        local missing_count inline_count placeholder_count
        missing_count=$(python3 - "$token_report" <<'PY_COUNT'
import json, sys
print(len(json.loads(sys.argv[1]).get('missing', [])))
PY_COUNT
)
        inline_count=$(python3 - "$token_report" <<'PY_COUNT'
import json, sys
print(len(json.loads(sys.argv[1]).get('inline', [])))
PY_COUNT
)
        placeholder_count=$(python3 - "$token_report" <<'PY_COUNT'
import json, sys
print(len(json.loads(sys.argv[1]).get('placeholder', [])))
PY_COUNT
)
        if [ "$missing_count" = "0" ]; then
            out_ok "All agent token sources resolve"
        else
            out_warn "$missing_count agent(s) have no token or resolved tokenEnv"
            python3 - "$token_report" <<'PY_SHOW_MISSING'
import json, sys
for n in json.loads(sys.argv[1]).get('missing', []): print(f'  {n}')
PY_SHOW_MISSING
            _inc_warnings
        fi
        if [ "$inline_count" = "0" ]; then
            out_ok "No inline agent tokens stored"
        else
            out_warn "$inline_count agent(s) store inline tokens, prefer tokenEnv"
            python3 - "$token_report" <<'PY_SHOW_INLINE'
import json, sys
for n in json.loads(sys.argv[1]).get('inline', []): print(f'  {n}')
PY_SHOW_INLINE
            _inc_warnings
        fi
        if [ "$placeholder_count" = "0" ]; then
            out_ok "No placeholder tokens found"
        else
            out_warn "$placeholder_count agent(s) have placeholder tokens"
            python3 - "$token_report" <<'PY_SHOW_PLACEHOLDER'
import json, sys
for n in json.loads(sys.argv[1]).get('placeholder', []): print(f'  {n}')
PY_SHOW_PLACEHOLDER
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
            offline_agents=$(python3 - "$FLEET_CONFIG_PATH" <<'PY_AGENT_AUDIT' 2>/dev/null | tail -1
import json, subprocess, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
offline = 0
for a in c.get('agents', []):
    try:
        r = subprocess.run(['curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
            '--max-time', '2', f'http://127.0.0.1:{a["port"]}/health'],
            capture_output=True, text=True)
        if r.stdout.strip() != '200':
            offline += 1
            print(f'  {a["name"]} (:{a["port"]})')
    except Exception:
        offline += 1
print(offline)
PY_AGENT_AUDIT
)

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
            red_repos=$(python3 - "$FLEET_CONFIG_PATH" <<'PY_CI_AUDIT' 2>/dev/null
import json, subprocess, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
red = []
for r in c.get('repos', []):
    try:
        result = subprocess.run(['gh', 'run', 'list', '--repo', r['repo'], '--limit', '1',
            '--json', 'conclusion'], capture_output=True, text=True, timeout=10)
        runs = json.loads(result.stdout) if result.stdout.strip() else []
        if runs and runs[0].get('conclusion') == 'failure':
            red.append(r.get('name', r['repo']))
    except Exception:
        pass
for r in red:
    print(r)
PY_CI_AUDIT
)

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
    latest_backup=$(python3 - "$HOME/.fleet/backups" <<'PY_LATEST_BACKUP'
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
        echo -e "  ${CLR_GREEN}${CLR_BOLD}All clear${CLR_RESET}: $checks checks passed, 0 warnings"
    else
        echo -e "  ${CLR_YELLOW}${CLR_BOLD}${warnings} warning(s)${CLR_RESET} across $checks checks"
    fi
    echo ""
}
