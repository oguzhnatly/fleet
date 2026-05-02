#!/usr/bin/env bash
# fleet init: configuration setup with explicit local writes

cmd_init() {
    local link_bin=false write_path=false assume_yes=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --link) link_bin=true; shift ;;
            --path) link_bin=true; write_path=true; shift ;;
            --yes|-y) assume_yes=true; shift ;;
            --help|-h)
                cat <<'HELP'
  Usage: fleet init [--link] [--path] [--yes]

  By default, fleet init creates ~/.fleet/config.json only.
  --link creates ~/.local/bin/fleet.
  --path may append ~/.local/bin to shell rc files after confirmation.
HELP
                return 0 ;;
            *) shift ;;
        esac
    done

    out_header "Fleet Setup"

    local config_dir
    config_dir=$(dirname "$FLEET_CONFIG_PATH")

    # Optional PATH setup. No shell rc files are modified unless --path is used.
    if [ "$link_bin" = "true" ]; then
        _ensure_path "$write_path" "$assume_yes"
    else
        out_dim "Skipping PATH writes. Run fleet init --link to create ~/.local/bin/fleet."
    fi

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
    chmod 700 "$config_dir" 2>/dev/null || true

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
        detected_workspace=$(python3 - "$HOME/.openclaw/openclaw.json" <<'PY_WORKSPACE' 2>/dev/null
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print(c.get('workspace', ''))
PY_WORKSPACE
)
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

# Scan for employee gateways
scanned = []
gw = int(detected_port)
scan_ports = set()
for p in range(gw + 20, gw + 220, 20):
    scan_ports.add(p)
for p in range(48400, 48700, 10):
    if p != gw:
        scan_ports.add(p)

for port in sorted(scan_ports):
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
        "tokenEnv": f"FLEET_AGENT_{port}_TOKEN"
    })

config_path = os.path.join(config_dir, "config.json")
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

os.chmod(config_path, 0o600)

print(f"\n  Config written to: {config_path}")
print(f"  {D}Permissions set to 600. Agent auth should use tokenEnv when possible.{N}")
print(f"\n  {D}Set token env vars or edit the config before dispatching tasks.{N}")
print(f"  {D}Then run: fleet health{N}")
INIT_PY

    echo ""
    out_ok "Fleet initialized"
}

_ensure_path() {
    local write_path="${1:-false}"
    local assume_yes="${2:-false}"
    local bin_dir="$HOME/.local/bin"
    local fleet_bin="$FLEET_ROOT/bin/fleet"

    mkdir -p "$bin_dir"
    chmod 700 "$bin_dir" 2>/dev/null || true

    if [ ! -L "$bin_dir/fleet" ] && [ ! -f "$bin_dir/fleet" ]; then
        ln -sf "$fleet_bin" "$bin_dir/fleet"
        out_ok "Linked fleet to $bin_dir/fleet"
    elif [ -L "$bin_dir/fleet" ]; then
        ln -sf "$fleet_bin" "$bin_dir/fleet"
        out_ok "Updated fleet symlink in $bin_dir/"
    else
        out_warn "$bin_dir/fleet exists and is not a symlink. Leaving it unchanged."
    fi

    if echo "$PATH" | tr ':' '\n' | grep -q "^$bin_dir$"; then
        out_ok "$bin_dir is in PATH"
        return
    fi

    if [ "$write_path" != "true" ]; then
        out_info "Add this to your shell if needed:"
        printf '%s\n' "       export PATH=\"\$HOME/.local/bin:\$PATH\""
        return
    fi

    fleet_confirm_action "append ~/.local/bin to shell rc files" "Files checked: ~/.bashrc, ~/.zshrc, ~/.profile" "$assume_yes" || return 1

    local added=false
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$rc" ]; then
            if ! grep -q '\.local/bin' "$rc" 2>/dev/null; then
                {
                    printf '\n'
                    printf '%s\n' '# Added by fleet: https://github.com/oguzhnatly/fleet'
                    printf '%s\n' "export PATH=\"\$HOME/.local/bin:\$PATH\""
                } >> "$rc"
                out_ok "Added $bin_dir to PATH in $(basename "$rc")"
                added=true
            else
                out_ok "$bin_dir already in $(basename "$rc")"
                added=true
            fi
        fi
    done

    if [ "$added" = true ]; then
        export PATH="$bin_dir:$PATH"
        out_info "PATH updated for current session"
    else
        out_warn "Could not find shell rc file. Add manually:"
        printf '%s\n' "       export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}
