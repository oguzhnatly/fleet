#!/bin/bash
# fleet sitrep: Structured status report with delta tracking

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

# v4: runtimes via adapter dispatcher (shell out to fleet adapter health)
runtimes = {}
runtimes_meta = {}
fleet_root = os.environ.get("FLEET_ROOT", "")
rt_list = config.get("runtimes", [])
if rt_list and fleet_root and os.path.isdir(fleet_root):
    # Probe runtimes in parallel so a slow target does not stall sitrep.
    from concurrent.futures import ThreadPoolExecutor, as_completed

    def _probe_runtime(rt):
        rname = rt.get("name", "?")
        atype = rt.get("adapter") or rt.get("type") or "openclaw"
        try:
            r = subprocess.run(
                ["bash", "-c",
                 f'source "{fleet_root}/lib/core/adapters.sh" 2>/dev/null; '
                 f'fleet_adapter_load_all; fleet_adapter_health "$1"',
                 "_", json.dumps(rt)],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "FLEET_ROOT": fleet_root}
            )
            line = (r.stdout or "{}").strip().splitlines()[-1] if r.stdout else "{}"
            d = json.loads(line)
        except Exception:
            d = {}
        return rname, atype, d

    with ThreadPoolExecutor(max_workers=min(8, max(1, len(rt_list)))) as pool:
        futures = [pool.submit(_probe_runtime, rt) for rt in rt_list]
        for fut in as_completed(futures):
            rname, atype, d = fut.result()
            runtimes[rname] = d.get("status", "error")
            runtimes_meta[rname] = {
                "adapter": atype,
                "verified": d.get("verified", False),
                "ms": d.get("elapsed_ms", 0),
            }
elif rt_list:
    # FLEET_ROOT missing: report runtimes as unprobed but list them.
    for rt in rt_list:
        rname = rt.get("name", "?")
        atype = rt.get("adapter") or rt.get("type") or "openclaw"
        runtimes[rname] = "unprobed"
        runtimes_meta[rname] = {"adapter": atype, "verified": False, "ms": 0}

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

prev_rt = prev.get("runtimes", {})
for rname, status in runtimes.items():
    if prev_rt.get(rname) and prev_rt[rname] != status:
        changes.append(f"runtime {rname}: {prev_rt[rname]} → {status}")

# Save state
current = {
    "timestamp": timestamp, "ci": ci, "endpoints": endpoints,
    "agents": agents, "runtimes": runtimes, "linear": linear,
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

# Runtimes (v4)
if runtimes:
    online_rt = sum(1 for s in runtimes.values() if s == "online")
    total_rt = len(runtimes)
    rcolor = G if online_rt == total_rt else (Y if online_rt > 0 else R)
    print(f"\n{BOLD}Runtimes{N}  {rcolor}{online_rt}/{total_rt} online{N}")
    for rname, status in runtimes.items():
        meta = runtimes_meta.get(rname, {})
        atype = meta.get("adapter", "?"); ver = meta.get("verified", False)
        verify_tag = f"{D}verified{N}" if ver else f"{Y}inferred{N}"
        if status == "online":
            print(f"  {G}⬢{N} {rname} {D}({atype}){N} {verify_tag}")
        elif status in ("starting","degraded","auth_failed"):
            print(f"  {Y}⚠{N} {rname} {status} {D}({atype}){N} {verify_tag}")
        elif status == "unprobed":
            print(f"  {D}?{N}  {rname} unprobed {D}({atype}, FLEET_ROOT not set){N}")
        else:
            print(f"  {R}⬡{N} {rname} {status} {D}({atype}){N} {verify_tag}")

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

# Trust summary (v3)
trust_file = os.path.join(os.path.dirname(config_path), "..", ".fleet", "log.jsonl")
log_f = os.environ.get("FLEET_LOG", os.path.expanduser("~/.fleet/log.jsonl"))
if os.path.exists(log_f):
    agents_cfg = [a["name"] for a in config.get("agents", [])]
    if agents_cfg:
        # Compute a quick per-agent trust score from the log
        from datetime import datetime as _dt, timezone as _tz
        _now = _dt.now(_tz.utc)
        _wh  = float(config.get("trust", {}).get("windowHours", 72))

        def _tq(outcome, steers):
            steers = int(steers)
            if outcome == "success":  return max(0.7, 1.0 - 0.15 * steers)
            if outcome == "steered":  return max(0.3, 0.5 - 0.10 * max(0, steers-1))
            if outcome in ("failure","timeout"): return 0.0
            return None

        def _speed_mult(avg_min):
            if avg_min is None or avg_min <= 5:  return 1.0
            if avg_min <= 15: return 0.9
            if avg_min <= 30: return 0.75
            return max(0.5, 1.0 - (avg_min - 30) / 120.0)

        _entries = {}
        with open(log_f) as _lf:
            for _ln in _lf:
                _ln = _ln.strip()
                if not _ln: continue
                try:
                    _e = json.loads(_ln)
                    _a = _e.get("agent","")
                    _entries.setdefault(_a, []).append(_e)
                except Exception: pass

        _scores = {}
        for _n in agents_cfg:
            _elist = _entries.get(_n, [])
            _tw = _qw = 0.0
            _durs = []
            for _e in _elist:
                try:
                    _d = _dt.strptime(_e.get("dispatched_at","")[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=_tz.utc)
                    _age = (_now - _d).total_seconds() / 3600.0
                    _w = 2.0 if _age <= _wh else (1.0 if _age <= 168 else 0.5)
                    _q = _tq(_e.get("outcome",""), _e.get("steer_count",0))
                    if _q is None: continue
                    _tw += _w; _qw += _w * _q
                    _comp_s = _e.get("completed_at","")
                    if _comp_s:
                        _cd = _dt.strptime(_comp_s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=_tz.utc)
                        _dur = (_cd - _d).total_seconds()
                        if 0 <= _dur < 86400: _durs.append(_dur)
                except Exception: pass
            if _tw > 0:
                _avg_min = (sum(_durs) / len(_durs)) / 60.0 if _durs else None
                _scores[_n] = round((_qw / _tw) * _speed_mult(_avg_min), 2)

        if _scores:
            _parts = []
            for _n, _s in sorted(_scores.items(), key=lambda x: x[1], reverse=True):
                _c = G if _s >= 0.8 else (Y if _s >= 0.6 else R)
                _parts.append(f"{_c}{_n}:{round(_s*100)}%{N}")
            print(f"{BOLD}Trust{N}     {' | '.join(_parts)}")

print()
SITREP_PY
}
