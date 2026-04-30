#!/bin/bash
# fleet parallel: Decompose a high-level task into subtasks and dispatch in parallel
# Usage: fleet parallel "<task>" [--dry-run] [--timeout <minutes>]

# ── v3: Trust-weighted decomposition ─────────────────────────────────────────
# Selects the highest-trust agent per task type from the dispatch log.
# When no log data exists, falls back to name-based role matching
# (agents whose name contains the task type keyword, e.g. "coder" for code tasks).
_parallel_decompose() {
    local task="$1"

    python3 - "$FLEET_CONFIG_PATH" "$FLEET_LOG_FILE" "$task" \
              "${FLEET_TRUST_WINDOW_HOURS:-72}" <<'PY'
import json, sys, os
from datetime import datetime, timezone

with open(sys.argv[1]) as f:
    config = json.load(f)

log_file    = sys.argv[2]
task        = sys.argv[3]
window_h    = float(sys.argv[4])
task_lower  = task.lower()
now         = datetime.now(timezone.utc)

available = [a["name"] for a in config.get("agents", [])]

patterns = {
    "research": ["research", "analys", "investigat", "compet", "find out", "look up", "check if"],
    "code":     ["implement", "build", "create", "add", "fix", "refactor", "write code", "develop"],
    "review":   ["review", "audit", "check", "verify", "security", "lint"],
    "deploy":   ["deploy", "release", "ship", "publish", "push to prod"],
    "qa":       ["test", "qa", "quality", "spec", "coverage", "e2e"],
}

type_prompts = {
    "research": f"Research phase: {task}",
    "code":     f"Implementation: {task}",
    "review":   f"Code review: {task}",
    "qa":       f"Quality assurance and testing: {task}",
    "deploy":   f"Deploy: {task}",
}

# ── Load log entries grouped by agent ─────────────────────────────────────────
all_entries = {}
if os.path.exists(log_file):
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                a = e.get("agent", "")
                if a not in all_entries:
                    all_entries[a] = []
                all_entries[a].append(e)
            except Exception:
                pass

# ── Trust scoring helpers ──────────────────────────────────────────────────────
def _tq(outcome, steers):
    steers = int(steers)
    if outcome == "success":  return max(0.7, 1.0 - 0.15 * steers)
    if outcome == "steered":  return max(0.3, 0.5 - 0.10 * max(0, steers - 1))
    if outcome in ("failure", "timeout"): return 0.0
    return None

def _speed_mult(avg_min):
    if avg_min is None or avg_min <= 5:  return 1.0
    if avg_min <= 15:                    return 0.9
    if avg_min <= 30:                    return 0.75
    return max(0.5, 1.0 - (avg_min - 30) / 120.0)

def compute_trust(entries, wh):
    tw = qw = 0.0
    durs = []
    for e in entries:
        try:
            d = datetime.strptime(e.get("dispatched_at","")[:19],
                                  "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        except Exception:
            continue
        age = (now - d).total_seconds() / 3600.0
        w   = 2.0 if age <= wh else (1.0 if age <= 168 else 0.5)
        q   = _tq(e.get("outcome",""), e.get("steer_count", 0))
        if q is None:
            continue
        tw += w; qw += w * q
        c = e.get("completed_at")
        if c:
            try:
                cd = datetime.strptime(c[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
                dur = (cd - d).total_seconds()
                if 0 <= dur < 86400:
                    durs.append(dur)
            except Exception:
                pass
    if tw == 0:
        return None
    avg_min = (sum(durs) / len(durs)) / 60.0 if durs else None
    return round(min(1.0, (qw / tw) * _speed_mult(avg_min)), 3)

# ── Trust-ranked agent selection ──────────────────────────────────────────────
def best_agent_for_type(task_type):
    """Return agent name with highest trust for the given task type.

    Selection order:
    1. Highest trust score among agents WITH type-specific log data for this task type.
    2. Name-based role match when no agent has type-specific data (e.g. "deployer" for deploy tasks).
    3. Highest overall trust (with 0.8x penalty) when no name match exists.
    4. First available agent as last resort.
    """
    if not available:
        return "coder"

    # Separate agents with type-specific history from those without
    typed_scores = {}
    for name in available:
        entries = all_entries.get(name, [])
        typed   = [e for e in entries
                   if (e.get("task_type") or "general") == task_type]
        if typed:
            s = compute_trust(typed, window_h)
            typed_scores[name] = s if s is not None else 0.0

    # If any agent has type-specific data, pick the highest-scoring one
    if typed_scores:
        return max(typed_scores, key=lambda n: typed_scores[n])

    # No agent has type-specific data: prefer role name match
    role_keyword = task_type.rstrip("ing").rstrip("e")  # code, deploy, review, research, qa
    name_matches = [n for n in available if role_keyword.lower() in n.lower()]
    if name_matches:
        return name_matches[0]

    # Last resort: highest overall trust (with 0.8x penalty for untested type)
    overall_scores = {}
    for name in available:
        s = compute_trust(all_entries.get(name, []), window_h)
        overall_scores[name] = (s if s is not None else 0.0) * 0.8
    if overall_scores:
        return max(overall_scores, key=lambda n: overall_scores[n])

    return available[0]

# ── Detect matched task types ──────────────────────────────────────────────────
matched = {}
for agent_type, keywords in patterns.items():
    for kw in keywords:
        if kw in task_lower:
            matched[agent_type] = True
            break

subtasks = []

if not matched:
    # No patterns matched: dispatch single task to best overall agent
    agent = best_agent_for_type("code")
    trust_val = compute_trust(all_entries.get(agent, []), window_h)
    subtasks.append({
        "agent":  agent,
        "type":   "code",
        "prompt": task,
        "trust":  trust_val,
    })
else:
    for task_type in matched:
        agent     = best_agent_for_type(task_type)
        trust_val = compute_trust(
            [e for e in all_entries.get(agent, [])
             if (e.get("task_type") or "general") == task_type],
            window_h,
        )
        subtasks.append({
            "agent":  agent,
            "type":   task_type,
            "prompt": type_prompts.get(task_type, task),
            "trust":  trust_val,
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

G = "\033[32m"; Y = "\033[33m"; R = "\033[31m"
for i, st in enumerate(subtasks, 1):
    trust = st.get("trust")
    if trust is not None:
        tc = G if trust >= 0.8 else (Y if trust >= 0.6 else R)
        trust_str = f"  {tc}trust:{round(trust*100)}%{N}"
    else:
        trust_str = f"  {D}trust: no data{N}"
    print(f"  {BOLD}{i}.{N} {C}{st['agent']:12}{N}  [{st['type']}]{trust_str}")
    print(f"     {D}{st['prompt'][:100]}{'…' if len(st['prompt']) > 100 else ''}{N}")
    print()

print(f"  {D}{'─' * 40}{N}")
print(f"  {len(subtasks)} subtask(s), agents selected by trust score.")
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
policy = config.get("constitution") or config.get("policy") or {}
if not isinstance(policy, dict):
    policy = {}

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; D = "\033[2m"; C = "\033[36m"; N = "\033[0m"; BOLD = "\033[1m"

results = {}
lock = threading.Lock()

def now_ts():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def policy_guard(agent, task_type, action="parallel"):
    required = bool(policy.get("required", False) or policy.get("strict", False))
    if not required:
        return None
    apply_to = policy.get("applyTo") or policy.get("apply_to") or policy.get("commands") or ["task", "parallel", "steer"]
    if isinstance(apply_to, str):
        apply_to = [part.strip() for part in apply_to.split(",")]
    apply_to = [str(part).strip().lower() for part in apply_to if str(part).strip()]
    if apply_to and action.lower() not in apply_to and "all" not in apply_to:
        return None
    only_agents = policy.get("agents") or []
    if only_agents and agent not in only_agents:
        return f"constitution required but agent '{agent}' is outside constitution scope"
    rules = policy.get("rules") or []
    if isinstance(rules, str):
        rules = [rules]
    rules = [str(r).strip() for r in rules if str(r).strip()]
    prefix = str(policy.get("prefix") or policy.get("prompt") or "").strip()
    if not policy.get("enabled", False):
        return "constitution required but disabled"
    if not rules and not prefix:
        return "constitution required but has no rules"
    return None

def apply_policy(prompt, agent, task_type, action="parallel"):
    if not policy.get("enabled", False):
        return prompt
    only_agents = policy.get("agents") or []
    if only_agents and agent not in only_agents:
        return prompt
    apply_to = policy.get("applyTo") or policy.get("apply_to") or policy.get("commands") or ["task", "parallel", "steer"]
    if isinstance(apply_to, str):
        apply_to = [part.strip() for part in apply_to.split(",")]
    apply_to = [str(part).strip().lower() for part in apply_to if str(part).strip()]
    if apply_to and action.lower() not in apply_to and "all" not in apply_to:
        return prompt
    rules = policy.get("rules") or []
    if isinstance(rules, str):
        rules = [rules]
    rules = [str(r).strip() for r in rules if str(r).strip()]
    prefix = str(policy.get("prefix") or policy.get("prompt") or "Follow the operator constitution before doing this task.").strip()
    title = str(policy.get("title") or "Operator Constitution").strip()
    mode = str(policy.get("mode") or "prepend").strip().lower()
    if not rules and not prefix:
        return prompt
    lines = [title]
    if prefix:
        lines.append(prefix)
    lines.append(f"Agent: {agent}")
    lines.append(f"Task type: {task_type}")
    if rules:
        lines.append("Rules:")
        for i, rule in enumerate(rules, 1):
            lines.append(f"{i}. {rule}")
    block = "\n".join(lines).strip()
    if mode == "append":
        return f"{prompt}\n\n{block}"
    return f"{block}\n\nTask:\n{prompt}"

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

    guard_error = policy_guard(agent_name, task_type, "parallel")
    if guard_error:
        with lock:
            results[agent_name] = {"ok": False, "error": guard_error}
        return

    task_id = str(uuid.uuid4())[:8]
    session_key = f"fleet-{agent_name}"
    dispatched_at = now_ts()
    log_entry(task_id, agent_name, task_type, prompt, dispatched_at)

    dispatch_prompt = apply_policy(prompt, agent_name, task_type)

    payload = json.dumps({
        "model": "openclaw",
        "messages": [{"role": "user", "content": dispatch_prompt}],
    })

    with lock:
        print(f"  {C}→{N} {agent_name:12}  dispatching...  [{task_id}]")

    try:
        r = subprocess.run(
            ["curl", "-s", "--max-time", str(timeout_s),
             f"http://127.0.0.1:{port}/v1/chat/completions",
             "-H", f"Authorization: Bearer {token}",
             "-H", "Content-Type: application/json",
             "-H", f"x-openclaw-session-key: {session_key}",
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
