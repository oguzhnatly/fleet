#!/bin/bash
# fleet trust: Trust matrix for all agents with scores, trends, and task counts
# Usage: fleet trust [--window <hours>] [--json]
#
# Shows a trust matrix for every configured agent, computed from ~/.fleet/log.jsonl.
# Agents with no log data show "no data". The matrix updates every time you run it.

cmd_trust() {
    local window="${FLEET_TRUST_WINDOW_HOURS:-72}"
    local json_mode=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --window|-w)
                if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                    echo "  fleet trust: --window requires a value (hours)" >&2
                    return 1
                fi
                window="$2"; shift 2 ;;
            --json)       json_mode=true; shift ;;
            --help|-h)
                cat <<'HELP'

  Usage: fleet trust [--window <hours>] [--json]

  Show the trust matrix for all configured agents.

  Trust score is computed from ~/.fleet/log.jsonl using the formula:
    trust_score = quality_score × speed_multiplier

  quality_score per task:
    success:         1.0 - 0.15 × steer_count  (min 0.70)
    steered:         0.5 - 0.10 × (steer_count - 1)  (min 0.30)
    failure/timeout: 0.0

  speed_mult  = 1.0 (avg ≤5m), 0.9 (≤15m), 0.75 (≤30m), ≥0.5 (>30m)

  Recency weights: tasks within --window hours count 2×,
                   within 7 days count 1×, older count 0.5×.

  Options:
    --window <hours>  Recency window for 2× weight (default: 72)
    --json            Output raw JSON (for piping or scripting)

HELP
                return 0 ;;
            *) shift ;;
        esac
    done

    python3 - "$FLEET_CONFIG_PATH" "$FLEET_LOG_FILE" "$window" "$json_mode" <<'TRUSTPY'
import json, sys, os
from datetime import datetime, timezone

config_path = sys.argv[1]
log_file    = sys.argv[2]
window_h    = float(sys.argv[3])
json_mode   = sys.argv[4] == "true"

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; B = "\033[34m"
C = "\033[36m"; D = "\033[2m"; BOLD = "\033[1m"; N = "\033[0m"
BARS      = "████████████████████"
BAR_EMPTY = "░░░░░░░░░░░░░░░░░░░░"

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None

def task_quality(outcome, steers):
    steers = int(steers)
    if outcome == "success":
        return max(0.7, 1.0 - 0.15 * steers)
    if outcome == "steered":
        return max(0.3, 0.5 - 0.10 * max(0, steers - 1))
    if outcome in ("failure", "timeout"):
        return 0.0
    return None

def speed_mult(avg_min):
    if avg_min is None or avg_min <= 5:
        return 1.0
    if avg_min <= 15:
        return 0.9
    if avg_min <= 30:
        return 0.75
    return max(0.5, 1.0 - (avg_min - 30) / 120.0)

def compute_score(entries, now, wh):
    total_w = quality_w = 0.0
    type_data = {}
    durations = []
    valid = 0
    for e in entries:
        dispatched = parse_ts(e.get("dispatched_at"))
        if not dispatched:
            continue
        age_h = (now - dispatched).total_seconds() / 3600.0
        w = 2.0 if age_h <= wh else (1.0 if age_h <= 168 else 0.5)
        outcome = e.get("outcome", "pending")
        steers  = e.get("steer_count", 0)
        q = task_quality(outcome, steers)
        if q is None:
            continue
        valid     += 1
        total_w   += w
        quality_w += w * q
        tt = e.get("task_type") or "general"
        if tt not in type_data:
            type_data[tt] = {"total_w": 0.0, "quality_w": 0.0, "count": 0}
        type_data[tt]["total_w"]   += w
        type_data[tt]["quality_w"] += w * q
        type_data[tt]["count"]     += 1
        completed = parse_ts(e.get("completed_at"))
        if completed:
            dur = (completed - dispatched).total_seconds()
            if 0 <= dur < 86400:
                durations.append(dur)
    if total_w == 0:
        return {"score": None, "tasks": valid, "by_type": {}, "avg_min": None}
    avg_min = (sum(durations) / len(durations)) / 60.0 if durations else None
    sp = speed_mult(avg_min)
    comp = round(min(1.0, (quality_w / total_w) * sp), 3)
    by_type = {}
    for tt, d in type_data.items():
        if d["total_w"] > 0:
            by_type[tt] = {
                "score": round((d["quality_w"] / d["total_w"]) * sp, 3),
                "count": d["count"],
            }
    return {"score": comp, "tasks": valid, "by_type": by_type,
            "avg_min": round(avg_min, 1) if avg_min is not None else None}

