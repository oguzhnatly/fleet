#!/bin/bash
# fleet/lib/core/trust.sh: Trust scoring engine
#
# Computes agent reliability scores from ~/.fleet/log.jsonl.
# Sourced by bin/fleet alongside config.sh, output.sh, state.sh.
#
# Public API (bash wrappers around the Python engine below):
#   trust_score_agent  <log_file> <agent> [window_h]   → float or "none"
#   trust_best_for_type <log_file> <config> <type> [w] → agent name
#   trust_all_json     <log_file> <config> [window_h]  → JSON array
#
# Formula:  trust = quality_score × speed_multiplier
#   quality_score  = weighted(success + 0.5×steered) / total_weight
#                    steer_count within a task applies up to 30% penalty
#   speed_mult     = 1.0 (≤5m), 0.9 (≤15m), 0.75 (≤30m), ≥0.5 (>30m)
# Recency weights: ≤window_h → 2×: ≤168h → 1×: older → 0.5×
# Trend:          compare [0..7d] vs [7d..14d]; ↑ if delta > 5%, ↓ if < -5%

FLEET_TRUST_WINDOW_HOURS="${FLEET_TRUST_WINDOW_HOURS:-72}"

# ── Shared Python engine (heredoc, reused by all trust commands) ─────────────
# This string is eval'd by the bash wrappers below via python3 - <<PY ... PY.
# Do NOT call it directly from bash; use the wrapper functions instead.
_FLEET_TRUST_ENGINE='
import json, sys, os
from datetime import datetime, timezone

def _parse_ts(s):
    if not s:
        return None
    try:
        return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    except Exception:
        return None

def _task_quality(outcome, steers):
    """Return quality score [0.0, 1.0] for a single completed task."""
    if outcome == "success":
        return max(0.7, 1.0 - 0.15 * steers)
    if outcome == "steered":
        return max(0.3, 0.5 - 0.10 * max(0, steers - 1))
    if outcome in ("failure", "timeout"):
        return 0.0
    return None  # pending or unknown, skip

def _speed_mult(avg_min):
    if avg_min is None or avg_min <= 5:
        return 1.0
    if avg_min <= 15:
        return 0.9
    if avg_min <= 30:
        return 0.75
    return max(0.5, 1.0 - (avg_min - 30) / 120.0)

def compute_score(entries, now, window_h):
    """
    Compute composite trust score for a list of log entries.
    Returns dict: score, tasks, by_type, avg_min
    """
    total_w = quality_w = 0.0
    type_data = {}
    durations = []
    valid = 0

    for e in entries:
        dispatched = _parse_ts(e.get("dispatched_at"))
        if not dispatched:
            continue
        age_h = (now - dispatched).total_seconds() / 3600.0
        # Weight by recency
        w = 2.0 if age_h <= window_h else (1.0 if age_h <= 168 else 0.5)

        outcome = e.get("outcome", "pending")
        steers  = int(e.get("steer_count", 0))
        q = _task_quality(outcome, steers)
        if q is None:
            continue  # skip pending

        valid   += 1
        total_w += w
        quality_w += w * q

        tt = e.get("task_type") or "general"
        if tt not in type_data:
            type_data[tt] = {"total_w": 0.0, "quality_w": 0.0, "count": 0, "outcomes": {}}
        type_data[tt]["total_w"]   += w
        type_data[tt]["quality_w"] += w * q
        type_data[tt]["count"]     += 1
        type_data[tt]["outcomes"][outcome] = type_data[tt]["outcomes"].get(outcome, 0) + 1

        completed = _parse_ts(e.get("completed_at"))
        if completed:
            dur = (completed - dispatched).total_seconds()
            if 0 <= dur < 86400:  # sanity: ignore >24h tasks
                durations.append(dur)

    if total_w == 0:
        return {"score": None, "tasks": valid, "by_type": {}, "avg_min": None}

    avg_min = (sum(durations) / len(durations)) / 60.0 if durations else None
    speed   = _speed_mult(avg_min)
    composite = round(min(1.0, (quality_w / total_w) * speed), 3)

    by_type = {}
    for tt, d in type_data.items():
        if d["total_w"] > 0:
            ts = round((d["quality_w"] / d["total_w"]) * speed, 3)
            by_type[tt] = {"score": ts, "count": d["count"], "outcomes": d["outcomes"]}

    return {
        "score":   composite,
        "tasks":   valid,
        "by_type": by_type,
        "avg_min": round(avg_min, 1) if avg_min is not None else None,
        "speed":   round(speed, 3),
    }

