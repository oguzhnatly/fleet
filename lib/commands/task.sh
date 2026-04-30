#!/bin/bash
# fleet task: Dispatch a task to a named agent via its gateway
# Usage: fleet task <agent> "<prompt>" [--type code|review|research|deploy|qa] [--timeout 30] [--no-wait]

# ── Infer task type from prompt keywords ──────────────────────────────────────
_infer_task_type() {
    local prompt="${1,,}"  # lowercase
    case "$prompt" in
        *deploy*|*release*|*ship*|*publish*|*railway*|*cloudflare*) echo "deploy" ;;
        *test*|*qa*|*quality*|*spec*|*coverage*)                    echo "qa" ;;
        *review*|*audit*|*check*|*security*)                        echo "review" ;;
        *research*|*analys*|*investigat*|*compet*|*search*)         echo "research" ;;
        *code*|*implement*|*build*|*fix*|*refactor*|*write*|*add*)  echo "code" ;;
        *)                                                           echo "code" ;;
    esac
}

# ── Lookup agent config by name ───────────────────────────────────────────────
_agent_config() {
    local name="$1" field="$2"
    python3 - "$FLEET_CONFIG_PATH" "$name" "$field" <<'PY'
import json, sys

with open(sys.argv[1]) as f:
    c = json.load(f)

name  = sys.argv[2]
field = sys.argv[3]

for agent in c.get("agents", []):
    if agent.get("name") == name:
        print(agent.get(field, ""))
        sys.exit(0)

# Check gateway too (coordinator)
gw = c.get("gateway", {})
if gw.get("name") == name:
    print(gw.get(field, ""))
    sys.exit(0)

print("")
PY
}

cmd_task() {
    # ── Parse args ─────────────────────────────────────────────────────────
    local agent="" prompt="" task_type="" timeout_min=30 no_wait=false

    if [[ $# -lt 2 ]]; then
        echo "  Usage: fleet task <agent> \"<prompt>\" [--type code|review|research|deploy|qa] [--timeout <minutes>] [--no-wait]"
        echo "  Example: fleet task coder \"add pagination to /api/spots, tests required\""
        return 1
    fi

    agent="$1"; shift
    prompt="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type|-t)    task_type="${2:-}"; shift 2 ;;
            --timeout)    timeout_min="${2:-30}"; shift 2 ;;
            --no-wait)    no_wait=true; shift ;;
            *) shift ;;
        esac
    done

    # ── Validate agent exists in config ────────────────────────────────────
    local port token
    port="$(_agent_config "$agent" "port")"
    token="$(_agent_config "$agent" "token")"

    if [ -z "$port" ]; then
        out_fail "Agent '$agent' not found in fleet config."
        echo "  Run 'fleet agents' to see configured agents."
        return 1
    fi

    # ── Infer task type if not specified ───────────────────────────────────
    if [ -z "$task_type" ]; then
        task_type="$(_infer_task_type "$prompt")"
    fi

    # ── Apply optional operator constitution ────────────────────────────────
    local dispatch_prompt
    dispatch_prompt="$(fleet_policy_apply "$prompt" "$agent" "$task_type")"

    # ── Log dispatch ────────────────────────────────────────────────────────
    local task_id
    task_id="$(fleet_log_dispatch "$agent" "$task_type" "$prompt")"

    out_header "Fleet Task"
    out_kv "Agent"     "$agent (port $port)"
    out_kv "Type"      "$task_type"
    out_kv "Task ID"   "$task_id"
    out_kv "Timeout"   "${timeout_min}m"
    echo ""
    echo -e "  ${CLR_DIM}${prompt}${CLR_RESET}"
    echo ""

    if [ "$no_wait" = "true" ]; then
        # Fire and forget: dispatch without waiting for response
        python3 -u - "$port" "$token" "$dispatch_prompt" "$agent" <<'PY'
import subprocess, sys, json

port, token, prompt, agent = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
session_key = f"fleet-{agent}"

payload = json.dumps({
    "model": "openclaw",
    "messages": [{"role": "user", "content": prompt}],
})

subprocess.Popen(
    ["curl", "-s", "-o", "/dev/null",
     f"http://127.0.0.1:{port}/v1/chat/completions",
     "-H", f"Authorization: Bearer {token}",
     "-H", "Content-Type: application/json",
     "-H", f"x-openclaw-session-key: {session_key}",
     "-d", payload],
    close_fds=True
)
print("dispatched")
PY
        out_ok "Dispatched (no-wait). Track with: fleet log --agent $agent"
        return 0
    fi

    # ── Stream response ─────────────────────────────────────────────────────
    local outcome="success"
    echo -e "  ${CLR_DIM}────────────────────────────────────────${CLR_RESET}"

    python3 -u - "$port" "$token" "$dispatch_prompt" "$agent" "$timeout_min" <<'PY'
import subprocess, sys, json, signal, time

port       = sys.argv[1]
token      = sys.argv[2]
prompt     = sys.argv[3]
agent      = sys.argv[4]
timeout_s  = int(sys.argv[5]) * 60
session_key = f"fleet-{agent}"

G = "\033[32m"; R = "\033[31m"; D = "\033[2m"; N = "\033[0m"; BOLD = "\033[1m"

payload = json.dumps({
    "model": "openclaw",
    "stream": True,
    "messages": [{"role": "user", "content": prompt}],
})

cmd = [
    "curl", "-sN", "--max-time", str(timeout_s),
    f"http://127.0.0.1:{port}/v1/chat/completions",
    "-H", f"Authorization: Bearer {token}",
    "-H", "Content-Type: application/json",
    "-H", f"x-openclaw-session-key: {session_key}",
    "-d", payload,
]

try:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    buffer = ""
    had_output = False

    for line in proc.stdout:
        line = line.strip()
        if not line or line == "data: [DONE]":
            if line == "data: [DONE]":
                break
            continue
        if line.startswith("data: "):
            try:
                chunk = json.loads(line[6:])
                delta = chunk.get("choices", [{}])[0].get("delta", {})
                content = delta.get("content", "")
                if content:
                    print(f"  {content}", end="", flush=True)
                    had_output = True
            except Exception:
                pass

    proc.wait()

    if had_output:
        print("")  # newline after streamed content

    if proc.returncode != 0:
        print(f"\n  {R}Task failed or timed out.{N}", file=sys.stderr)
        sys.exit(1)

except KeyboardInterrupt:
    print(f"\n  {D}Interrupted.{N}")
    sys.exit(2)
PY

    local exit_code=$?
    echo -e "  ${CLR_DIM}────────────────────────────────────────${CLR_RESET}"

    if [ $exit_code -eq 0 ]; then
        outcome="success"
        out_ok "Task complete  (${task_id})"
    elif [ $exit_code -eq 2 ]; then
        outcome="failure"
        out_warn "Task interrupted  (${task_id})"
    else
        outcome="timeout"
        out_fail "Task timed out after ${timeout_min}m  (${task_id})"
    fi

    # ── Log outcome ─────────────────────────────────────────────────────────
    fleet_log_complete "$task_id" "$outcome"
}
