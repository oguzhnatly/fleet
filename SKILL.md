---
name: fleet
type: installable-cli
install: "clawhub install fleet"
metadata:
  openclaw:
    requires:
      bins:
        - bash
        - python3
        - curl
    optionalBins:
      - gh
    install:
      - id: clawhub
        kind: clawhub
        slug: fleet
        label: "Install fleet via ClawHub"
description: "Multi-agent fleet management CLI for OpenClaw. Coordinator agent tool for monitoring, dispatching tasks to, and observing a fleet of agent gateways. Operations are local-only (loopback) plus explicitly declared external endpoints. Operator consent required before install."
triggers: "check agents, fleet status, run sitrep, health check, dispatch task, send task to agent, steer agent, watch agent, parallel tasks, kill agent, fleet log, backup config, show agents, fleet report, how many agents online, CI status, what skills installed, trust score, which agent is reliable, fleet trust, fleet score, agent reliability, who should I assign, best agent for task"
requires:
  binaries:
    - bash>=4.0
    - python3>=3.10
    - curl
  optionalBinaries:
    - gh
envVars:
  optional:
    - name: FLEET_CONFIG
      description: "Override path to fleet config (default: ~/.fleet/config.json)"
    - name: FLEET_LOG
      description: "Override dispatch log path (default: ~/.fleet/log.jsonl)"
    - name: FLEET_STATE_DIR
      description: "Override state directory (default: ~/.fleet/state)"
    - name: FLEET_TRUST_WINDOW_HOURS
      description: "Override trust scoring window in hours (default: 72)"
    - name: FLEET_NO_UPDATE_CHECK
      description: "Set to 1 to disable background GitHub update check entirely"
    - name: LINEAR_API_KEY
      description: "Linear API key for CI ticket integration (optional, referenced in examples/solo-empire/config.json)"
    - name: NO_COLOR
      description: "Disable colored output"
installSpec:
  method: clawhub
  command: "clawhub install fleet"
  manual: "git clone https://github.com/oguzhnatly/fleet.git && fleet/bin/fleet init"
  initRequired: true
  initWrites:
    - "~/.fleet/config.json (chmod 600 immediately on creation, stores agent tokens in plaintext)"
    - "~/.local/bin/fleet (symlink to binary)"
    - "~/.bashrc or ~/.zshrc or ~/.profile (PATH export appended only if ~/.local/bin not already present)"
  initReads:
    - "~/.openclaw/openclaw.json (read-only, one-time workspace path detection)"
    - "127.0.0.1:40000-50000 (loopback port scan, one-time gateway discovery)"
  skipInit: "Clone repo, create ~/.fleet/config.json from templates/configs/minimal.json, add bin/ to PATH manually. No automatic writes."
updateSpec:
  command: "fleet update"
  source: "api.github.com/repos/oguzhnatly/fleet/releases/latest"
  verification: "SHA256 verified against fleet.sha256 published with each release. Extraction halts on mismatch."
  backgroundCheck: "Once per 24h, non-blocking. Disable with FLEET_NO_UPDATE_CHECK=1"
permissions:
  reads:
    - "~/.fleet/ (config, state, logs, backups created by fleet itself)"
    - "~/.openclaw/openclaw.json (read-only, fleet init only, workspace path detection)"
    - "~/.openclaw*/agents/*/sessions/<fleet-session-id>.jsonl (fleet watch: only fleet-named sessions)"
    - "/proc/meminfo (Linux only, fleet sitrep)"
  writes:
    - "~/.fleet/ (all fleet-created data)"
    - "~/.local/bin/fleet (symlink, fleet init)"
    - "~/.bashrc or ~/.zshrc or ~/.profile (PATH export, fleet init, only if not already present)"
  network:
    - "127.0.0.1:<agent-ports> (loopback only, operator config)"
    - "api.github.com/repos/<operator-repos>/actions/runs (fleet ci, operator gh CLI auth)"
    - "api.github.com/repos/oguzhnatly/fleet/releases/latest (background update check, 24h cache)"
    - "Operator-configured endpoint URLs (fleet health only)"
sensitive:
  storedPlaintext:
    - "~/.fleet/config.json: agent gateway auth tokens"
  hardening: "chmod 600 applied automatically by fleet init. Documented in SECURITY.md."
agentScope:
  permitted:
    - "Run fleet commands within operator-configured scope"
    - "Run fleet init to create config and link binary"
    - "Run fleet update after operator explicitly requests it"
  notPermitted:
    - "Implement fleet functionality by other means if fleet commands fail"
    - "Autonomously run system package managers (apt-get, brew, dnf, apk, etc.) to install dependencies"
    - "Run any command requiring root or sudo without explicit operator instruction in the current conversation"
    - "Read session files fleet did not create"
    - "Scan addresses outside operator config"
    - "Modify OpenClaw config files"
    - "Run commands outside fleet management"
---

# Fleet: Multi-Agent Fleet Management

## Intent, Authorization, and Trust

