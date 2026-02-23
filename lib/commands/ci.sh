#!/bin/bash
# fleet ci · GitHub CI status across configured repos

cmd_ci() {
    local filter="${1:-}"

    out_header "CI Status"

    if ! command -v gh &>/dev/null; then
        out_fail "gh CLI not installed. Install from https://cli.github.com"
        return 1
    fi

    if ! fleet_has_config; then
        echo "  No config found. Run: fleet init"
        return 1
    fi

    python3 - "$FLEET_CONFIG_PATH" "$filter" <<'CI_PY'
import json, subprocess, sys

with open(sys.argv[1]) as f:
    config = json.load(f)
name_filter = sys.argv[2] if len(sys.argv) > 2 else ""

G = "\033[32m"; R = "\033[31m"; Y = "\033[33m"; D = "\033[2m"; N = "\033[0m"

repos = config.get("repos", [])
if not repos:
    print("  No repos configured.")
    sys.exit(0)

for repo_conf in repos:
    name = repo_conf.get("name", repo_conf.get("repo", "?"))
    repo = repo_conf.get("repo", "")

    if name_filter and name_filter.lower() not in name.lower():
        continue

    if not repo:
        continue

    try:
        r = subprocess.run(
            ["gh", "run", "list", "--repo", repo, "--limit", "3",
             "--json", "conclusion,status,displayTitle,headBranch,updatedAt,databaseId"],
            capture_output=True, text=True, timeout=15
        )
        runs = json.loads(r.stdout) if r.stdout.strip() else []

        print(f"\n  {name} ({D}{repo}{N})")

        if not runs:
            print(f"    {D}No CI runs found{N}")
            continue

        for run in runs:
            s = run.get("status", "")
            c = run.get("conclusion", "")
            title = run.get("displayTitle", "?")[:50]
            branch = run.get("headBranch", "?")
            updated = run.get("updatedAt", "")[:16]

            if s in ("in_progress", "queued"):
                icon = f"{Y}⚡{N}"
                label = s
            elif c == "success":
                icon = f"{G}✅{N}"
                label = "passed"
            elif c == "failure":
                icon = f"{R}❌{N}"
                label = "failed"
            else:
                icon = f"{D}?{N} "
                label = c or s or "unknown"

            print(f"    {icon} {title} {D}({branch}) {label} {updated}{N}")

    except subprocess.TimeoutExpired:
        print(f"    {R}timeout{N}")
    except Exception as e:
        print(f"    {R}error: {e}{N}")
CI_PY
}