def agent_trend(entries, now):
    def in_range(e, lo, hi):
        ts = parse_ts(e.get("dispatched_at"))
        if not ts:
            return False
        age = (now - ts).total_seconds() / 3600.0
        return lo <= age < hi
    c7 = [e for e in entries if in_range(e, 0,   168)]
    p7 = [e for e in entries if in_range(e, 168, 336)]
    cs = compute_score(c7, now, 168).get("score")
    ps = compute_score(p7, now, 168).get("score")
    if cs is None or ps is None:
        return "new"
    d = cs - ps
    return "up" if d > 0.05 else ("down" if d < -0.05 else "stable")

now = datetime.now(timezone.utc)

config = {}
if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            config = json.load(f)
    except Exception:
        pass

trust_cfg  = config.get("trust", {})
window_h   = float(trust_cfg.get("windowHours", window_h))
cfg_agents = [a["name"] for a in config.get("agents", [])]

all_entries = {}
if os.path.exists(log_file):
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
                a = e.get("agent", "")
                if a not in all_entries:
                    all_entries[a] = []
                all_entries[a].append(e)
            except Exception:
                pass

all_names = list(cfg_agents) + [a for a in all_entries if a not in cfg_agents]
results = []
for name in all_names:
    entries = all_entries.get(name, [])
    curr = compute_score(entries, now, window_h)
    tr   = agent_trend(entries, now)
    results.append({
        "agent":     name,
        "score":     curr.get("score"),
        "tasks":     curr.get("tasks", 0),
        "by_type":   curr.get("by_type", {}),
        "avg_min":   curr.get("avg_min"),
        "trend":     tr,
        "in_config": name in cfg_agents,
    })

results.sort(key=lambda r: r["score"] if r["score"] is not None else -1, reverse=True)

if json_mode:
    print(json.dumps(results, indent=2))
    sys.exit(0)

print(f"\n{BOLD}{B}Fleet Trust Matrix{N}  "
      f"{D}| {now.strftime('%Y-%m-%d %H:%M UTC')} | {int(window_h)}h window{N}")
print(f"{D}{'─' * 72}{N}")

if not results:
    print(f"\n  {D}No agents found. Add agents to your config and run 'fleet task' to start.{N}\n")
    sys.exit(0)

print()

total_tasks = sum(r["tasks"] for r in results)
has_data    = any(r["score"] is not None for r in results)

for r in results:
    name  = r["agent"]
    score = r["score"]
    tasks = r["tasks"]
    tr    = r["trend"]

    trend_icon = (f"{G}↑{N}" if tr == "up"   else
                  f"{R}↓{N}" if tr == "down" else
                  f"{D}→{N}" if tr == "stable" else
                  f"{C}★{N}")

    if score is None:
        nc = f"  {D}(not in config){N}" if not r["in_config"] else ""
        print(f"  {BOLD}{name:16}{N}  {D}{'─ no data':20}{N}  {D}0 tasks{N}  {trend_icon}{nc}")
        continue

    filled  = round(score * 20)
    color   = G if score >= 0.8 else (Y if score >= 0.6 else R)
    bar     = f"{color}{BARS[:filled]}{D}{BAR_EMPTY[filled:]}{N}"
    pct     = f"{color}{BOLD}{round(score * 100):>3}%{N}"

    by_type = r.get("by_type", {})
    top_types = sorted(by_type.items(), key=lambda x: x[1]["count"], reverse=True)[:3]
    type_parts = [f"{D}{tt}:{round(td['score']*100)}%{N}" for tt, td in top_types]
    type_str   = "  " + "  ".join(type_parts) if type_parts else ""

    tasks_str = f"{tasks} task{'s' if tasks != 1 else ''}"
    avg_str   = f"  {D}avg {r['avg_min']}m{N}" if r.get("avg_min") else ""
    nc_str    = f"  {D}(log only){N}" if not r["in_config"] else ""

    print(f"  {BOLD}{name:16}{N}  {bar}  {pct}  {D}{tasks_str:10}{N}  {trend_icon}{type_str}{avg_str}{nc_str}")

print()
if has_data:
    print(f"  {D}Formula: quality_score × speed_multiplier  |  "
          f"Recency: ≤{int(window_h)}h → 2×  ≤7d → 1×  older → 0.5×{N}")
    print(f"  {D}Trend: {G}↑{N}{D} improved  {R}↓{N}{D} degraded  → stable  {C}★{N}{D} new (no prior period){N}")
    if total_tasks > 0:
        print(f"  {D}Total dispatched tasks in log: {total_tasks}{N}")
print()
TRUSTPY
}
