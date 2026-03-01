#!/bin/bash
# fleet parallel · Decompose a high-level task into subtasks and dispatch in parallel
# Usage: fleet parallel "<task>" [--dry-run] [--timeout <minutes>]

# ── Decompose task into subtasks using heuristics + coordinator AI ────────────
_parallel_decompose() {
    local task="$1"

    python3 - "$FLEET_CONFIG_PATH" "$task" <<'PY'
import json, sys, re

with open(sys.argv[1]) as f:
    config = json.load(f)

task = sys.argv[2]
task_lower = task.lower()

available = [a["name"] for a in config.get("agents", [])]

# ── Heuristic decomposition ──────────────────────────────────────────────────
# Each subtask: { "agent": name, "prompt": str, "type": str }

subtasks = []

# Patterns that suggest multi-agent work
patterns = {
    "research": ["research", "analys", "investigat", "compet", "find out", "look up", "check if"],
    "code":     ["implement", "build", "create", "add", "fix", "refactor", "write code", "develop"],
    "review":   ["review", "audit", "check", "verify", "security", "lint"],
    "deploy":   ["deploy", "release", "ship", "publish", "push to prod"],
    "qa":       ["test", "qa", "quality", "spec", "coverage", "e2e"],
}

matched = {}
for agent_type, keywords in patterns.items():
    for kw in keywords:
        if kw in task_lower:
            matched[agent_type] = True
            break

# Build subtasks from matches
type_prompts = {
    "research": f"Research phase: {task}",
    "code":     f"Implementation: {task}",
    "review":   f"Code review: {task}",
    "qa":       f"Quality assurance and testing: {task}",
    "deploy":   f"Deploy: {task}",
}

# Map agent types to actual configured agents
type_to_agent = {}
for a in config.get("agents", []):
    name = a.get("name", "")
    role = a.get("role", name)
    # Match by name or role
    for t in patterns.keys():
        if t in name.lower() or t in role.lower():
            type_to_agent[t] = name

if not matched:
    # No patterns matched — single task to coder (default)
    agent = type_to_agent.get("code", available[0] if available else "coder")
    subtasks.append({"agent": agent, "type": "code", "prompt": task})
else:
    for task_type in matched:
        agent = type_to_agent.get(task_type)
        if not agent:
            # Find first available agent with matching name
            for a in available:
                if task_type in a.lower():
                    agent = a
                    break
        if not agent and available:
            agent = available[0]
        if agent:
            subtasks.append({
                "agent":  agent,
                "type":   task_type,
                "prompt": type_prompts.get(task_type, task),
            })

print(json.dumps(subtasks))
PY
}

