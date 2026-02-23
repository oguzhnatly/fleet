#!/bin/bash
# fleet sitrep — Structured status report with delta tracking

cmd_sitrep() {
    local hours="${1:-4}"

    python3 - "$FLEET_CONFIG_PATH" "$FLEET_STATE_DIR" "$hours" <<'SITREP_PY'
import json, subprocess, sys, os, time
from datetime import datetime, timezone

config_path = sys.argv[1]
state_dir = sys.argv[2]
hours = sys.argv[3]

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; B = "\033[34m"
D = "\033[2m"; BOLD = "\033[1m"; N = "\033[0m"

# Load config
config = {}
if os.path.exists(config_path):
    with open(config_path) as f:
        config = json.load(f)

now = datetime.now(timezone.utc)
timestamp = now.strftime("%Y-%m-%dT%H:%M:%SZ")
display_time = now.strftime("%Y-%m-%d %H:%M UTC")

# ── Collect data ────────────────────────────────────────────────────────────

# CI status
ci = {}
for repo_conf in config.get("repos", []):
    name = repo_conf.get("name", repo_conf.get("repo", "?"))
    repo = repo_conf.get("repo", "")
    if not repo:
        continue
    try:
        r = subprocess.run(
            ["gh", "run", "list", "--repo", repo, "--limit", "1",
             "--json", "conclusion,status"],
            capture_output=True, text=True, timeout=15
        )
        runs = json.loads(r.stdout) if r.stdout.strip() else []
        if not runs:
            ci[name] = "no_runs"
        else:
            run = runs[0]
            s = run.get("status", "")
            c = run.get("conclusion", "")
            if s in ("in_progress", "queued"):
                ci[name] = "running"
            elif c == "success":
                ci[name] = "green"
            elif c == "failure":
                ci[name] = "RED"
            else:
                ci[name] = c or s or "unknown"
    except Exception:
        ci[name] = "error"

# Endpoint checks
endpoints = {}
for ep in config.get("endpoints", []):
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", str(ep.get("timeout", 6)), ep["url"]],
            capture_output=True, text=True
        )
        endpoints[ep.get("name", ep["url"])] = r.stdout.strip()
    except Exception:
        endpoints[ep.get("name", "?")] = "error"

# Agent health
agents = {}
gw = config.get("gateway", {})
gw_port = gw.get("port", 48391)
try:
    r = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
         "--max-time", "3", f"http://127.0.0.1:{gw_port}/health"],
        capture_output=True, text=True
    )
    agents[gw.get("name", "coordinator")] = "online" if r.stdout.strip() == "200" else "offline"
except Exception:
    agents[gw.get("name", "coordinator")] = "error"

for agent in config.get("agents", []):
    port = agent.get("port", 0)
    token = agent.get("token", "")
    try:
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", "3", f"http://127.0.0.1:{port}/health"],
            capture_output=True, text=True
        )
        code = r.stdout.strip()
        if code != "200" and token:
            r = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "--max-time", "3", "-H", f"Authorization: Bearer {token}",
                 f"http://127.0.0.1:{port}/v1/models"],
                capture_output=True, text=True
            )
            code = r.stdout.strip()
        agents[agent["name"]] = "online" if code == "200" else "offline"
    except Exception:
        agents[agent["name"]] = "error"

# Linear (optional)
linear = {}
linear_conf = config.get("linear", {})
api_key_env = linear_conf.get("apiKeyEnv", "LINEAR_API_KEY")
api_key = os.environ.get(api_key_env, "")
for team in linear_conf.get("teams", []):
    if not api_key:
        linear[team] = "no_key"
        continue
    try:
        query = f'{{ issues(filter: {{ team: {{ key: {{ eq: "{team}" }} }}, state: {{ type: {{ nin: ["completed","cancelled"] }} }} }}) {{ nodes {{ id }} }} }}'
        r = subprocess.run(
            ["curl", "-s", "-X", "POST", "https://api.linear.app/graphql",
             "-H", f"Authorization: {api_key}", "-H", "Content-Type: application/json",
             "-d", json.dumps({"query": query})],
            capture_output=True, text=True, timeout=10
        )
        data = json.loads(r.stdout)
        count = len(data.get("data", {}).get("issues", {}).get("nodes", []))
        linear[team] = count
    except Exception:
        linear[team] = "error"

