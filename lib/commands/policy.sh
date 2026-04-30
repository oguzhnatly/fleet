#!/bin/bash
# fleet policy: Manage optional operator constitution injection.

_policy_help() {
    cat <<'HELP'

  Usage:
    fleet policy
    fleet policy show
    fleet policy enable
    fleet policy disable
    fleet policy require
    fleet policy optional
    fleet policy add "<rule>"
    fleet policy rm <index>
    fleet policy clear
    fleet policy title "<title>"
    fleet policy scope task,parallel,steer
    fleet policy preview <agent> "<prompt>" [--type code|review|research|deploy|qa] [--action task|parallel|steer]

  Config key:
    constitution.enabled = true
    constitution.rules = ["Rule text"]

HELP
}

_policy_require_config() {
    if ! fleet_has_config; then
        out_fail "No config at $FLEET_CONFIG_PATH"
        echo "       Run: fleet init"
        return 1
    fi
}

_policy_update() {
    local action="$1" value="${2:-}"
    _policy_require_config || return 1
    python3 - "$FLEET_CONFIG_PATH" "$action" "$value" <<'POLICY_UPDATE_PY'
import json, os, sys
path, action, value = sys.argv[1:4]
with open(path) as f:
    cfg = json.load(f)
policy = cfg.setdefault("constitution", {})
policy.setdefault("enabled", False)
policy.setdefault("title", "Operator Constitution")
policy.setdefault("mode", "prepend")
policy.setdefault("required", False)
policy.setdefault("applyTo", ["task", "parallel", "steer"])
policy.setdefault("rules", [])
if isinstance(policy.get("rules"), str):
    policy["rules"] = [policy["rules"]]
message = "updated"
if action == "enable":
    policy["enabled"] = True
    message = "enabled"
elif action == "disable":
    policy["enabled"] = False
    message = "disabled"
elif action == "require":
    policy["required"] = True
    policy["enabled"] = True
    message = "required"
elif action == "optional":
    policy["required"] = False
    message = "optional"
elif action == "add":
    rule = value.strip()
    if not rule:
        print("empty_rule")
        sys.exit(2)
    policy["rules"].append(rule)
    policy["enabled"] = True
    message = f"added:{len(policy['rules'])}"
elif action == "rm":
    try:
        idx = int(value)
    except Exception:
        print("bad_index")
        sys.exit(2)
    if idx < 1 or idx > len(policy["rules"]):
        print("bad_index")
        sys.exit(2)
    policy["rules"].pop(idx - 1)
    message = "removed"
elif action == "clear":
    policy["rules"] = []
    message = "cleared"
elif action == "title":
    title = value.strip()
    if not title:
        print("empty_title")
        sys.exit(2)
    policy["title"] = title
    message = "title"
elif action == "scope":
    allowed = {"task", "parallel", "steer", "all"}
    scope = [part.strip().lower() for part in value.split(",") if part.strip()]
    if not scope or any(part not in allowed for part in scope):
        print("bad_scope")
        sys.exit(2)
    policy["applyTo"] = scope
    message = "scope"
else:
    print("unknown_action")
    sys.exit(2)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
try:
    os.chmod(path, 0o600)
except Exception:
    pass
print(message)
POLICY_UPDATE_PY
}

_policy_show() {
    _policy_require_config || return 1
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
print(f"  required   {str(data.get('required', False)).lower()}")
agents = data.get('agents') or []
print(f"  agents     {', '.join(agents) if agents else 'all'}")
apply_to = data.get('applyTo') or ['task', 'parallel', 'steer']
if isinstance(apply_to, str):
    apply_to = [part.strip() for part in apply_to.split(',') if part.strip()]
print(f"  applies    {', '.join(apply_to) if apply_to else 'none'}")
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
    local agent="" prompt="" task_type="code" action="task"
    if [[ $# -lt 2 ]]; then
        _policy_help
        return 1
    fi
    agent="$1"; shift
    prompt="$1"; shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type|-t) task_type="${2:-code}"; shift 2 ;;
            --action|-a) action="${2:-task}"; shift 2 ;;
            *) shift ;;
        esac
    done
    out_header "Policy Preview"
    fleet_policy_apply "$prompt" "$agent" "$task_type" "$action"
}

cmd_policy() {
    local result
    case "${1:-show}" in
        show) _policy_show ;;
        enable)
            result="$(_policy_update enable)" || return 1
            [ "$result" = "enabled" ] && out_ok "Operator constitution enabled"
            ;;
        disable)
            result="$(_policy_update disable)" || return 1
            [ "$result" = "disabled" ] && out_ok "Operator constitution disabled"
            ;;
        require)
            result="$(_policy_update require)" || return 1
            [ "$result" = "required" ] && out_ok "Operator constitution required"
            ;;
        optional)
            result="$(_policy_update optional)" || return 1
            [ "$result" = "optional" ] && out_ok "Operator constitution optional"
            ;;
        add)
            if [[ $# -lt 2 ]]; then echo "  Usage: fleet policy add \"<rule>\""; return 1; fi
            result="$(_policy_update add "$2")" || { out_fail "Could not add rule"; return 1; }
            out_ok "Added constitution rule"
            ;;
        rm|remove)
            if [[ $# -lt 2 ]]; then echo "  Usage: fleet policy rm <index>"; return 1; fi
            result="$(_policy_update rm "$2")" || { out_fail "Rule index not found"; return 1; }
            [ "$result" = "removed" ] && out_ok "Removed constitution rule"
            ;;
        clear)
            result="$(_policy_update clear)" || return 1
            [ "$result" = "cleared" ] && out_ok "Cleared constitution rules"
            ;;
        title)
            if [[ $# -lt 2 ]]; then echo "  Usage: fleet policy title \"<title>\""; return 1; fi
            result="$(_policy_update title "$2")" || { out_fail "Could not set title"; return 1; }
            [ "$result" = "title" ] && out_ok "Updated constitution title"
            ;;
        scope)
            if [[ $# -lt 2 ]]; then echo "  Usage: fleet policy scope task,parallel,steer"; return 1; fi
            result="$(_policy_update scope "$2")" || { out_fail "Scope must use task, parallel, steer, or all"; return 1; }
            [ "$result" = "scope" ] && out_ok "Updated constitution scope"
            ;;
        preview) _policy_preview "${@:2}" ;;
        help|--help|-h) _policy_help ;;
        *) _policy_help; return 1 ;;
    esac
}
