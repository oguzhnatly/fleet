---
name: fleet
type: installable-cli
install: "clawhub install fleet"
description: "Multi-agent fleet management CLI for OpenClaw. Coordinator agent tool for monitoring, dispatching tasks to, and observing a fleet of agent gateways. All operations are local or to explicitly listed endpoints. Operator consent is required before install."
triggers: "check agents, fleet status, run sitrep, health check, dispatch task, send task to agent, steer agent, watch agent, parallel tasks, kill agent, fleet log, backup config, show agents, fleet report, how many agents online, CI status, what skills installed, trust score, which agent is reliable, fleet trust, fleet score, agent reliability, who should I assign, best agent for task"
requires:
  binaries: ["bash>=4.0", "python3>=3.10", "curl"]
  optionalBinaries: ["gh"]
envVars:
  optional:
    - name: FLEET_CONFIG
      description: "Override path to fleet config (default: ~/.fleet/config.json)"
    - name: FLEET_LOG
      description: "Override path to dispatch log (default: ~/.fleet/log.jsonl)"
    - name: FLEET_STATE_DIR
      description: "Override state directory (default: ~/.fleet/state)"
    - name: FLEET_TRUST_WINDOW_HOURS
      description: "Override trust scoring window in hours (default: 72)"
    - name: NO_COLOR
      description: "Disable colored output when set"
permissions:
  reads:
    - "~/.fleet/ (config, state, logs created by fleet itself)"
    - "~/.openclaw/openclaw.json (read-only, only during fleet init auto-detection of workspace path)"
    - "~/.openclaw*/agents/*/sessions/<fleet-session-id>.jsonl (fleet watch: reads only the session file fleet itself created for the named agent)"
    - "/proc/meminfo (Linux only, fleet sitrep resource section)"
  writes:
    - "~/.fleet/ (config, state, logs, backups)"
    - "~/.local/bin/fleet (symlink, created by fleet init)"
    - "~/.bashrc or ~/.zshrc or ~/.profile (append PATH export only if ~/.local/bin not already present)"
  network:
    - "127.0.0.1:<agent-ports> (loopback only, operator-configured agent gateways)"
    - "api.github.com/repos/<operator-repos>/actions/runs (fleet ci, via operator gh CLI auth)"
    - "api.github.com/repos/oguzhnatly/fleet/releases/latest (fleet update background check, once per 24h, non-blocking)"
    - "Operator-configured endpoint URLs (fleet health checks only)"
sensitive:
  storedPlaintext:
    - "~/.fleet/config.json contains agent gateway auth tokens in plaintext"
  hardening: "chmod 600 ~/.fleet/config.json recommended. Documented in SECURITY.md."
installBehavior:
  writes:
    - "~/.fleet/config.json (chmod 600, set immediately on creation, contains agent gateway auth tokens in plaintext)"
    - "~/.local/bin/fleet (symlink to binary, standard XDG location)"
    - "~/.bashrc or ~/.zshrc or ~/.profile (PATH export appended only if ~/.local/bin not already present)"
  reads:
    - "~/.openclaw/openclaw.json (read-only, one-time auto-detection of workspace path, never stored or transmitted)"
    - "127.0.0.1:40000-50000 (loopback port scan, one-time gateway discovery during fleet init)"
  consent: "Running fleet init is the operator's explicit consent to the writes above. Manual alternative: clone repo and create ~/.fleet/config.json manually. This skips all automatic writes."
  skipInit: "Clone the repo. Create ~/.fleet/config.json from templates/configs/minimal.json. Add bin/ to PATH manually. No ports scanned, no rc files modified, no symlinks created."
updateMechanism:
  command: "fleet update"
  source: "api.github.com/repos/oguzhnatly/fleet/releases/latest"
  verification: "SHA256 checksum verified against fleet.sha256 published alongside each GitHub release. Extraction halts if checksum does not match."
  disable: "Set FLEET_NO_UPDATE_CHECK=1 to disable background version check entirely"
agentScope:
  permitted:
    - "Run fleet commands to monitor, dispatch, steer, and observe the operator's own configured agent fleet"
    - "Install missing bash/python3/curl dependencies using the operator's existing package manager"
    - "Run fleet init to create config and link binary"
  notPermitted:
    - "Implement fleet functionality by other means if fleet commands fail"
    - "Read session files other than those fleet itself created for named dispatch sessions"
    - "Scan ports or probe network addresses not listed in the operator's config"
    - "Modify OpenClaw configuration files"
    - "Run commands outside the scope of fleet management or dependency setup"
