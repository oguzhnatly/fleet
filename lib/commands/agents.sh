#!/bin/bash
# fleet agents — Show all configured agent gateways with health status

cmd_agents() {
    out_header "Agent Fleet"

    if ! fleet_has_config; then
        echo "  No config found. Run: fleet init"
        return 1
    fi

    python3 - "$FLEET_CONFIG_PATH" <<'AGENTS_PY'
import json, subprocess, sys, time

with open(sys.argv[1]) as f:
    config = json.load(f)

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; D = "\033[2m"; N = "\033[0m"

# Main gateway
gw = config.get("gateway", {})
port = gw.get("port", 48391)
name = gw.get("name", "coordinator")
role = gw.get("role", "coordinator")
model = gw.get("model", "default")

try:
    start = time.time()
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "--max-time", "3", f"http://127.0.0.1:{port}/health"],
        capture_output=True, text=True
    )
    code = r.stdout.strip()
    ms = int((time.time() - start) * 1000)
    status = f"{G}online{N}" if code == "200" else f"{R}offline{N}"
except Exception:
    status = f"{R}error{N}"
    ms = 0

print(f"  {G}⬢{N} {name:16} {role:16} {model:30} :{port:<6} {status} {D}{ms}ms{N}")

# Agent fleet
agents = config.get("agents", [])
if not agents:
    print(f"\n  {D}No additional agents configured.{N}")
    sys.exit(0)

print()

for agent in agents:
    aname = agent.get("name", "?")
    aport = agent.get("port", 0)
    arole = agent.get("role", aname)
    amodel = agent.get("model", "default")
    atoken = agent.get("token", "")

    try:
        start = time.time()

        # Try /health first
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "3", f"http://127.0.0.1:{aport}/health"],
            capture_output=True, text=True
        )
        code = r.stdout.strip()

        # If health doesn't work, try authenticated endpoint
        if code != "200" and atoken:
            r = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "--max-time", "3", "-H", f"Authorization: Bearer {atoken}",
                 f"http://127.0.0.1:{aport}/v1/models"],
                capture_output=True, text=True
            )
            code = r.stdout.strip()

        ms = int((time.time() - start) * 1000)

        if code == "200":
            status = f"{G}online{N}"
            icon = f"{G}⬢{N}"
        elif code == "000":
            status = f"{R}unreachable{N}"
            icon = f"{R}⬡{N}"
        elif code == "401":
            status = f"{Y}auth failed{N}"
            icon = f"{Y}⬡{N}"
        else:
            status = f"{R}HTTP {code}{N}"
            icon = f"{R}⬡{N}"
    except Exception:
        status = f"{R}error{N}"
        icon = f"{R}⬡{N}"
        ms = 0

    print(f"  {icon} {aname:16} {arole:16} {amodel:30} :{aport:<6} {status} {D}{ms}ms{N}")
AGENTS_PY
}
