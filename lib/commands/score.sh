#!/bin/bash
# fleet score: Per-agent reliability breakdown by task type
# Usage: fleet score [<agent>] [--window <hours>] [--type <task_type>]
#
# Shows quality score, speed, per-task-type breakdown, and recent task history.
# With no <agent> argument, scores all configured agents in summary form.
# v3.5: cross-validates code/deploy successes against GitHub commit activity.

cmd_score() {
    local agent="" window="${FLEET_TRUST_WINDOW_HOURS:-72}" type_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --window|-w)  window="${2:-72}"; shift 2 ;;
            --type|-t)    type_filter="${2:-}"; shift 2 ;;
            --help|-h)
                cat <<'HELP'

  Usage: fleet score [<agent>] [--window <hours>] [--type <task_type>]

  Show per-task-type reliability breakdown for an agent.
  Omit <agent> to see a summary table for all configured agents.

  Options:
    --window <hours>     Recency window for 2× weight (default: 72)
    --type <task_type>   Filter to a specific task type (code, review, deploy, qa, research)

  Cross-validation (v3.5):
    For agents with code or deploy successes, fleet score checks whether
    a corresponding GitHub CI run exists within 1 hour of completion.
    If none found, the task is flagged as unverified.

HELP
                return 0 ;;
            -*)  shift ;;
            *)   agent="$1"; shift ;;
        esac
    done

    python3 - "$FLEET_CONFIG_PATH" "$FLEET_LOG_FILE" "$agent" "$window" "$type_filter" <<'SCOREPY'
import json, sys, os, subprocess
from datetime import datetime, timezone

config_path  = sys.argv[1]
log_file     = sys.argv[2]
target       = sys.argv[3]
window_h     = float(sys.argv[4])
type_filter  = sys.argv[5]

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

def compute(entries, now, wh):
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
            type_data[tt] = {"total_w": 0.0, "quality_w": 0.0, "count": 0, "outcomes": {}}
        type_data[tt]["total_w"]   += w
        type_data[tt]["quality_w"] += w * q
        type_data[tt]["count"]     += 1
        oc = outcome
        type_data[tt]["outcomes"][oc] = type_data[tt]["outcomes"].get(oc, 0) + 1
        completed = parse_ts(e.get("completed_at"))
        if completed:
            dur = (completed - dispatched).total_seconds()
            if 0 <= dur < 86400:
                durations.append(dur)
    if total_w == 0:
        return {"score": None, "tasks": valid, "by_type": {}, "avg_min": None, "speed": 1.0}
    avg_min = (sum(durations) / len(durations)) / 60.0 if durations else None
    sp   = speed_mult(avg_min)
    comp = round(min(1.0, (quality_w / total_w) * sp), 3)
    by_type = {}
    for tt, d in type_data.items():
        if d["total_w"] > 0:
            by_type[tt] = {
                "score":    round((d["quality_w"] / d["total_w"]) * sp, 3),
                "count":    d["count"],
                "outcomes": d["outcomes"],
            }
    return {"score": comp, "tasks": valid, "by_type": by_type,
            "avg_min": round(avg_min, 1) if avg_min is not None else None, "speed": round(sp, 3)}

def score_bar(score, width=14):
    if score is None:
        return f"{D}{'no data':>{width}}{N}"
    filled = round(score * width)
    c = G if score >= 0.8 else (Y if score >= 0.6 else R)
    return f"{c}{BARS[:filled]}{D}{BAR_EMPTY[filled:]}{N}"

def agent_trend(entries, now):
    def in_range(e, lo, hi):
        ts = parse_ts(e.get("dispatched_at"))
        if not ts:
            return False
        age = (now - ts).total_seconds() / 3600.0
        return lo <= age < hi
    c7 = [e for e in entries if in_range(e, 0,   168)]
    p7 = [e for e in entries if in_range(e, 168, 336)]
    cs = compute(c7, now, 168).get("score")
    ps = compute(p7, now, 168).get("score")
    if cs is None or ps is None:
        return None, None
    return cs - ps, ps

now = datetime.now(timezone.utc)

config = {}
if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            config = json.load(f)
    except Exception:
        pass

cfg_agents  = [a["name"] for a in config.get("agents", [])]
repos       = [r.get("repo") for r in config.get("repos", []) if r.get("repo")]
trust_cfg   = config.get("trust", {})
window_h    = float(trust_cfg.get("windowHours", window_h))

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

target_agents = [target] if target else (cfg_agents or sorted(all_entries.keys()))

