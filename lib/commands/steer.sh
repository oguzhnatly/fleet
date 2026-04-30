#!/bin/bash
# fleet steer: Send a mid-session correction to a running agent
# Sends to the same fleet session as fleet task (stable session key: fleet-<agent>)
# Usage: fleet steer <agent> "<message>"

cmd_steer() {
    if [[ $# -lt 2 ]]; then
        echo "  Usage: fleet steer <agent> \"<message>\""
        echo "  Example: fleet steer coder \"also add rate limiting to that endpoint\""
        return 1
    fi

    local agent="$1" message="$2"

    local port token
    port="$(_agent_config "$agent" "port")"
    token="$(_agent_config "$agent" "token")"

    if [ -z "$port" ]; then
        out_fail "Agent '$agent' not found in fleet config."
        return 1
    fi

    local policy_guard dispatch_message
    policy_guard="$(fleet_policy_guard "$agent" "steer" "steer")"
    if [ "$policy_guard" != "ok" ]; then
        out_fail "$policy_guard"
        echo "       Run: fleet policy"
        return 1
    fi
    dispatch_message="$(fleet_policy_apply "$message" "$agent" "steer" "steer")"

    out_header "Fleet Steer"
    out_kv "Agent"   "$agent"
    out_kv "Session" "fleet-$agent"
    echo ""
    echo -e "  ${CLR_DIM}${message}${CLR_RESET}"
    echo ""

    # Increment steer count in log for this agent's last pending task
    fleet_log_steer "$agent"

    # Send to the same session used by fleet task
    python3 -u - "$port" "$token" "$dispatch_message" "$agent" <<'PY'
import subprocess, sys, json

port, token, message, agent = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
session_key = f"fleet-{agent}"

G = "\033[32m"; R = "\033[31m"; D = "\033[2m"; N = "\033[0m"

payload = json.dumps({
    "model": "openclaw",
    "stream": True,
    "messages": [{"role": "user", "content": message}],
})

cmd = [
    "curl", "-sN", "--max-time", "1800",
    f"http://127.0.0.1:{port}/v1/chat/completions",
    "-H", f"Authorization: Bearer {token}",
    "-H", "Content-Type: application/json",
    "-H", f"x-openclaw-session-key: {session_key}",
    "-d", payload,
]

try:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    print(f"  {D}────────────────────────────────────────{N}")
    had_output = False

    for line in proc.stdout:
        line = line.strip()
        if line == "data: [DONE]":
            break
        if line.startswith("data: "):
            try:
                chunk = json.loads(line[6:])
                content = chunk.get("choices", [{}])[0].get("delta", {}).get("content", "")
                if content:
                    print(f"  {content}", end="", flush=True)
                    had_output = True
            except Exception:
                pass

    proc.wait()
    if had_output:
        print("")
    print(f"  {D}────────────────────────────────────────{N}")
    print(f"  {G}✅{N} Steered.")

except KeyboardInterrupt:
    print(f"\n  {D}Interrupted.{N}")
    sys.exit(1)
PY
}