def load_entries(log_file):
    """Load all log entries grouped by agent name."""
    all_entries = {}
    if not os.path.exists(log_file):
        return all_entries
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
    return all_entries

def trend(entries, now):
    """Compare last 7d vs prior 7d. Returns: up | down | stable | new"""
    def in_range(e, lo, hi):
        ts = _parse_ts(e.get("dispatched_at"))
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
    diff = cs - ps
    return "up" if diff > 0.05 else ("down" if diff < -0.05 else "stable")
'

# ── trust_score_agent <log_file> <agent> [window_h] ─────────────────────────
# Prints a float 0.0-1.0 or "none" if no data.
trust_score_agent() {
    local log_file="$1" agent="$2" window="${3:-$FLEET_TRUST_WINDOW_HOURS}"
    python3 - "$log_file" "$agent" "$window" <<PY
${_FLEET_TRUST_ENGINE}
from datetime import datetime, timezone
import sys

log_file  = sys.argv[1]
agent     = sys.argv[2]
window_h  = float(sys.argv[3])
now       = datetime.now(timezone.utc)

entries = load_entries(log_file).get(agent, [])
result  = compute_score(entries, now, window_h)
s = result.get("score")
print(s if s is not None else "none")
PY
}

# ── trust_best_for_type <log_file> <config_file> <task_type> [window_h] ─────
# Prints the agent name with the highest trust score for the given task type.
# Falls back to overall score (with 0.8x penalty) when no type-specific data.
trust_best_for_type() {
    local log_file="$1" config_file="$2" task_type="$3" window="${4:-$FLEET_TRUST_WINDOW_HOURS}"
    python3 - "$log_file" "$config_file" "$task_type" "$window" <<PY
${_FLEET_TRUST_ENGINE}
from datetime import datetime, timezone
import sys

log_file    = sys.argv[1]
config_file = sys.argv[2]
task_type   = sys.argv[3]
window_h    = float(sys.argv[4])
now         = datetime.now(timezone.utc)

with open(config_file) as f:
    config = json.load(f)

agents     = [a["name"] for a in config.get("agents", [])]
all_entries = load_entries(log_file)

if not agents:
    sys.exit(1)

scores = {}
for name in agents:
    entries = all_entries.get(name, [])
    typed   = [e for e in entries if (e.get("task_type") or "general") == task_type]
    if typed:
        r = compute_score(typed, now, window_h)
        scores[name] = r.get("score") or 0.0
    else:
        r = compute_score(entries, now, window_h)
        scores[name] = (r.get("score") or 0.0) * 0.8  # small penalty for untested type

best = max(scores, key=lambda a: scores[a]) if scores else agents[0]
print(best)
PY
}

# ── trust_all_json <log_file> <config_file> [window_h] ──────────────────────
# Prints a JSON array; each element: {agent, score, tasks, by_type, avg_min, trend, in_config}
trust_all_json() {
    local log_file="$1" config_file="$2" window="${3:-$FLEET_TRUST_WINDOW_HOURS}"
    python3 - "$log_file" "$config_file" "$window" <<PY
${_FLEET_TRUST_ENGINE}
from datetime import datetime, timezone
import sys

log_file    = sys.argv[1]
config_file = sys.argv[2]
window_h    = float(sys.argv[3])
now         = datetime.now(timezone.utc)

with open(config_file) as f:
    config = json.load(f)

cfg_agents  = [a["name"] for a in config.get("agents", [])]
all_entries = load_entries(log_file)

all_names = list(cfg_agents) + [a for a in all_entries if a not in cfg_agents]
out = []
for name in all_names:
    entries = all_entries.get(name, [])
    curr    = compute_score(entries, now, window_h)
    tr      = trend(entries, now)
    out.append({
        "agent":     name,
        "score":     curr.get("score"),
        "tasks":     curr.get("tasks", 0),
        "by_type":   curr.get("by_type", {}),
        "avg_min":   curr.get("avg_min"),
        "trend":     tr,
        "in_config": name in cfg_agents,
    })

print(json.dumps(out))
PY
}