cmd_parallel() {
    local task="" dry_run=false timeout_min=30

    if [[ $# -lt 1 ]]; then
        echo "  Usage: fleet parallel \"<task>\" [--dry-run] [--timeout <minutes>]"
        echo "  Example: fleet parallel \"audit all products: CI status, last deploy, open tickets\" --dry-run"
        return 1
    fi

    task="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry_run=true; shift ;;
            --timeout)    timeout_min="${2:-30}"; shift 2 ;;
            *) shift ;;
        esac
    done

    out_header "Fleet Parallel"
    echo -e "  ${CLR_DIM}Task: ${task}${CLR_RESET}"
    echo ""

    # ── Decompose ───────────────────────────────────────────────────────────
    local subtasks_json
    subtasks_json="$(_parallel_decompose "$task")"

    if [ -z "$subtasks_json" ] || [ "$subtasks_json" = "[]" ]; then
        out_fail "Could not decompose task into subtasks."
        return 1
    fi

    # ── Display plan ────────────────────────────────────────────────────────
    echo -e "  ${CLR_BOLD}Execution plan:${CLR_RESET}"
    echo ""

    python3 - "$subtasks_json" <<'PY'
import json, sys

subtasks = json.loads(sys.argv[1])
C = "\033[36m"; D = "\033[2m"; BOLD = "\033[1m"; N = "\033[0m"

for i, st in enumerate(subtasks, 1):
    print(f"  {BOLD}{i}.{N} {C}{st['agent']:12}{N}  [{st['type']}]")
    print(f"     {D}{st['prompt'][:100]}{'…' if len(st['prompt']) > 100 else ''}{N}")
    print()

print(f"  {D}{'─' * 40}{N}")
print(f"  {len(subtasks)} subtask(s) ready to dispatch in parallel.")
print()
PY

    if [ "$dry_run" = "true" ]; then
        out_info "Dry run complete. Remove --dry-run to execute."
        return 0
    fi

    # ── Confirm before executing ────────────────────────────────────────────
    echo -e "  ${CLR_YELLOW}Execute? [y/N]${CLR_RESET} \c"
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        out_dim "Cancelled."
        return 0
    fi

    echo ""
    out_section "Dispatching..."
    echo ""

    # ── Dispatch all subtasks in parallel ───────────────────────────────────
    python3 - "$subtasks_json" "$FLEET_CONFIG_PATH" "$FLEET_LOG_FILE" "$timeout_min" <<'PY'
import json, sys, subprocess, threading, time, uuid, os
from datetime import datetime, timezone

subtasks   = json.loads(sys.argv[1])
config_path = sys.argv[2]
log_file    = sys.argv[3]
timeout_s   = int(sys.argv[4]) * 60

with open(config_path) as f:
    config = json.load(f)

agent_map = {a["name"]: a for a in config.get("agents", [])}

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; D = "\033[2m"; C = "\033[36m"; N = "\033[0m"; BOLD = "\033[1m"

results = {}
lock = threading.Lock()

def now_ts():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def log_entry(task_id, agent, task_type, prompt, dispatched_at):
    entry = {
        "task_id": task_id, "agent": agent, "task_type": task_type,
        "prompt": prompt[:500], "dispatched_at": dispatched_at,
        "completed_at": None, "outcome": "pending", "steer_count": 0,
    }
    os.makedirs(os.path.dirname(log_file), exist_ok=True)
    with open(log_file, "a") as f:
        f.write(json.dumps(entry) + "\n")

def run_subtask(st):
    agent_name = st["agent"]
    agent_conf = agent_map.get(agent_name, {})
    port       = agent_conf.get("port", "")
    token      = agent_conf.get("token", "")
    prompt     = st["prompt"]
    task_type  = st["type"]

    if not port:
        with lock:
            results[agent_name] = {"ok": False, "error": f"agent '{agent_name}' not configured"}
        return

    task_id = str(uuid.uuid4())[:8]
    session_user = f"fleet-{agent_name}"
    dispatched_at = now_ts()
    log_entry(task_id, agent_name, task_type, prompt, dispatched_at)

    payload = json.dumps({
        "model": "openclaw",
        "messages": [{"role": "user", "content": prompt}],
        "user": session_user,
    })

    with lock:
        print(f"  {C}→{N} {agent_name:12}  dispatching...  [{task_id}]")

    try:
        r = subprocess.run(
            ["curl", "-s", "--max-time", str(timeout_s),
             f"http://127.0.0.1:{port}/v1/chat/completions",
             "-H", f"Authorization: Bearer {token}",
             "-H", "Content-Type: application/json",
             "-d", payload],
            capture_output=True, text=True, timeout=timeout_s + 5
        )
        data = json.loads(r.stdout)
        content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
        outcome = "success" if content else "failure"
        summary = content.strip()[:120] if content else "no response"

        with lock:
            results[agent_name] = {"ok": outcome == "success", "task_id": task_id, "summary": summary}
            # Update log
            lines = []
            if os.path.exists(log_file):
                with open(log_file) as f:
                    for line in f:
                        try:
                            e = json.loads(line.strip())
                            if e.get("task_id") == task_id:
                                e["outcome"] = outcome
                                e["completed_at"] = now_ts()
                            lines.append(json.dumps(e))
                        except Exception:
                            lines.append(line.strip())
                with open(log_file, "w") as f:
                    f.write("\n".join(lines) + "\n")

    except Exception as ex:
        with lock:
            results[agent_name] = {"ok": False, "task_id": task_id, "error": str(ex)}

threads = []
for st in subtasks:
    t = threading.Thread(target=run_subtask, args=(st,))
    t.start()
    threads.append(t)

for t in threads:
    t.join()

print()
print(f"  {BOLD}Results{N}")
print(f"  {D}{'─' * 40}{N}")
for agent_name, res in results.items():
    if res.get("ok"):
        print(f"  {G}✅{N} {agent_name:12}  {D}{res.get('summary', '')}{N}")
    else:
        print(f"  {R}❌{N} {agent_name:12}  {D}{res.get('error', res.get('summary', 'failed'))}{N}")
print()
PY
}