**Who this skill is for:** A coordinator AI agent that has been explicitly configured by its operator. Fleet is designed for OpenClaw, Claude Code, Codex, Cursor, Windsurf, and any coding agent or editor that can read a skill file and run shell commands. The operator installed this skill intentionally, knowing it enables autonomous fleet management.

**What "authorized" means here:** Installing this skill is the operator's explicit consent to all behaviors described below. The skill contacts only the operator's own agent gateways (loopback), the operator's own GitHub repos via their authenticated gh CLI, and api.github.com for fleet's own release updates (documented, non-blocking, once per 24h). It does not escalate privileges beyond the installing user's home directory and does not take any action outside the local fleet the operator already controls.

**Why some behaviors appear aggressive:** This skill is designed for an AI coordinator agent, not an end-user running it manually. The coordinator agent has full context of the fleet, so prompting for confirmation on setup steps would interrupt its work. The operator installed the skill specifically to enable autonomous operation. Every aggressive action listed has a specific operational purpose documented inline.

**What this skill never does (hard limits):**
- Never installs software that requires root or sudo without explicit operator instruction
- Never modifies files outside `~/.fleet/`, `~/.local/bin/`, and the shell rc files (`~/.bashrc`, `~/.zshrc`, `~/.profile`) of the installing user
- Never contacts external services except: (1) operator-configured agent gateways on loopback, (2) operator-configured endpoint URLs for health checks, (3) operator's GitHub repos via their authenticated gh CLI for CI status, (4) api.github.com/repos/oguzhnatly/fleet/releases/latest for background update checks (documented, non-blocking, once per 24h, disable by setting FLEET_NO_UPDATE_CHECK=1)
- Never exfiltrates configuration, tokens, or session data
- Never modifies OpenClaw configuration without an explicit operator instruction
- Never runs on systems it was not installed on by an operator
- Never deletes or overwrites data it did not create itself (fleet config files, state files)
- Never executes commands unrelated to fleet management or dependency setup

**Trust boundary:** All operations are local. Fleet communicates only with `127.0.0.1` (loopback) to reach the operator's own agent gateways. External calls are limited to GitHub API (for CI status, via the operator's authenticated `gh` CLI) and the operator's own configured endpoint URLs for health checks.

---

CLI toolkit for managing, dispatching to, and observing a fleet of OpenClaw agent gateways plus v4 runtimes such as HTTP services, Docker containers, and OS processes. The coordinator agent uses fleet to monitor employees, dispatch tasks, steer running sessions, watch live output, and review dispatch history.

## Security Model

Fleet operates within a strictly defined trust boundary. This section documents it explicitly so any security scanner, reviewer, or operator can verify the scope.

### Network scope
Fleet only makes HTTP connections to:
1. `127.0.0.1` loopback ports: the operator's own agent gateways (configured in `~/.fleet/config.json`)
2. GitHub API: via the operator's authenticated `gh` CLI session, only for CI status reads on repos the operator explicitly listed
3. URLs in `endpoints[]`: health checks to URLs the operator explicitly configured

Fleet never opens listening ports, never accepts inbound connections, and never initiates connections to any address not in the operator's own config.

### Filesystem scope
Fleet reads and writes only:
- `~/.fleet/`: fleet config, state, logs, backups (all created by fleet itself)
- `~/.local/bin/fleet`: a symlink to the fleet binary (created by `fleet init`, standard XDG location)
- Shell rc files (`~/.bashrc`, `~/.zshrc`, `~/.profile`): only to append `export PATH="$HOME/.local/bin:$PATH"` if not already present
- Session output for `fleet watch`: reads the specific session file fleet itself created for the named agent under `~/.openclaw*/agents/*/sessions/<fleet-session-id>.jsonl`. This file may contain conversation transcript data from that agent session. Fleet never reads sessions it did not create, other users' sessions, or the coordinator's main session (unless `--all` flag is explicitly passed).

Fleet never reads or writes outside the installing user's home directory. Fleet never accesses sessions it did not create. Fleet reads `~/.openclaw/openclaw.json` once during `fleet init` to auto-detect the workspace path (read-only, never written). Fleet never modifies OpenClaw config files.

### Credential scope
Fleet reads auth tokens from `~/.fleet/config.json` only. These tokens belong to the operator's own agents and are stored in plaintext in that file. Fleet never transmits them outside loopback. Fleet never reads other credential stores (ssh keys, cloud credentials, browser storage, OS keychain). Recommended hardening: `chmod 600 ~/.fleet/config.json`.

### Privilege scope
Fleet never calls `sudo`. Fleet never requests elevated permissions. All install commands that require system-level package managers (e.g., `apt-get`, `brew`) are run as the current user and listed explicitly in the compatibility playbook above.

---

## Quick Reference

