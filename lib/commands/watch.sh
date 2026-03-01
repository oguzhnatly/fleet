#!/bin/bash
# fleet watch · Live session tail for a named agent
# Polls the agent gateway session history and shows new messages as they arrive
# Usage: fleet watch <agent> [--interval <seconds>]

cmd_watch() {
    local agent="" interval=3

    if [[ $# -lt 1 ]]; then
        echo "  Usage: fleet watch <agent> [--interval <seconds>]"
        echo "  Example: fleet watch coder"
        return 1
    fi

    agent="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval|-i) interval="${2:-3}"; shift 2 ;;
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

    out_header "Watching $agent"
    echo -e "  ${CLR_DIM}Polling session every ${interval}s. Press Ctrl+C to stop.${CLR_RESET}"
    echo ""

    python3 - "$port" "$token" "$agent" "$interval" <<'PY'
import subprocess, sys, json, time, signal

port       = sys.argv[1]
token      = sys.argv[2]
agent      = sys.argv[3]
interval   = float(sys.argv[4])
session_key = f"fleet-{agent}"

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; D = "\033[2m"
BOLD = "\033[1m"; C = "\033[36m"; N = "\033[0m"

seen_ids = set()

def fetch_history(limit=30):
    payload = json.dumps({
        "tool": "sessions_history",
        "args": {"sessionKey": session_key, "limit": limit},
    })
    try:
        r = subprocess.run(
            ["curl", "-s", "--max-time", "5",
             f"http://127.0.0.1:{port}/tools/invoke",
             "-H", f"Authorization: Bearer {token}",
             "-H", "Content-Type: application/json",
             "-d", payload],
            capture_output=True, text=True
        )
        data = json.loads(r.stdout)
        if data.get("ok"):
            return data.get("result", {}).get("messages", [])
    except Exception:
        pass
    return []

def print_message(msg):
    role    = msg.get("role", "?")
    content = msg.get("content", "")
    ts      = msg.get("timestamp", "")[:16].replace("T", " ")

    if isinstance(content, list):
        content = " ".join(
            block.get("text", "") for block in content
            if isinstance(block, dict) and block.get("type") == "text"
        )

    if role == "user":
        color = C
        label = "you"
    elif role == "assistant":
        color = G
        label = agent
    else:
        color = D
        label = role

    preview = str(content).strip()[:200]
    if len(str(content).strip()) > 200:
        preview += "…"

    print(f"  {color}{BOLD}{label:12}{N}  {D}{ts}{N}")
    for line in preview.splitlines():
        print(f"  {line}")
    print()

print(f"  {D}Connecting to {agent} session...{N}")

# Initial load
messages = fetch_history(20)
if not messages:
    print(f"  {D}No messages yet. Waiting for activity...{N}")
else:
    print(f"  {D}Last {len(messages)} message(s):{N}\n")
    for m in messages:
        mid = id(m)
        seen_ids.add(mid)
        print_message(m)

# Poll loop
try:
    while True:
        time.sleep(interval)
        fresh = fetch_history(30)
        new_msgs = [m for m in fresh if id(m) not in seen_ids]
        for m in new_msgs:
            seen_ids.add(id(m))
            print_message(m)
except KeyboardInterrupt:
    print(f"\n  {D}Watch stopped.{N}")
PY
}
