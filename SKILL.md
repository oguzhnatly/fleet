---
name: fleet
description: "Multi-agent fleet management CLI for OpenClaw. Use when: (1) checking health of agent gateways, (2) running structured status reports (SITREP) with delta tracking, (3) monitoring CI across repos, (4) listing installed skills, (5) backing up agent configs, (6) initializing a new fleet. Triggers: 'check agents', 'fleet status', 'run sitrep', 'health check', 'backup config', 'show agents', 'fleet report', 'how many agents online', 'CI status', 'what skills installed'."
---

# Fleet — Multi-Agent Fleet Management

CLI toolkit for managing a fleet of OpenClaw agent gateways. Designed for the coordinator agent to monitor and manage employee agents, track CI, run status reports, and maintain operational awareness.

## Quick Reference

| Situation | Action |
|-----------|--------|
| Check if all agents are alive | Run `fleet agents` |
| Something feels wrong, need full picture | Run `fleet sitrep` |
| Quick health check | Run `fleet health` |
| Check CI across all repos | Run `fleet ci` |
| Check CI for specific repo | Run `fleet ci <name>` |
| See what skills are installed | Run `fleet skills` |
| Backup everything before a change | Run `fleet backup` |
| Restore after something broke | Run `fleet restore` |
| First time setup | Run `fleet init` |
| User asks "how's the fleet?" | Run `fleet agents`, summarize |
| User asks "what changed?" | Run `fleet sitrep`, report deltas |
| Scheduled morning report | Run `fleet sitrep 12` in cron |
| Before deploying | Run `fleet health` + `fleet ci` |

## Installation

### Via ClawHub (recommended)

```bash
clawhub install fleet
```

Then link the binary so it's in your PATH:

```bash
ln -sf ~/.openclaw/skills/fleet/bin/fleet ~/.local/bin/fleet
chmod +x ~/.openclaw/skills/fleet/bin/fleet
```

### Manual Installation

```bash
git clone https://github.com/oguzhnatly/fleet.git
ln -sf $(pwd)/fleet/bin/fleet ~/.local/bin/fleet
```

### Verify Installation

```bash
fleet --version
# fleet v1.0.0

fleet help
# Shows all available commands
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

## Commands — Detailed Reference

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
- `✅` — healthy (HTTP 200 or expected status)
- `❌` — unhealthy (wrong status, unreachable, or error)
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
- `hours` — lookback period (default: 4). Only affects display context, deltas are always vs last run.

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
- `filter` — optional, filters repos by name (case-insensitive)

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
├── bin/fleet              # Entry point — command router only
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

## Requirements

- **bash 4+** — the shell
- **python3 3.10+** — for JSON parsing (no pip packages needed)
- **curl** — for HTTP health checks (pre-installed on most systems)
- **OpenClaw** — the agent gateway platform
- **gh CLI** — optional, for CI monitoring commands

## Best Practices

1. **Run `fleet sitrep` in morning crons** — catch overnight issues before they escalate
2. **Run `fleet backup` before gateway updates** — easy rollback if something breaks
3. **Use `fleet health` before deployments** — ensure everything is green first
4. **Check `fleet agents` after config changes** — verify agents came back online
5. **Filter `fleet ci` by repo** — avoid noise when debugging a specific service
6. **Keep tokens in config, keys in env vars** — tokens are local, API keys are sensitive