# ── Summary mode (no specific agent) ─────────────────────────────────────────
if not target:
    print(f"\n{BOLD}{B}Agent Score Summary{N}  "
          f"{D}| {now.strftime('%Y-%m-%d %H:%M UTC')} | {int(window_h)}h window{N}")
    print(f"{D}{'─' * 72}{N}\n")
    for name in target_agents:
        entries  = all_entries.get(name, [])
        if type_filter:
            entries = [e for e in entries if (e.get("task_type") or "general") == type_filter]
        curr     = compute(entries, now, window_h)
        delta, ps = agent_trend(all_entries.get(name, []), now)

        score = curr.get("score")
        tasks = curr.get("tasks", 0)
        pct   = f"{round(score*100)}%" if score is not None else "no data"
        color = G if score is not None and score >= 0.8 else (Y if score is not None and score >= 0.6 else R)

        trend_str = ""
        if delta is not None and ps is not None:
            trend_str = (f"  {G}↑ {round(delta*100):+}%{N}" if delta > 0.05 else
                         f"  {R}↓ {round(delta*100):+}%{N}" if delta < -0.05 else
                         f"  {D}→ stable{N}")

        by_type = curr.get("by_type", {})
        top     = sorted(by_type.items(), key=lambda x: x[1]["count"], reverse=True)[:3]
        type_str = "  " + "  ".join(f"{D}{tt}:{round(td['score']*100)}%{N}" for tt, td in top) if top else ""

        print(f"  {score_bar(score)}  {color}{BOLD}{pct:>5}{N}  {BOLD}{name:16}{N}  "
              f"{D}{tasks} tasks{N}{trend_str}{type_str}")
    print()
    sys.exit(0)