| Situation | Action |
|-----------|--------|
| Send a task to an agent | `fleet task coder "add pagination to /api/spots"` |
| Watch what an agent is doing | `fleet watch coder` |
| Watch what the coordinator is doing | `fleet watch coordinator` |
| Send a mid-task correction | `fleet steer coder "also add rate limiting"` |
| Stop an agent's current task | `fleet kill coder` |
| See all recent dispatches and outcomes | `fleet log` |
| Decompose a task across multiple agents | `fleet parallel "<task>" --dry-run` (plan first, agents selected by trust) |
| Check if all agents are alive | `fleet agents` |
| Something feels wrong, need full picture | `fleet sitrep` |
| Quick health check | `fleet health` |
| Check CI across all repos | `fleet ci` |
| See which agents are most reliable | `fleet trust` |
| Drill into one agent's reliability | `fleet score coder` |
| Check reliability for a specific task type | `fleet score coder --type code` |
| Check CI for specific repo | `fleet ci <name>` |
| See what skills are installed | `fleet skills` |
| Backup everything before a change | `fleet backup` |
| Restore after something broke | `fleet restore` |
| First time setup | `fleet init` |
| User asks "how's the fleet?" | `fleet agents`, summarize |
| User asks "what changed?" | `fleet sitrep`, report deltas |
| Scheduled morning report | `fleet sitrep 12` in cron |
| Before deploying | `fleet health` + `fleet ci` |
| Register a non-OpenClaw target | `fleet runtime add <name> <type> [options]` (v4) |
| Probe one runtime end to end | `fleet runtime test <name>` (v4) |
| Live status of every runtime | `fleet runtime list` (v4) |
| List adapters and their bindings | `fleet adapters` (v4) |
| Show configured task rules | `fleet policy` |
| Toggle task rules | `fleet policy enable`, `fleet policy disable` |
| Add or remove a task rule | `fleet policy add "<rule>"`, `fleet policy rm <index>` |
| Preview rules applied to a task | `fleet policy preview <agent> "<prompt>"` |

## Operator Constitution

If `constitution.enabled` is true in the Fleet config, `fleet task` and `fleet parallel` prepend the configured rules to every dispatched task. Use this for operator rules that all agents should see before they act.

Example config:

```json
{
  "constitution": {
    "enabled": true,
    "title": "Operator Constitution",
    "mode": "prepend",
    "rules": [
      "Read project instructions before editing files",
      "Run verification before reporting completion",
      "Do not rewrite shared git history unless the operator explicitly declares an emergency"
    ]
  }
}
```

Useful commands:

```bash
fleet policy
fleet policy enable
fleet policy add "Run verification before reporting completion"
fleet policy rm 1
fleet policy preview coder "fix failing tests" --type code
```

Treat this as prompt level enforcement. It helps compliant coding agents follow the operator's rules, but it does not replace sandboxing, git hooks, CI, or human review.

## Auto-Setup

**Purpose:** These steps ensure the fleet binary is usable on first run. They only touch files the installing user already owns. No root access is needed or used.

**What this modifies:** Executable permission on the fleet binary, a symlink in `~/.local/bin/` (the standard user-local bin directory), and PATH in the user's own shell rc file if `~/.local/bin` is not already on PATH.

**Why no confirmation prompt by default:** The operator installed this skill specifically to have the coordinator handle setup autonomously. The consent to auto-setup is given at install time.

**Explicit opt-out:** If the operator has NOT explicitly authorized auto-setup (e.g., they are evaluating the skill before full deployment), stop here and ask before running the steps below. The question to ask: "Fleet needs to symlink its binary to `~/.local/bin/fleet` and may add a PATH export to your shell rc file. Is that OK?"

**Shell rc modification rule:** Only add the PATH export if `~/.local/bin` is not already on PATH. Check first with `echo $PATH | grep -q "$HOME/.local/bin"`. If it is already there, skip the rc modification entirely.

```bash
# 1. Make the binary executable: only affects the fleet script itself
chmod +x "$(dirname "$0")/bin/fleet"

# 2. Symlink into ~/.local/bin: user-owned directory, standard XDG location
ln -sf "$(dirname "$0")/bin/fleet" "$HOME/.local/bin/fleet"

# 3. Add to PATH only if not already present
if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    export PATH="$HOME/.local/bin:$PATH"
    # Append to shell rc only if not already there
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [ -f "$rc" ] && grep -q "local/bin" "$rc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
    done
fi

# 4. Create initial config if none exists: only writes to ~/.fleet/
if [ ! -f "$HOME/.fleet/config.json" ]; then
    fleet init
fi

# 5. Verify
fleet --version
```

