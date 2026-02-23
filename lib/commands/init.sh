#!/usr/bin/env bash
# fleet init — Interactive configuration setup with auto-PATH

cmd_init() {
    out_header "Fleet Setup"

    local config_dir
    config_dir=$(dirname "$FLEET_CONFIG_PATH")

    # ── Step 1: Ensure fleet is in PATH ─────────────────────────────────────
    _ensure_path

    # ── Step 2: Create config ───────────────────────────────────────────────
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
import json, sys, os, subprocess

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

G = "\033[32m"; D = "\033[2m"; N = "\033[0m"

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

# ── PATH helper ─────────────────────────────────────────────────────────────
_ensure_path() {
    local bin_dir="$HOME/.local/bin"
    local fleet_bin="$FLEET_ROOT/bin/fleet"

    # Create ~/.local/bin if it doesn't exist
    mkdir -p "$bin_dir"

    # Symlink fleet into ~/.local/bin
    if [ ! -L "$bin_dir/fleet" ] && [ ! -f "$bin_dir/fleet" ]; then
        ln -sf "$fleet_bin" "$bin_dir/fleet"
        out_ok "Linked fleet to $bin_dir/fleet"
    elif [ -L "$bin_dir/fleet" ]; then
        # Update existing symlink
        ln -sf "$fleet_bin" "$bin_dir/fleet"
        out_ok "Updated fleet symlink in $bin_dir/"
    fi

    # Check if ~/.local/bin is in PATH
    if echo "$PATH" | tr ':' '\n' | grep -q "^$bin_dir$"; then
        out_ok "$bin_dir is in PATH"
        return
    fi

    # Add to PATH in shell rc files
    local added=false
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$rc" ]; then
            if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
                echo '' >> "$rc"
                echo '# Added by fleet — https://github.com/oguzhnatly/fleet' >> "$rc"
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
                out_ok "Added $bin_dir to PATH in $(basename "$rc")"
                added=true
            else
                out_ok "$bin_dir already in $(basename "$rc")"
                added=true
            fi
        fi
    done

    if [ "$added" = true ]; then
        # Export for current session too
        export PATH="$bin_dir:$PATH"
        out_info "PATH updated for current session"
    else
        out_warn "Could not find shell rc file. Add manually:"
        echo '       export PATH="$HOME/.local/bin:$PATH"'
    fi
}
