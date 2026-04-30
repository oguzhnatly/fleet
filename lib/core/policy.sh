#!/bin/bash
# fleet/lib/core/policy.sh: Optional operator constitution prompt policy.
# Applies operator-defined rules to dispatched agent tasks.

fleet_policy_apply() {
    local prompt="$1" agent="${2:-}" task_type="${3:-}" action="${4:-task}"
    python3 - "$FLEET_CONFIG_PATH" "$agent" "$task_type" "$action" "$prompt" <<'POLICY_PY'
import json, sys

config_path, agent, task_type, action, prompt = sys.argv[1:6]
try:
    with open(config_path) as f:
        config = json.load(f)
except Exception:
    print(prompt)
    sys.exit(0)

policy = config.get("constitution") or config.get("policy") or {}
if not isinstance(policy, dict) or not policy.get("enabled", False):
    print(prompt)
    sys.exit(0)

only_agents = policy.get("agents") or []
if only_agents and agent not in only_agents:
    print(prompt)
    sys.exit(0)

apply_to = policy.get("applyTo") or policy.get("apply_to") or policy.get("commands") or ["task", "parallel", "steer"]
if isinstance(apply_to, str):
    apply_to = [part.strip() for part in apply_to.split(",")]
apply_to = [str(part).strip().lower() for part in apply_to if str(part).strip()]
if apply_to and action.lower() not in apply_to and "all" not in apply_to:
    print(prompt)
    sys.exit(0)

rules = policy.get("rules") or []
if isinstance(rules, str):
    rules = [rules]
rules = [str(r).strip() for r in rules if str(r).strip()]

prefix = str(policy.get("prefix") or policy.get("prompt") or "Follow the operator constitution before doing this task.").strip()
title = str(policy.get("title") or "Operator Constitution").strip()
mode = str(policy.get("mode") or "prepend").strip().lower()

if not rules and not prefix:
    print(prompt)
    sys.exit(0)

lines = [title]
if prefix:
    lines.append(prefix)
if agent:
    lines.append(f"Agent: {agent}")
if task_type:
    lines.append(f"Task type: {task_type}")
if rules:
    lines.append("Rules:")
    for i, rule in enumerate(rules, 1):
        lines.append(f"{i}. {rule}")
block = "\n".join(lines).strip()

if mode == "append":
    print(f"{prompt}\n\n{block}")
else:
    print(f"{block}\n\nTask:\n{prompt}")
POLICY_PY
}

fleet_policy_summary_json() {
    python3 - "$FLEET_CONFIG_PATH" <<'POLICY_PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        config = json.load(f)
except Exception:
    print(json.dumps({"enabled": False, "rules": []}))
    sys.exit(0)
policy = config.get("constitution") or config.get("policy") or {}
if not isinstance(policy, dict):
    policy = {}
rules = policy.get("rules") or []
if isinstance(rules, str):
    rules = [rules]
print(json.dumps({
    "enabled": bool(policy.get("enabled", False)),
    "title": policy.get("title") or "Operator Constitution",
    "mode": policy.get("mode") or "prepend",
    "agents": policy.get("agents") or [],
    "applyTo": policy.get("applyTo") or policy.get("apply_to") or policy.get("commands") or ["task", "parallel", "steer"],
    "rules": [str(r) for r in rules if str(r).strip()],
}))
POLICY_PY
}
