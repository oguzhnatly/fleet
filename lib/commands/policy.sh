#!/bin/bash
# fleet policy: Show and preview optional operator constitution injection.

_policy_help() {
    cat <<'HELP'

  Usage:
    fleet policy
    fleet policy show
    fleet policy preview <agent> "<prompt>" [--type code|review|research|deploy|qa]

  Config key:
    constitution.enabled = true
    constitution.rules = ["Rule text"]

HELP
}

_policy_show() {
    if ! fleet_has_config; then
        out_fail "No config at $FLEET_CONFIG_PATH"
        echo "       Run: fleet init"
        return 1
    fi
    out_header "Operator Constitution"
    python3 - "$(fleet_policy_summary_json)" <<'POLICY_PY'
import json, sys
try:
    data = json.loads(sys.argv[1])
except Exception:
    data = {"enabled": False, "rules": []}
print(f"  enabled    {str(data.get('enabled', False)).lower()}")
print(f"  title      {data.get('title', 'Operator Constitution')}")
print(f"  mode       {data.get('mode', 'prepend')}")
agents = data.get('agents') or []
print(f"  agents     {', '.join(agents) if agents else 'all'}")
print("")
rules = data.get('rules') or []
if rules:
    print("  rules")
    for i, rule in enumerate(rules, 1):
        print(f"    {i}. {rule}")
else:
    print("  no rules configured")
POLICY_PY
}

_policy_preview() {
    local agent="" prompt="" task_type="code"
    if [[ $# -lt 2 ]]; then
        _policy_help
        return 1
    fi
    agent="$1"; shift
    prompt="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type|-t) task_type="${2:-code}"; shift 2 ;;
            *) shift ;;
        esac
    done
    out_header "Policy Preview"
    fleet_policy_apply "$prompt" "$agent" "$task_type"
}

cmd_policy() {
    case "${1:-show}" in
        show)    _policy_show ;;
        preview) _policy_preview "${@:2}" ;;
        help|--help|-h) _policy_help ;;
        *) _policy_help; return 1 ;;
    esac
}