# VPS resources
mem_pct = disk_pct = 0
try:
    r = subprocess.run(["free"], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith("Mem:"):
            parts = line.split()
            mem_pct = int(float(parts[2]) / float(parts[1]) * 100)
            break
    r = subprocess.run(["df", "/"], capture_output=True, text=True)
    disk_pct = int(r.stdout.splitlines()[-1].split()[4].rstrip("%"))
except Exception:
    pass

# ── Load previous state & compute deltas ────────────────────────────────────
state_file = os.path.join(state_dir, "sitrep.json")
prev = {}
os.makedirs(state_dir, exist_ok=True)
if os.path.exists(state_file):
    try:
        with open(state_file) as f:
            prev = json.load(f)
    except Exception:
        pass

changes = []
prev_ci = prev.get("ci", {})
for repo, status in ci.items():
    if prev_ci.get(repo) and prev_ci[repo] != status:
        changes.append(f"CI {repo}: {prev_ci[repo]} → {status}")

prev_ep = prev.get("endpoints", {})
for ep, code in endpoints.items():
    if prev_ep.get(ep) and prev_ep[ep] != code:
        changes.append(f"{ep}: {prev_ep[ep]} → {code}")

prev_agents = prev.get("agents", {})
for name, status in agents.items():
    if prev_agents.get(name) and prev_agents[name] != status:
        changes.append(f"agent {name}: {prev_agents[name]} → {status}")

prev_linear = prev.get("linear", {})
for team, count in linear.items():
    if isinstance(count, int) and isinstance(prev_linear.get(team), int):
        delta = count - prev_linear[team]
        if delta != 0:
            changes.append(f"{team} tickets: {'+' if delta > 0 else ''}{delta}")

# Save state
current = {
    "timestamp": timestamp, "ci": ci, "endpoints": endpoints,
    "agents": agents, "linear": linear,
    "vps": {"mem_pct": mem_pct, "disk_pct": disk_pct}
}
with open(state_file, "w") as f:
    json.dump(current, f, indent=2)

# ── Display ─────────────────────────────────────────────────────────────────
prev_ts = prev.get("timestamp", "first run")
if prev_ts != "first run":
    prev_ts = prev_ts[:16].replace("T", " ")

print(f"\n{BOLD}{B}SITREP{N} {D}|{N} {display_time} {D}|{N} vs {prev_ts}")
print(f"{D}{'─' * 60}{N}")

# Agents
online = sum(1 for s in agents.values() if s == "online")
total = len(agents)
color = G if online == total else (Y if online > 0 else R)
print(f"\n{BOLD}Agents{N}  {color}{online}/{total} online{N}")
for name, status in agents.items():
    icon = f"{G}⬢{N}" if status == "online" else f"{R}⬡{N}"
    print(f"  {icon} {name}")

# CI
if ci:
    print(f"\n{BOLD}CI{N}")
    for repo, status in ci.items():
        if status == "green":
            print(f"  {G}✅{N} {repo}")
        elif status == "RED":
            print(f"  {R}❌{N} {repo}")
        elif status == "running":
            print(f"  {Y}⚡{N} {repo} (in progress)")
        else:
            print(f"  {D}?{N}  {repo} ({status})")

# Endpoints
if endpoints:
    print(f"\n{BOLD}Services{N}")
    for ep, code in endpoints.items():
        icon = f"{G}✅{N}" if code in ("200", "201", "301", "302") else f"{R}❌{N}"
        print(f"  {icon} {ep} ({code})")

# Deltas
if changes:
    print(f"\n{BOLD}{Y}CHANGED{N}")
    for c in changes:
        print(f"  → {c}")
elif prev_ts != "first run":
    print(f"\n  {G}No changes since last run{N}")

# Resources
if mem_pct or disk_pct:
    mc = R if mem_pct > 80 else (Y if mem_pct > 60 else G)
    dc = R if disk_pct > 80 else (Y if disk_pct > 60 else G)
    print(f"\n{BOLD}Resources{N}  mem {mc}{mem_pct}%{N} | disk {dc}{disk_pct}%{N}")

# Linear
if linear:
    parts = []
    for t, c in linear.items():
        if isinstance(c, int):
            parts.append(f"{t}: {c} open")
    if parts:
        print(f"{BOLD}Linear{N}    {' | '.join(parts)}")

print()
SITREP_PY
}
