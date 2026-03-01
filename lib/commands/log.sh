#!/bin/bash
# fleet log · Append-only structured log of all fleet dispatches and outcomes
# Schema per entry (JSONL): task_id, agent, task_type, prompt, dispatched_at,
#   completed_at, outcome, steer_count

FLEET_LOG_FILE="${FLEET_LOG_FILE:-$HOME/.fleet/log.jsonl}"

# ── Internal: write a new log entry ─────────────────────────────────────────
# Usage: fleet_log_write <json-string>
fleet_log_write() {
    mkdir -p "$(dirname "$FLEET_LOG_FILE")"
    echo "$1" >> "$FLEET_LOG_FILE"
}

# ── Internal: create a dispatched entry, print task_id ──────────────────────
# Usage: fleet_log_dispatch <agent> <task_type> <prompt>
fleet_log_dispatch() {
    local agent="$1" task_type="$2" prompt="$3"
    local task_id now

    task_id="$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])")"
    now="$(python3 -c "from datetime import datetime,timezone; print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")"

    python3 - "$FLEET_LOG_FILE" "$task_id" "$agent" "$task_type" "$prompt" "$now" <<'PY'
import json, sys

log_file = sys.argv[1]
entry = {
    "task_id":      sys.argv[2],
    "agent":        sys.argv[3],
    "task_type":    sys.argv[4],
    "prompt":       sys.argv[5][:500],
    "dispatched_at": sys.argv[6],
    "completed_at": None,
    "outcome":      "pending",
    "steer_count":  0,
}
import os; os.makedirs(os.path.dirname(log_file), exist_ok=True)
with open(log_file, "a") as f:
    f.write(json.dumps(entry) + "\n")
print(sys.argv[2])
PY
}

# ── Internal: update outcome of a task by task_id ───────────────────────────
# Usage: fleet_log_complete <task_id> <outcome: success|failure|timeout|steered>
fleet_log_complete() {
    local task_id="$1" outcome="$2"
    python3 - "$FLEET_LOG_FILE" "$task_id" "$outcome" <<'PY'
import json, sys, os
from datetime import datetime, timezone

log_file = sys.argv[1]
task_id = sys.argv[2]
outcome = sys.argv[3]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

if not os.path.exists(log_file):
    sys.exit(0)

lines = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
            if entry.get("task_id") == task_id and entry.get("outcome") == "pending":
                entry["outcome"] = outcome
                entry["completed_at"] = now
        except Exception:
            pass
        lines.append(entry if 'entry' in dir() and isinstance(entry, dict) else line)

with open(log_file, "w") as f:
    for item in lines:
        if isinstance(item, dict):
            f.write(json.dumps(item) + "\n")
        else:
            f.write(item + "\n")
PY
}

# ── Internal: increment steer_count for last pending task of an agent ────────
fleet_log_steer() {
    local agent="$1"
    python3 - "$FLEET_LOG_FILE" "$agent" <<'PY'
import json, sys, os

log_file = sys.argv[1]
agent = sys.argv[2]

if not os.path.exists(log_file):
    sys.exit(0)

lines = []
last_pending_idx = -1
with open(log_file) as f:
    raw = f.readlines()

entries = []
for line in raw:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
        entries.append(entry)
    except Exception:
        entries.append(line)

for i, entry in enumerate(entries):
    if isinstance(entry, dict) and entry.get("agent") == agent and entry.get("outcome") == "pending":
        last_pending_idx = i

if last_pending_idx >= 0:
    entries[last_pending_idx]["steer_count"] = entries[last_pending_idx].get("steer_count", 0) + 1

with open(log_file, "w") as f:
    for item in entries:
        if isinstance(item, dict):
            f.write(json.dumps(item) + "\n")
        else:
            f.write(item + "\n")
PY
}

# ── cmd_log · Display fleet log ──────────────────────────────────────────────
cmd_log() {
    local filter_agent="" filter_outcome="" limit=50 flag

    while [[ $# -gt 0 ]]; do
        flag="$1"; shift
        case "$flag" in
            --agent|-a)   filter_agent="${1:-}"; shift ;;
            --outcome|-o) filter_outcome="${1:-}"; shift ;;
            --limit|-n)   limit="${1:-50}"; shift ;;
            --all)        limit=9999 ;;
            --help|-h)
                echo "  Usage: fleet log [--agent <name>] [--outcome <success|failure|timeout|steered|pending>] [--limit N] [--all]"
                return 0 ;;
        esac
    done

    if [ ! -f "$FLEET_LOG_FILE" ]; then
        out_dim "No fleet log yet. Dispatch a task with: fleet task <agent> \"<prompt>\""
        return 0
    fi

    python3 - "$FLEET_LOG_FILE" "$filter_agent" "$filter_outcome" "$limit" <<'PY'
import json, sys, os
from datetime import datetime, timezone

log_file    = sys.argv[1]
flt_agent   = sys.argv[2]
flt_outcome = sys.argv[3]
limit       = int(sys.argv[4])

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; B = "\033[34m"
C = "\033[36m"; D = "\033[2m"; BOLD = "\033[1m"; N = "\033[0m"

entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except Exception:
            pass

# Apply filters
if flt_agent:
    entries = [e for e in entries if e.get("agent") == flt_agent]
if flt_outcome:
    entries = [e for e in entries if e.get("outcome") == flt_outcome]

# Most recent first, limited
entries = entries[-limit:][::-1]

if not entries:
    print(f"  {D}No log entries found.{N}")
    sys.exit(0)

print(f"\n{BOLD}{B}Fleet Log{N}  {D}{len(entries)} entries{N}\n")

outcome_colors = {
    "success":  f"{G}success{N}",
    "failure":  f"{R}failure{N}",
    "timeout":  f"{R}timeout{N}",
    "steered":  f"{Y}steered{N}",
    "pending":  f"{Y}pending{N}",
}

for e in entries:
    task_id    = e.get("task_id", "?")
    agent      = e.get("agent", "?")
    task_type  = e.get("task_type", "?")
    prompt     = e.get("prompt", "")[:72]
    dispatched = e.get("dispatched_at", "")[:16].replace("T", " ")
    outcome    = e.get("outcome", "?")
    steers     = e.get("steer_count", 0)
    completed  = e.get("completed_at")

    outcome_str = outcome_colors.get(outcome, outcome)

    # Duration
    dur = ""
    if completed and e.get("dispatched_at"):
        try:
            fmt = "%Y-%m-%dT%H:%M:%SZ"
            t0 = datetime.strptime(e["dispatched_at"], fmt)
            t1 = datetime.strptime(completed, fmt)
            s = int((t1 - t0).total_seconds())
            dur = f"{s//60}m{s%60:02d}s" if s >= 60 else f"{s}s"
        except Exception:
            pass

    steer_str = f" {Y}⤷{steers} steer{'s' if steers != 1 else ''}{N}" if steers else ""
    dur_str = f" {D}{dur}{N}" if dur else ""

    print(f"  {D}{task_id}{N}  {C}{agent:12}{N} {D}{task_type:8}{N}  {outcome_str}{steer_str}{dur_str}")
    print(f"  {D}{dispatched}  {prompt}{'…' if len(e.get('prompt','')) > 72 else ''}{N}")
    print()
PY
}