# ── Detailed mode (single agent) ─────────────────────────────────────────────
for agent_name in target_agents:
    raw_entries = all_entries.get(agent_name, [])
    entries = ([e for e in raw_entries if (e.get("task_type") or "general") == type_filter]
               if type_filter else raw_entries)

    curr              = compute(entries, now, window_h)
    delta, prior_s    = agent_trend(raw_entries, now)
    score             = curr.get("score")
    tasks             = curr.get("tasks", 0)
    avg_min           = curr.get("avg_min")
    sp                = curr.get("speed", 1.0)
    by_type           = curr.get("by_type", {})
    nc_tag            = f"  {D}(not in config){N}" if agent_name not in cfg_agents else ""
    type_tag          = f"  {D}filtered: {type_filter}{N}" if type_filter else ""

    print(f"\n{BOLD}{B}fleet score  {N}{BOLD}{agent_name}{N}{nc_tag}{type_tag}")
    print(f"{D}{'─' * 60}{N}")

    color = G if score is not None and score >= 0.8 else (Y if score is not None and score >= 0.6 else R)
    pct   = f"{round(score*100)}%" if score is not None else "no data"

    trend_str = ""
    if delta is not None and prior_s is not None:
        trend_str = (f"  {G}↑ from {round(prior_s*100)}%{N}" if delta > 0.05 else
                     f"  {R}↓ from {round(prior_s*100)}%{N}" if delta < -0.05 else
                     f"  {D}→ stable vs last week{N}")

    print(f"  {'Overall':16}  {score_bar(score)}  {color}{BOLD}{pct:>5}{N}{trend_str}")

    info_parts = [f"Tasks: {tasks}", f"Window: {int(window_h)}h"]
    if avg_min:
        info_parts.append(f"Avg duration: {avg_min}m")
    info_parts.append(f"Speed mult: {sp:.2f}")
    print(f"  {D}{': '.join(info_parts)}{N}")
    print()

    if by_type:
        print(f"  {BOLD}By task type:{N}")
        for tt, td in sorted(by_type.items(), key=lambda x: x[1]["count"], reverse=True):
            ts       = td["score"]
            tc       = td["count"]
            outcomes = td.get("outcomes", {})
            ok  = outcomes.get("success", 0)
            st  = outcomes.get("steered", 0)
            fa  = outcomes.get("failure", 0) + outcomes.get("timeout", 0)
            ok_s  = f"{G}{ok}✓{N}" if ok else ""
            st_s  = f"  {Y}{st}⤷{N}" if st else ""
            fa_s  = f"  {R}{fa}✗{N}" if fa else ""
            tc_color = G if ts is not None and ts >= 0.8 else (Y if ts is not None and ts >= 0.6 else R)
            print(f"  {D}{tt:14}{N}  {score_bar(ts)}  "
                  f"{tc_color}{round(ts*100) if ts is not None else 0:>4}%{N}  "
                  f"{D}{tc} task{'s' if tc != 1 else ''}{N}  {ok_s}{st_s}{fa_s}")
        print()

    # Recent tasks (last 10, newest first)
    completed_entries = [e for e in entries if e.get("outcome") not in ("pending",)]
    recent = sorted(completed_entries, key=lambda e: e.get("dispatched_at", ""), reverse=True)[:10]
    if recent:
        print(f"  {BOLD}Recent tasks:{N}")
        for e in recent:
            tid     = e.get("task_id", "?")[:8]
            tt      = e.get("task_type") or "?"
            outcome = e.get("outcome", "?")
            steers  = e.get("steer_count", 0)
            disp    = parse_ts(e.get("dispatched_at"))
            comp    = parse_ts(e.get("completed_at"))

            icon = (f"{G}✓{N}" if outcome == "success"    else
                    f"{Y}⤷{N}" if outcome == "steered"    else
                    f"{R}✗{N}" if outcome in ("failure","timeout") else
                    f"{D}?{N}")

            age_str = dur_str = ""
            if disp:
                age_h = (now - disp).total_seconds() / 3600.0
                age_str = (f"{int(age_h*60)}m ago" if age_h < 1 else
                           f"{int(age_h)}h ago"   if age_h < 24 else
                           f"{int(age_h/24)}d ago")
            if disp and comp:
                dur_s = (comp - disp).total_seconds()
                dur_str = (f"{int(dur_s)}s" if dur_s < 60 else
                           f"{int(dur_s//60)}m{int(dur_s%60):02d}s")

            steer_str = f" {Y}⤷{steers}{N}" if steers else ""
            prompt    = e.get("prompt", "")[:58]
            ellipsis  = "…" if len(e.get("prompt", "")) > 58 else ""

            print(f"    {icon}  {D}{tid:8}{N}  {D}{tt:10}{N}  {D}{age_str:10}{N}  {D}{dur_str:8}{N}{steer_str}")
            print(f"       {D}{prompt}{ellipsis}{N}")
        print()

    # ── v3.5: GitHub cross-validation ─────────────────────────────────────
    gh_bin = (next((p for p in ["/usr/bin/gh", "/usr/local/bin/gh",
                                 os.path.expanduser("~/.local/bin/gh")]
                    if os.path.exists(p)), None))
    if gh_bin and repos:
        code_deploy = [e for e in raw_entries
                       if e.get("outcome") == "success"
                       and (e.get("task_type") or "") in ("code", "deploy")]
        sample = sorted(code_deploy, key=lambda e: e.get("completed_at",""), reverse=True)[:5]

        if sample:
            print(f"  {BOLD}Cross-validation{N}  {D}(v3.5: GitHub CI vs fleet log){N}")
            unverified = []
            for e in sample:
                comp_ts = parse_ts(e.get("completed_at"))
                if not comp_ts:
                    continue
                verified = False
                for repo in repos[:3]:
                    try:
                        r = subprocess.run(
                            [gh_bin, "run", "list", "--repo", repo,
                             "--limit", "10", "--json", "updatedAt,conclusion"],
                            capture_output=True, text=True, timeout=8
                        )
                        runs = json.loads(r.stdout) if r.stdout.strip() else []
                        for run in runs:
                            run_ts = parse_ts((run.get("updatedAt","")[:19]).replace(" ","T") + "Z")
                            if run_ts:
                                delta_min = abs((run_ts - comp_ts).total_seconds()) / 60.0
                                if delta_min <= 60 and run.get("conclusion") == "success":
                                    verified = True
                                    break
                    except Exception:
                        pass
                    if verified:
                        break
                icon   = f"{G}✓{N}" if verified else f"{Y}?{N}"
                label  = "verified" if verified else "unverified"
                prompt = e.get("prompt","")[:40]
                print(f"    {icon}  {D}{e.get('task_id','?')[:8]:8}  {label:12}  {prompt}…{N}")
                if not verified:
                    unverified.append(e)

            if unverified:
                print(f"\n  {Y}⚠️  {len(unverified)} task{'s' if len(unverified)>1 else ''} had no matching "
                      f"GitHub CI success within 1h. The trust score may be optimistic.{N}")
            else:
                print(f"\n  {G}All sampled tasks cross-validated against GitHub CI.{N}")
            print()

SCOREPY
}