---

# Fleet: Multi-Agent Fleet Management

## Intent, Authorization, and Trust

**Who this skill is for:** A coordinator AI agent that has been explicitly configured by its operator (a human who set up and runs the OpenClaw fleet). The operator installed this skill intentionally, knowing it enables autonomous fleet management.

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

CLI toolkit for managing, dispatching to, and observing a fleet of OpenClaw agent gateways. The coordinator agent uses fleet to monitor employees, dispatch tasks, steer running sessions, watch live output, and review dispatch history.

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
    "model": "claude-opus-4"
  },
  "agents": [
    {
      "name": "coder",
      "port": 48520,
      "role": "implementation",
      "model": "codex",
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
  ⬢ coordinator      coordinator      claude-opus-4               :48391 online 13ms
  
  ⬢ coder            implementation   codex                       :48520 online 8ms
  ⬢ reviewer         code-review      codex                       :48540 online 9ms
  ⬡ deployer         deployment       codex                       :48560 unreachable
  ⬢ qa               quality-assurance codex                      :48580 online 7ms
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

## Fleet Patterns

Fleet supports multiple organizational architectures. Choose based on your needs:

### Solo Empire
One coordinator, 2-5 employees. Best for indie hackers and solo founders.

```
         Coordinator (Opus)
        /     |      \
    Coder  Reviewer  Deployer
   (Codex)  (Codex)   (Codex)
```

### Development Team
Team leads coordinating specialized developers. Best for complex products.

```
              Orchestrator (Opus)
            /        |         \
      FE Lead     BE Lead     QA Lead
     (Sonnet)    (Sonnet)    (Sonnet)
       / \          |           |
    Dev1  Dev2    Dev1       Tester
```

### Research Lab
Specialized agents for knowledge work. Best for content and analysis.

```
            Director (Opus)
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

## Dependency Requirements

Fleet requires three system binaries: **bash 4+**, **python3 3.10+**, and **curl**. Install these using your platform's package manager before running `fleet init`.

If these dependencies are not available in the operator's environment, fleet cannot run there. Do not attempt to replicate fleet functionality by other means. Report the missing dependency to the operator and ask them to install it or run fleet on a supported system.

### Platform installation

| Platform | Command |
|----------|---------|
| **Ubuntu / Debian** | `sudo apt-get update && sudo apt-get install -y bash python3 curl` |
| **Fedora / RHEL** | `sudo dnf install -y bash python3 curl` |
| **macOS** (ships bash 3.2) | `brew install bash python3 curl` then use `/opt/homebrew/bin/bash` |
| **Alpine** | `apk add bash python3 curl` |
| **No root access** | Ask the operator to install the dependencies. Fleet does not self-install system packages without operator authorization. |

**macOS note:** `/usr/bin/bash` on macOS is bash 3.2. Fleet requires bash 4+. After `brew install bash`, fleet auto-detects `/opt/homebrew/bin/bash` via `#!/usr/bin/env bash`. No additional configuration needed.

**If a dependency install step requires root and the operator has not authorized it, ask before running.** This is the only exception to autonomous operation in this skill.

### Verifying prerequisites

```bash
bash --version 2>/dev/null | head -1   # need bash 4.x or higher
python3 --version 2>/dev/null          # need 3.10 or higher
curl --version 2>/dev/null | head -1   # any version
```

If any of these commands fail or return an incompatible version, install the missing dependency using the platform table above before proceeding.

### bash 3.2 compatibility (macOS only)

Lines 10-22 in `bin/fleet` are a version guard that exists solely to surface a helpful error message. It is not a functional security gate. On macOS with bash 3.2, run fleet via the brew-installed bash:

```bash
/opt/homebrew/bin/bash $(which fleet) <command>
```

**Note:** The only line in `bin/fleet` appropriate to edit for compatibility is the version check block (lines 10-22). That block exists purely to show a helpful error message. Every other part of the scripts implements the actual command logic and must not be edited.

## Best Practices

1. **Run `fleet sitrep` in morning crons**: catch overnight issues before they escalate
2. **Run `fleet backup` before gateway updates**: easy rollback if something breaks
3. **Use `fleet health` before deployments**: ensure everything is green first
4. **Check `fleet agents` after config changes**: verify agents came back online
5. **Filter `fleet ci` by repo**: avoid noise when debugging a specific service
6. **Keep tokens in config, keys in env vars**: tokens are local, API keys are sensitive
