#!/bin/bash
# fleet kill: Send a graceful stop signal to an agent session
# Sends a termination message to the agent's fleet session
# Usage: fleet kill <agent> [--force]

cmd_kill() {
    if [[ $# -lt 1 ]]; then
        echo "  Usage: fleet kill <agent> [--force]"
        echo "  Example: fleet kill coder"
        return 1
    fi

    local agent="$1" force=false
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force=true; shift ;;
            *) shift ;;
        esac
    done

    local port token
    port="$(_agent_config "$agent" "port")"
    token="$(_agent_config "$agent" "token")"

    if [ -z "$port" ]; then
        out_fail "Agent '$agent' not found in fleet config."
        return 1
    fi

    # First verify the agent is online
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 \
        "http://127.0.0.1:${port}/health" 2>/dev/null)

    if [ "$http_code" != "200" ]; then
        out_warn "Agent '$agent' appears offline (port $port). Nothing to kill."
        return 0
    fi

    out_header "Fleet Kill"
    out_kv "Agent"   "$agent"
    out_kv "Session" "fleet-$agent"
    if [ "$force" = "true" ]; then
        out_kv "Mode" "force"
    fi
    echo ""

    local stop_message="[FLEET KILL] Stop current task. Archive this session. Confirm with: STOPPED."
    if [ "$force" = "true" ]; then
        stop_message="[FLEET KILL FORCE] Immediately stop all activity. Do not complete current task. Archive session now. Confirm with: FORCE STOPPED."
    fi

    python3 -u - "$port" "$token" "$stop_message" "$agent" <<'PY'
import subprocess, sys, json, time

port, token, message, agent = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
session_key = f"fleet-{agent}"

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; D = "\033[2m"; N = "\033[0m"

payload = json.dumps({
    "model": "openclaw",
    "stream": True,
    "messages": [{"role": "user", "content": message}],
    "max_tokens": 100,
})

cmd = [
    "curl", "-sN", "--max-time", "30",
    f"http://127.0.0.1:{port}/v1/chat/completions",
    "-H", f"Authorization: Bearer {token}",
    "-H", "Content-Type: application/json",
    "-H", f"x-openclaw-session-key: {session_key}",
    "-d", payload,
]

try:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    response = ""

    for line in proc.stdout:
        line = line.strip()
        if line == "data: [DONE]":
            break
        if line.startswith("data: "):
            try:
                chunk = json.loads(line[6:])
                content = chunk.get("choices", [{}])[0].get("delta", {}).get("content", "")
                response += content
            except Exception:
                pass

    proc.wait()

    if "STOPPED" in response.upper() or "STOP" in response.upper():
        print(f"  {G}✅{N} Agent {agent} acknowledged stop signal.")
    else:
        print(f"  {Y}⚠️ {N}  Stop signal sent. Agent response: {response[:100].strip() or 'no response'}")

except KeyboardInterrupt:
    print(f"\n  {D}Interrupted.{N}")
PY

    # Mark any pending tasks for this agent as steered/stopped in the log
    python3 - "$FLEET_LOG_FILE" "$agent" <<'PY'
import json, sys, os
from datetime import datetime, timezone

log_file = sys.argv[1]
agent = sys.argv[2]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if not os.path.exists(log_file):
    sys.exit(0)

entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get("agent") == agent and entry.get("outcome") == "pending":
                entry["outcome"] = "steered"
                entry["completed_at"] = now
            entries.append(entry)
        except Exception:
            entries.append(line)

with open(log_file, "w") as f:
    for item in entries:
        if isinstance(item, dict):
            f.write(json.dumps(item) + "\n")
        else:
            f.write(item + "\n")
PY

    out_ok "Kill signal sent to $agent."
}
