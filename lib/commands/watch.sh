#!/bin/bash
# fleet watch · Live session tail for a named agent
# Reads directly from the agent's JSONL session transcript on disk
# Usage: fleet watch <agent> [--interval <seconds>] [--all]

# ── Resolve the profile directory for a named agent ─────────────────────────
_agent_profile_dir() {
    local agent="$1"
    local role
    role="$(_agent_config "$agent" "role")"
    if [ "$role" = "coordinator" ]; then
        echo "$HOME/.openclaw"
    else
        echo "$HOME/.openclaw-${agent}"
    fi
}

# ── Resolve JSONL path for a session key in an agent profile dir ─────────────
# Returns: <path_to_jsonl> or ""
_resolve_session_jsonl() {
    local profile_dir="$1" session_key="$2"
    python3 -c "
import json, sys, os

profile_dir = sys.argv[1]
target_key  = sys.argv[2]

sessions_path = os.path.join(profile_dir, 'agents', 'main', 'sessions', 'sessions.json')
sessions_dir  = os.path.join(profile_dir, 'agents', 'main', 'sessions')

if not os.path.exists(sessions_path):
    sys.exit(0)

with open(sessions_path) as f:
    sessions = json.load(f)

entry = sessions.get(target_key)
if not entry:
    sys.exit(0)

session_id = entry.get('sessionId', '')
if not session_id:
    sys.exit(0)

jsonl_path = os.path.join(sessions_dir, session_id + '.jsonl')
if os.path.exists(jsonl_path):
    print(jsonl_path)
" "$profile_dir" "$session_key" 2>/dev/null
}

cmd_watch() {
    local agent="" interval=3 show_all=false

    if [[ $# -lt 1 ]]; then
        echo "  Usage: fleet watch <agent> [--interval <seconds>] [--all]"
        echo "  Example: fleet watch coordinator"
        echo "  Example: fleet watch coder"
        return 1
    fi

    agent="$1"; shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval|-i) interval="${2:-3}"; shift 2 ;;
            --all)         show_all=true; shift ;;
            *) shift ;;
        esac
    done

    local role profile_dir session_key jsonl_path
    role="$(_agent_config "$agent" "role")"
    profile_dir="$(_agent_profile_dir "$agent")"

    if [ -z "$(_agent_config "$agent" "port")" ]; then
        out_fail "Agent '$agent' not found in fleet config."
        return 1
    fi

    if [ ! -d "$profile_dir" ]; then
        out_fail "Agent profile not found: $profile_dir"
        echo "  Agent may not be installed or using a different profile path."
        return 1
    fi

    # ── Determine which session to watch ──────────────────────────────────
    # Coordinator: always agent:main:main
    # Employees: fleet session (agent:main:fleet-<agent>) by default
    #            --all: override to full main session (agent:main:main)
    if [ "$role" = "coordinator" ] || [ "$show_all" = "true" ]; then
        session_key="agent:main:main"
        jsonl_path="$(_resolve_session_jsonl "$profile_dir" "$session_key")"
    else
        session_key="agent:main:fleet-${agent}"
        jsonl_path="$(_resolve_session_jsonl "$profile_dir" "$session_key")"
    fi

    out_header "Watching $agent"

    if [ -z "$jsonl_path" ]; then
        if [ "$role" = "coordinator" ]; then
            out_fail "No session found for coordinator at $profile_dir"
        else
            out_dim "No fleet session yet for $agent."
            echo -e "  Run: fleet task $agent \"<prompt>\" to start one."
            echo -e "  Run: fleet watch $agent --all  to watch the agent's full session history."
        fi
        return 0
    fi

    echo -e "  ${CLR_DIM}Session: ${session_key}${CLR_RESET}"
    echo -e "  ${CLR_DIM}File: $(basename "$jsonl_path") · polling every ${interval}s · Ctrl+C to stop${CLR_RESET}"
    echo ""

    python3 -u - "$jsonl_path" "$interval" "$agent" "$role" <<'PY'
import sys, json, time, os
from datetime import datetime, timezone

jsonl_path  = sys.argv[1]
interval    = float(sys.argv[2])
agent       = sys.argv[3]
role        = sys.argv[4]

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; D = "\033[2m"
BOLD = "\033[1m"; C = "\033[36m"; N = "\033[0m"

def fmt_ts(ts):
    """Convert ISO string or int ms epoch to HH:MM UTC."""
    if isinstance(ts, (int, float)):
        dt = datetime.fromtimestamp(ts / 1000, tz=timezone.utc)
        return dt.strftime("%H:%M UTC")
    if isinstance(ts, str) and ts:
        return ts[11:16] + " UTC"
    return ""

def extract_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") == "text":
                parts.append(block.get("text", ""))
        return "\n".join(p for p in parts if p)
    return str(content)

def print_message(entry):
    msg  = entry.get("message", {})
    role_name = msg.get("role", "?")
    ts   = fmt_ts(entry.get("timestamp", msg.get("timestamp", "")))
    text = extract_text(msg.get("content", ""))
    if not text.strip():
        return

    if role_name == "user":
        color = C
        label = "you"
    elif role_name in ("assistant",):
        color = G
        label = agent
    elif role_name == "toolResult":
        color = D
        label = "tool"
    else:
        color = D
        label = role_name

    preview = text.strip()[:300]
    if len(text.strip()) > 300:
        preview += "…"

    print(f"  {color}{BOLD}{label:14}{N}  {D}{ts}{N}")
    for line in preview.splitlines():
        print(f"  {line}")
    print()

# ── Read existing messages up to a point ─────────────────────────────────────
def read_entries(start_byte=0):
    entries = []
    try:
        with open(jsonl_path, "rb") as f:
            f.seek(start_byte)
            data = f.read()
            end_byte = start_byte + len(data)
        for line in data.decode("utf-8", errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except Exception:
                pass
    except FileNotFoundError:
        end_byte = start_byte
    return entries, end_byte

# Initial load: show last N messages
MAX_INITIAL = 12
all_entries, file_pos = read_entries(0)
msg_entries = [e for e in all_entries if e.get("type") == "message"]

if not msg_entries:
    print(f"  {D}No messages yet. Waiting for activity...{N}")
else:
    to_show = msg_entries[-MAX_INITIAL:]
    print(f"  {D}Last {len(to_show)} message(s):{N}\n")
    for e in to_show:
        print_message(e)

# Poll loop: tail new entries by seeking to end of last known position
try:
    while True:
        time.sleep(interval)
        new_entries, file_pos = read_entries(file_pos)
        new_msgs = [e for e in new_entries if e.get("type") == "message"]
        for e in new_msgs:
            print_message(e)
except KeyboardInterrupt:
    print(f"\n  {D}Watch stopped.{N}")
PY
}
