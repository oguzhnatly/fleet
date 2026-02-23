#!/bin/bash
# fleet init — Interactive configuration setup

cmd_init() {
    out_header "Fleet Setup"

    local config_dir
    config_dir=$(dirname "$FLEET_CONFIG_PATH")

    if [ -f "$FLEET_CONFIG_PATH" ]; then
        out_warn "Config already exists at $FLEET_CONFIG_PATH"
        echo ""
        echo "  To reconfigure, delete it first:"
        echo "  rm $FLEET_CONFIG_PATH"
        echo ""
        echo "  Or edit directly:"
        echo "  \$EDITOR $FLEET_CONFIG_PATH"
        return
    fi

    echo "  Creating fleet configuration..."
    echo ""

    mkdir -p "$config_dir"

    # Auto-detect OpenClaw gateway
    local detected_port=""
    for port in 48391 3000 8080; do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "http://127.0.0.1:$port/health" 2>/dev/null)
        if [ "$code" = "200" ]; then
            detected_port=$port
            break
        fi
    done

    # Auto-detect workspace
    local detected_workspace=""
    if [ -f "$HOME/.openclaw/openclaw.json" ]; then
        detected_workspace=$(python3 -c "
import json
with open('$HOME/.openclaw/openclaw.json') as f:
    c = json.load(f)
print(c.get('workspace', ''))
" 2>/dev/null)
    fi

    # Build config
    python3 - "$config_dir" "$detected_port" "$detected_workspace" <<'INIT_PY'
import json, sys, os

config_dir = sys.argv[1]
detected_port = sys.argv[2] or "48391"
detected_workspace = sys.argv[3] or os.path.expanduser("~")

config = {
    "workspace": detected_workspace,
    "gateway": {
        "port": int(detected_port),
        "name": "coordinator",
        "role": "coordinator",
        "model": "default"
    },
    "agents": [],
    "endpoints": [],
    "repos": [],
    "services": [],
    "linear": {
        "teams": [],
        "apiKeyEnv": "LINEAR_API_KEY"
    }
}

# Auto-detect additional gateways
G = "\033[32m"; D = "\033[2m"; N = "\033[0m"
import subprocess

print(f"  {G}✅{N} Main gateway detected on :{detected_port}")
if detected_workspace:
    print(f"  {G}✅{N} Workspace: {detected_workspace}")

# Scan common employee ports
scanned = []
for port in range(int(detected_port) + 20, int(detected_port) + 200, 20):
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "1", f"http://127.0.0.1:{port}/health"],
            capture_output=True, text=True
        )
        if r.stdout.strip() in ("200", "401"):
            scanned.append(port)
            print(f"  {G}✅{N} Agent gateway found on :{port}")
    except Exception:
        pass

for port in scanned:
    config["agents"].append({
        "name": f"agent-{port}",
        "port": port,
        "role": "employee",
        "model": "default",
        "token": ""
    })

config_path = os.path.join(config_dir, "config.json")
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print(f"\n  Config written to: {config_path}")
print(f"\n  {D}Edit it to add agent names, tokens, repos, and endpoints.{N}")
print(f"  {D}Then run: fleet health{N}")
INIT_PY

    echo ""
    out_ok "Fleet initialized"
}