`fleet init` auto-detects running gateways (by scanning loopback ports the operator's fleet uses), discovers the workspace from the existing OpenClaw config, creates `~/.fleet/config.json`, symlinks the binary, and adds `~/.local/bin` to PATH in shell rc files only if it is not already present. All changes are scoped to the installing user's home directory.

After init, populate `~/.fleet/config.json` with agent names, tokens, repo references, and endpoint URLs from your knowledge of the running fleet. The coordinator agent already knows this information.

### Via ClawHub

```bash
clawhub install fleet
```

### Manual

```bash
git clone https://github.com/oguzhnatly/fleet.git
fleet/bin/fleet init
```

## Configuration

Fleet reads `~/.fleet/config.json`. Generate one automatically or create manually.

### Auto-Detection Setup

```bash
fleet init
```

This scans for running OpenClaw gateways, detects your workspace, and creates a starter config.

### Manual Configuration

Create `~/.fleet/config.json`:

```json
{
  "workspace": "~/workspace",
  "gateway": {
    "port": 48391,
    "name": "coordinator",
    "role": "coordinator",
    "model": "strategic-default"
  },
  "agents": [
    {
      "name": "coder",
      "port": 48520,
      "role": "implementation",
      "model": "coding-default",
      "token": "your-agent-token"
    }
  ],
  "endpoints": [
    { "name": "website", "url": "https://example.com" }
  ],
  "repos": [
    { "name": "frontend", "repo": "myorg/frontend" }
  ]
}
```

### Configuration Reference

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `workspace` | string | Yes | Path to main workspace directory |
| `gateway.port` | number | Yes | Main coordinator gateway port |
| `gateway.name` | string | No | Display name (default: "coordinator") |
| `gateway.role` | string | No | Role description |
| `gateway.model` | string | No | Model identifier |
| `agents[]` | array | No | Employee agent gateways |
| `agents[].name` | string | Yes | Unique agent identifier |
| `agents[].port` | number | Yes | Gateway port number |
| `agents[].role` | string | No | What this agent does |
| `agents[].model` | string | No | Model used |
| `agents[].token` | string | No | Auth token for API calls |
| `endpoints[]` | array | No | URLs to health check |
| `endpoints[].name` | string | Yes | Display name |
| `endpoints[].url` | string | Yes | Full URL to check |
| `endpoints[].expectedStatus` | number | No | Expected HTTP code (default: 200) |
| `endpoints[].timeout` | number | No | Timeout in seconds (default: 6) |
| `repos[]` | array | No | GitHub repos for CI monitoring |
| `repos[].name` | string | Yes | Display name |
| `repos[].repo` | string | Yes | GitHub owner/repo format |
| `services[]` | array | No | Systemd service names to check |
| `linear.teams[]` | array | No | Linear team keys for ticket counts |
| `linear.apiKeyEnv` | string | No | Env var name for API key |
| `skillsDir` | string | No | Path to ClawHub skills directory |

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FLEET_CONFIG` | Path to config file | `~/.fleet/config.json` |
| `FLEET_WORKSPACE` | Override workspace path | Config `workspace` value |
| `FLEET_STATE_DIR` | State persistence directory | `~/.fleet/state` |
| `NO_COLOR` | Disable colored output when set | (unset) |

## Commands: Detailed Reference

### `fleet task <agent> "<prompt>"`

Dispatches a task to a named agent and streams the response live.

**Requires:** Agent token in `~/.fleet/config.json` under `agents[].token`.

**Options:**
- `--type code|review|research|deploy|qa`: override task type (auto-inferred from prompt if omitted)
- `--timeout <minutes>`: response timeout (default: 30)
- `--no-wait`: fire and forget, return immediately

**Output:**
```
Fleet Task
──────────
  Agent     coder (port 48520)
  Type      code
  Task ID   a1b2c3d4
  Timeout   30m

  add pagination to /api/spots endpoint

  ────────────────────────────────────────
  [streams response in real time]
  ────────────────────────────────────────
  ✅  Task complete  (a1b2c3d4)
```

**Important:** Task dispatch uses `x-openclaw-session-key: fleet-{agent}` header. All tasks to the same agent share a session, so the agent has context of prior tasks.

### `fleet steer <agent> "<message>"`

Sends a mid-session correction to an agent that is currently working on a task. Routes to the same session as `fleet task`, so the agent has full context.

**Output:**
```
Fleet Steer
───────────
  Agent    coder
  Session  fleet-coder

  ────────────────────────────────────────
  [agent response to correction]
  ────────────────────────────────────────
  ✅  Steered.
```

### `fleet watch <agent> [--all]`

Live tail of the agent's active fleet session output. Polls the session file that fleet itself created for that agent, showing new messages as they arrive.

- Default: watches the `fleet-{agent}` session (the one fleet task created)
- `--all`: watches the agent's full main session
- `coordinator`: always watches the main coordinator session

**Output:**
```
Watching coder
──────────────
  Session: agent:main:fleet-coder
  File: b80eb2e5.jsonl: polling every 3s: Ctrl+C to stop

  Last 2 message(s):

  you             16:37 UTC
  add pagination to /api/spots

  coder           16:37 UTC
  Starting with the cursor-based approach...
```

**Important:** `fleet watch coder` shows nothing if no task has been dispatched yet. Run `fleet task coder "<prompt>"` first to create the fleet session. Use `fleet watch coder --all` to see the agent's full history.

### `fleet kill <agent> [--force]`

Sends a graceful stop signal to the agent's fleet session. The agent acknowledges and archives the session. Marks all pending log entries for that agent as `steered`.

### `fleet parallel "<task>" [--dry-run]`

Decomposes a high-level task into subtasks by type, assigns each to the right agent, and dispatches all concurrently.

**Always use `--dry-run` first** to review the decomposition plan before executing. Requires confirmation before actual dispatch.

**Output with `--dry-run`:**
```
Fleet Parallel
──────────────
  Task: research competitor pricing and build a pricing page

  Execution plan:

  1. researcher    [research]
     Research phase: ...

  2. coder         [code]
     Implementation: ...

  ────────────────────────────────────────
  2 subtask(s) ready to dispatch in parallel.

  ℹ️  Dry run complete. Remove --dry-run to execute.
```

### `fleet log [--agent <name>] [--outcome <status>] [--limit <n>] [--all]`

Shows the dispatch history for all fleet tasks. Filterable by agent, outcome, and count.

**Outcomes:** `success`, `failure`, `timeout`, `steered`, `pending`

**Output:**
```
Fleet Log  3 entries

  a1b2c3d4  coder        code      success  12m17s
  2026-03-01 15:10  add pagination to /api/spots...
```

### `fleet trust [--window <hours>] [--json]`

Shows the trust matrix for all configured agents, computed from `~/.fleet/log.jsonl`.

Trust is a single composite score per agent derived from the formula:

```
trust_score = quality_score × speed_multiplier
```

- **quality_score**: weighted average of per-task outcomes. `success`=1.0, `steered`=0.5, `failure`/`timeout`=0.0. Each steer within a task degrades the score by up to 30%.
- **speed_multiplier**: 1.0 if avg task duration ≤5min, down to 0.5 for >30min.
- **Recency**: tasks within the window (default 72h) count 2×. Tasks within 7 days count 1×. Older tasks count 0.5×.
- **Trend**: compares last 7 days vs prior 7 days. `↑` improved, `↓` degraded, `→` stable, `★` new agent.

**Output:**
```
Fleet Trust Matrix  | 2026-03-15 14:00 UTC | 72h window
─────────────────────────────────────────────────────────────────────

  reviewer         ████████████████░░░░   93%  3 tasks    →  review:95%
  coder            █████████████░░░░░░░   76%  12 tasks   ↑  code:78%  review:70%
  deployer         █████████░░░░░░░░░░░   55%  5 tasks    ↓  deploy:55%
```

Use `--json` for structured output (piping, scripting).

**When to use:** Before running `fleet parallel` on a critical task. Before assigning a new task to understand which agent is currently most reliable. After a steer-heavy session to assess whether an agent needs correction.

**Note:** `fleet sitrep` also shows a one-line trust summary. `fleet trust` gives the full matrix.

---

### `fleet score [<agent>] [--window <hours>] [--type <task_type>]`

Shows a detailed per-task-type reliability breakdown for one agent (or a summary table for all).

**Output (single agent):**
```
fleet score  coder
────────────────────────────────────────────────────────────

  Overall           ██████████████░░░░░░   76%  ↑ from 68%
  Tasks: 12  Window: 72h  Avg duration: 11.2m  Speed mult: 0.90

  By task type:
  code            ████████████████░░░░   79%   9 tasks  9✓
  review          ████████████░░░░░░░░   68%   2 tasks  1✓  1⤷
  research        ██████████████░░░░░░   72%   1 task   1✓

  Recent tasks:
  ✓  aaa00001  code        2h ago    8m12s
     add pagination to /api/spots
  ⤷  bbb00002  code        5h ago    18m04s   ⤷1
     fix auth flow in mobile app
```

**Cross-validation (v3.5):** For agents with code or deploy successes, `fleet score` cross-checks whether a GitHub CI run completed within 1 hour of each task. Tasks with no corresponding CI activity are flagged as unverified. Requires `gh` CLI and `repos` in config.

**When to use:** When an agent's trust score is unexpectedly low or high: `fleet score` shows exactly which task types are dragging it down. Use `--type code` to see only code-task history.

---

### `fleet health`

Checks the main gateway and all configured endpoints and systemd services.

**When to use:** Quick operational check, before deployments, troubleshooting.

**Output:**
```
Fleet Health Check
──────────────────
  ✅ coordinator (:48391) 12ms
  
Endpoints
  ✅ website (200) 234ms
  ✅ api (200) 89ms
  ❌ docs UNREACHABLE

Services
  ✅ openclaw-gateway
  ❌ openclaw-gateway-coder (inactive)
```

**Status codes:**
- `✅`: healthy (HTTP 200 or expected status)
- `❌`: unhealthy (wrong status, unreachable, or error)
- Shows response time in milliseconds

### `fleet agents`

Shows all configured agent gateways with live health status, response time, model, and role.

**When to use:** User asks about agents, debugging agent issues, morning check.

**Output:**
```
Agent Fleet
───────────
  ⬢ coordinator      coordinator      strategic-default               :48391 online 13ms
  
  ⬢ coder            implementation   coding-default                       :48520 online 8ms
  ⬢ reviewer         code-review      coding-default                       :48540 online 9ms
  ⬡ deployer         deployment       coding-default                       :48560 unreachable
  ⬢ qa               quality-assurance coding-default                      :48580 online 7ms
```

**Status indicators:**
- `⬢` green = online
- `⬡` red = unreachable or error
- `⬡` yellow = auth failed (token issue)

### `fleet sitrep [hours]`

The flagship command. Generates a structured status report with delta tracking.

**When to use:** Morning reports, scheduled crons, "what changed?" questions, incident response.

**Arguments:**
- `hours`: lookback period (default: 4). Only affects display context, deltas are always vs last run.

**What it checks:**
1. All agent gateways (online/offline)
2. CI status for all configured repos
3. All configured endpoint health
4. Linear ticket counts per team
5. VPS resource usage (memory, disk)

**Delta tracking:** State is saved to `~/.fleet/state/sitrep.json`. Each run compares against the previous and only shows what CHANGED.

**Output:**
```
SITREP | 2026-02-23 08:00 UTC | vs 2026-02-22 23:00
────────────────────────────────────────────────────────────

Agents  5/6 online
  ⬢ coordinator
  ⬢ coder
  ⬢ reviewer
  ⬡ deployer
  ⬢ qa
  ⬢ researcher

CI
  ✅ frontend
  ❌ backend
  ✅ mobile

Services
  ✅ website (200)
  ✅ api (200)

CHANGED
  → agent deployer: online → offline
  → CI backend: green → RED
  → OZZ tickets: +3

Resources  mem 45% | disk 7%
Linear    OZZ: 12 open | FRI: 8 open
```

**Cron integration example:**
```json
{
  "schedule": { "kind": "cron", "expr": "0 8,12 * * *", "tz": "Europe/London" },
  "payload": {
    "kind": "agentTurn",
    "message": "Run fleet sitrep and post results to the team channel"
  }
}
```

### `fleet ci [filter]`

Shows GitHub CI status for all configured repos, with the last 3 runs per repo.

**When to use:** Before pushing, after deployments, investigating failures.

**Requirements:** `gh` CLI must be installed and authenticated.

**Arguments:**
- `filter`: optional, filters repos by name (case-insensitive)

**Output:**
```
CI Status
─────────

  frontend (myorg/frontend)
    ✅ Update homepage (main) passed 2026-02-23T08:00
    ✅ Fix footer (main) passed 2026-02-23T07:30
    ✅ Add banner (main) passed 2026-02-23T07:00

  backend (myorg/backend)
    ❌ Add endpoint (main) failed 2026-02-23T08:15
    ✅ Fix auth (main) passed 2026-02-23T07:45
```

### `fleet skills`

Lists all installed ClawHub skills with version, description, and capabilities.

**When to use:** Inventory check, "what can I do?", planning.

**Output:**
```
Installed Skills
────────────────
from ~/workspace/skills

  ● fleet v1.0.0 [scripts]
    Multi-agent fleet management CLI for OpenClaw
  ● ontology v0.1.2 [scripts]
    Typed knowledge graph for structured agent memory
  ● self-improving-agent v1.0.11 [scripts, hooks]
    Captures learnings, errors, and corrections
```

### `fleet backup`

Backs up OpenClaw config, cron jobs, fleet config, and auth profiles.

**When to use:** Before major changes, before updates, periodic safety net.

**Backup location:** `~/.fleet/backups/<timestamp>/`

### `fleet restore`

Restores from the latest backup.

**When to use:** After a bad config change, after a failed update.

**Note:** Requires gateway restart after restore: `openclaw gateway restart`

### `fleet init`

Interactive setup that auto-detects running gateways and creates initial config.

**When to use:** First time setup, new machine, new fleet.

**Auto-detection:**
- Scans common gateway ports (48391, then every 20 ports up to 48600)
- Reads workspace from `~/.openclaw/openclaw.json`
- Discovers running employee gateways

### `fleet update`

Self-upgrade command. Fetches the latest release from GitHub and installs automatically.

```
fleet update             Install latest release when a newer one exists
fleet update --check     Report available update without installing
fleet update --force     Reinstall even when already on latest
```

**Version banner:** When a newer release is available, every fleet command prints a one-line
warning on stderr before its output:

```
fleet v3.1.0 is available. Run  fleet update  to upgrade from v3.0.0.
```

The GitHub check runs as a detached background process once per 24 hours so there
is zero latency impact on normal fleet commands. The result is cached at
`~/.fleet/state/update_check.json`.

### `fleet adapters`

Lists every adapter the fleet knows about, marked **verified** when the adapter
performs a real protocol-level handshake or **inferred** when it only detects
presence. Also shows the binding from each agent and runtime entry to its
adapter, so you can see at a glance which runtime probe runs against each
target.

### `fleet runtime add <name> <type> [options]`

Registers a new entry under the `runtimes` key in `~/.fleet/config.json`
without manual JSON editing.

**Adapter types and required options:**

| Type | Required | Common options |
|------|----------|----------------|
| `openclaw` | `--port=<n>` | `--host`, `--token`, `--role`, `--model` |
| `http`     | `--url=<URL>` | `--expected-status`, `--method`, `--token`, `--header K=V`, `--version-url` |
| `docker`   | `--container=<name>` | `--role`, `--model` |
| `process`  | `--process=<pat>` | `--match-full`, `--role` |

Examples:

```bash
fleet runtime add billing-api http --url=https://billing.example.com/health
fleet runtime add postgres docker --container=postgres
fleet runtime add tailscale process --process=tailscaled
fleet runtime add overflow openclaw --port=48490 --token=$OVERFLOW_TOKEN
```

The command refuses a name already used by an agent and writes the config
atomically with `chmod 600`.

### `fleet runtime test <name>`

One-off probe of a runtime or agent. Animates a spinner while the health,
info, and version probes run in parallel, then renders all three sections.
Use when a runtime turns red in `sitrep` and you need a focused look.

### `fleet runtime list`

Live status of every registered runtime, probed in parallel with an animated
progress indicator on TTY output.

### `fleet runtime rm <name>`

Removes a runtime from the config. Returns a clear error if the name is
not found.

### Custom Adapters

Drop a `<type>.sh` file into `~/.fleet/adapters/` (or `FLEET_ADAPTERS_DIR`)
with these six functions: `adapter_<type>_describe`, `adapter_<type>_verified`
(echo `verified` or `inferred`), `adapter_<type>_required`, `adapter_<type>_health`,
`adapter_<type>_info`, `adapter_<type>_version`. Each must complete within
`FLEET_ADAPTER_TIMEOUT` seconds (default 6) and emit JSON on stdout. The
runtime registry validates required fields per adapter before saving.

## Fleet Patterns

Fleet supports multiple organizational architectures. Choose based on your needs:

### Solo Empire
One coordinator, 2-5 employees. Best for indie hackers and solo founders.

```
         Coordinator (strategic)
        /     |      \
    Coder  Reviewer  Deployer
   (coding)  (coding)   (coding)
```

### Development Team
Team leads coordinating specialized developers. Best for complex products.

```
              Orchestrator (strategic)
            /        |         \
      FE Lead     BE Lead     QA Lead
     (review)    (review)    (review)
       / \          |           |
    Dev1  Dev2    Dev1       Tester
```

### Research Lab
Specialized agents for knowledge work. Best for content and analysis.

```
            Director (strategic)
          /     |      \       \
    Scraper  Analyst  Writer  Fact-Check
```

See `examples/` in the repo for ready-to-use config files for each pattern.

## Troubleshooting

### Common Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `fleet: command not found` | Not in PATH | `ln -sf path/to/fleet/bin/fleet ~/.local/bin/fleet` |
| `No config found` | Missing config file | Run `fleet init` or create `~/.fleet/config.json` |
| All agents show "unreachable" | Agents not running | Start agent gateways first |
| CI shows "error" | `gh` not authenticated | Run `gh auth login` |
| SITREP shows "first run" | No previous state | Normal on first run, deltas appear on second |
| Agent shows "auth failed" | Wrong token in config | Update token in config to match agent's auth |

### Debugging

```bash
# Check if fleet can find its config
echo $FLEET_CONFIG
cat ~/.fleet/config.json

# Check if agents are reachable directly
curl -s http://127.0.0.1:48520/health

# Check state directory
ls -la ~/.fleet/state/

# Run with verbose output
bash -x fleet health
```

## Architecture

Fleet is modular. Each component has a single responsibility:

```
fleet/
├── bin/fleet              # Entry point: command router only
├── lib/
│   ├── core/
│   │   ├── config.sh      # Config loading and JSON parsing
│   │   ├── output.sh      # Colors, formatting, HTTP helpers
│   │   └── state.sh       # Delta state persistence
│   └── commands/           # One file per command
│       ├── agents.sh
│       ├── backup.sh
│       ├── ci.sh
│       ├── health.sh
│       ├── init.sh
│       ├── sitrep.sh
│       └── skills.sh
├── templates/configs/      # Config templates (minimal + full)
├── examples/               # Pattern examples with configs
├── docs/                   # Extended documentation
└── tests/                  # Integration tests
```

**Adding new commands:** Create `lib/commands/yourcommand.sh`, define `cmd_yourcommand()`, add a case in `bin/fleet`.

## Integration with Other Skills

### With `ontology` skill
If the ontology skill is installed, fleet can query the knowledge graph:
```bash
# After installing: clawhub install ontology
fleet ontology          # Summary of all entities
fleet ontology Project  # List all projects
```

### With `self-improving-agent` skill
Log fleet operational learnings to `.learnings/`:
- Agent downtime patterns → `ERRORS.md`
- CI failure patterns → `LEARNINGS.md`
- Configuration improvements → promote to `TOOLS.md`

## Dependency Installation

Fleet requires three things: **bash 4+**, **python3 3.10+**, and **curl**. Below is the complete platform-by-platform installation reference. Install the missing dependencies, then run `fleet init`.

**Operator action required:** The commands in this section are for the operator to run manually, not for the agent to run autonomously. The agent must not run system package managers on the operator's behalf. If a dependency is missing, the agent reports it and the operator installs it using the appropriate command below.

Where root is required (e.g., `apt-get` on some systems), the command is shown explicitly. Prefer user-level installs (`--user`, `pyenv`, `$HOME/.local`) when root is not available.

### Step 1: Check What You Have

```bash
# Run these first. Know your environment.
bash --version 2>/dev/null | head -1
python3 --version 2>/dev/null
curl --version 2>/dev/null | head -1
uname -s  # Linux, Darwin, FreeBSD, etc.
cat /etc/os-release 2>/dev/null | head -3  # Distro info
```

### Step 2: Install Missing Dependencies

#### bash 4+

| Platform | Command |
|----------|---------|
| **macOS** (ships bash 3.2) | `brew install bash`: then fleet auto-detects `/opt/homebrew/bin/bash` via `#!/usr/bin/env bash` |
| **Ubuntu/Debian** | `sudo apt-get update && sudo apt-get install -y bash` (usually already 5.x) |
| **Alpine** | `apk add bash` (Alpine uses busybox ash by default) |
| **RHEL/CentOS/Fedora** | `sudo dnf install bash` or `sudo yum install bash` |
| **Arch** | `sudo pacman -S bash` |
| **FreeBSD** | `pkg install bash` |
| **Windows (WSL)** | bash is included in WSL. If using Git Bash, it ships bash 4+. |
| **Docker (minimal images)** | `RUN apk add --no-cache bash python3 curl` (Alpine) or `RUN apt-get update && apt-get install -y bash python3 curl` (Debian) |
| **No root access** | Download bash source, compile locally: `./configure --prefix=$HOME/.local && make && make install`: then `export PATH="$HOME/.local/bin:$PATH"` |
| **NixOS** | `nix-env -iA nixpkgs.bash` |

**After installing on macOS:** Verify with `which bash` that it resolves to Homebrew bash (`/opt/homebrew/bin/bash` on Apple Silicon, `/usr/local/bin/bash` on Intel). The `#!/usr/bin/env bash` shebang picks up whichever `bash` is first in PATH.

#### python3 3.10+

| Platform | Command |
|----------|---------|
| **macOS** | `brew install python@3.12` |
| **Ubuntu/Debian** | `sudo apt-get install -y python3` |
| **Alpine** | `apk add python3` |
| **RHEL/CentOS** | `sudo dnf install python3` |
| **Arch** | `sudo pacman -S python` |
| **No root access** | Use `pyenv`: `curl https://pyenv.run \| bash && pyenv install 3.12 && pyenv global 3.12` |

**Fleet uses python3 only for JSON parsing.** No pip packages needed. No virtual environment needed. Just the interpreter.

#### curl

| Platform | Command |
|----------|---------|
| **Almost everywhere** | Pre-installed. Check with `curl --version`. |
| **Alpine** | `apk add curl` |
| **Minimal Docker** | `apt-get install -y curl` or `apk add curl` |

#### gh CLI (optional, for `fleet ci`)

| Platform | Command |
|----------|---------|
| **macOS** | `brew install gh` |
| **Ubuntu/Debian** | See [cli.github.com/packages](https://cli.github.com/packages) |
| **Any** | `conda install gh --channel conda-forge` |

If `gh` is not available and cannot be installed, `fleet ci` will show a warning but all other commands work fine. Do not let a missing `gh` block fleet setup.

### Step 3: If You Truly Cannot Get bash 4+

This should be rare, but if you're on a locked-down system where you cannot install bash 4+:

1. **Try running with bash 3.2 anyway.** Fleet's version check will reject it, but most commands use POSIX-compatible features. Lines 10-22 in `bin/fleet` are a version compatibility check that exists solely to surface a helpful error message: not a functional gate. Disabling that check does not affect how any command runs. Many commands will still work on bash 3.2. Test each one and report results.

2. **Report compatibility issues.** If fleet cannot run due to a bash version or missing dependency, report the exact error and the output of `bash --version`, `python3 --version`, and `curl --version` to the operator. Ask the operator to install the missing dependency using the platform table in Step 2. Do not attempt to replicate fleet functionality by other means.

**Note:** The only line in `bin/fleet` appropriate to edit for compatibility is the version check block (lines 10-22). That block exists purely to show a helpful error message. Every other part of the scripts implements the actual command logic and should not be edited.

### Step 4: Environments Without Required Dependencies

Fleet requires bash 4+, python3 3.10+, and curl. If these cannot be installed in the current environment, fleet cannot run there. Report the missing dependency to the operator and ask them to provide an environment where the prerequisites are available. Do not attempt to replicate fleet functionality by other means.

## Best Practices

1. **Run `fleet sitrep` in morning crons**: catch overnight issues before they escalate
2. **Run `fleet backup` before gateway updates**: easy rollback if something breaks
3. **Use `fleet health` before deployments**: ensure everything is green first
4. **Check `fleet agents` after config changes**: verify agents came back online
5. **Filter `fleet ci` by repo**: avoid noise when debugging a specific service
6. **Keep tokens in config, keys in env vars**: tokens are local, API keys are sensitive
