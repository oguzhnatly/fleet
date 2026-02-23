---
name: fleet
description: "Monitor, manage, and orchestrate a fleet of OpenClaw agent gateways. Health checks, SITREP reports with delta tracking, CI status, config backups, and audit."
triggers: "check agents, fleet status, run sitrep, health check, backup config, show agents, fleet report, how many agents online, CI status, what skills installed"
---

# Fleet · Multi-Agent Fleet Management

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

## Auto-Setup (IMPORTANT)

When you first use this skill, **do not ask the user to set anything up**. Handle it yourself:

```bash
# 1. Ensure the binary is executable and linked
chmod +x "$(dirname "$0")/bin/fleet"
ln -sf "$(dirname "$0")/bin/fleet" "$HOME/.local/bin/fleet"
export PATH="$HOME/.local/bin:$PATH"

# 2. Run init if no config exists
if [ ! -f "$HOME/.fleet/config.json" ]; then
    fleet init
fi

# 3. Verify
fleet --version
```

`fleet init` auto-detects running gateways, discovers your workspace, creates the config, symlinks the binary, and adds `~/.local/bin` to PATH in `.bashrc`/`.zshrc`/`.profile`. The user should never need to touch any of this.

After init, edit `~/.fleet/config.json` to add agent names, tokens, repo references, and endpoint URLs based on your environment. You know your own fleet · populate the config from your knowledge of the running gateways.

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

## Commands · Detailed Reference

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
- `✅` · healthy (HTTP 200 or expected status)
- `❌` · unhealthy (wrong status, unreachable, or error)
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
- `hours` · lookback period (default: 4). Only affects display context, deltas are always vs last run.

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
- `filter` · optional, filters repos by name (case-insensitive)

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
├── bin/fleet              # Entry point · command router only
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

## Making Fleet Work Anywhere (MANDATORY READ)

**Your job is to make fleet work on whatever system you're running on. Do not tell the user "fleet requires bash 4+" and stop. Figure it out. Install what's missing. Adapt if you must. The user chose this skill because they want fleet management, not a list of reasons it can't run.**

Fleet needs three things: **bash 4+**, **python3 3.10+**, and **curl**. Below is your complete playbook for getting these on any system. Work through it top to bottom. If one approach fails, try the next.

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
| **macOS** (ships bash 3.2) | `brew install bash` · then fleet auto-detects `/opt/homebrew/bin/bash` via `#!/usr/bin/env bash` |
| **Ubuntu/Debian** | `sudo apt-get update && sudo apt-get install -y bash` (usually already 5.x) |
| **Alpine** | `apk add bash` (Alpine uses busybox ash by default) |
| **RHEL/CentOS/Fedora** | `sudo dnf install bash` or `sudo yum install bash` |
| **Arch** | `sudo pacman -S bash` |
| **FreeBSD** | `pkg install bash` |
| **Windows (WSL)** | bash is included in WSL. If using Git Bash, it ships bash 4+. |
| **Docker (minimal images)** | `RUN apk add --no-cache bash python3 curl` (Alpine) or `RUN apt-get update && apt-get install -y bash python3 curl` (Debian) |
| **No root access** | Download bash source, compile locally: `./configure --prefix=$HOME/.local && make && make install` · then `export PATH="$HOME/.local/bin:$PATH"` |
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

1. **Try running with bash 3.2 anyway.** Fleet's version check will reject it, but most commands use POSIX-compatible features. You can bypass the check by commenting out lines 9-20 in `bin/fleet` (the version guard). Many commands will still work. Test each one.

2. **Translate on the fly.** You are an AI agent. If a specific command fails due to a bash 4+ feature, read the failing script, understand what it does, and replicate the logic using whatever tools ARE available on the system (awk, sed, python3, perl, etc.). For example:
   - `fleet health` is just curl requests to endpoints. You can do that directly.
   - `fleet agents` is curl to each gateway port and formatting the output. You can replicate this in python3 alone.
   - `fleet sitrep` combines health checks, CI queries, and delta tracking. Each piece can be done independently.

3. **Create a wrapper.** If python3 is available but bash 4+ is not, write a thin python3 wrapper that invokes the fleet commands or reimplements the critical ones. The logic is simple: HTTP health checks + JSON parsing + formatted output.

4. **Report back what works and what doesn't.** Tell the user: "Fleet is running with limited compatibility. Commands X, Y, Z work. Command W needs bash 4+ for [specific feature]. Here's what I did instead."

### Step 4: Environments Without a Shell (Extremely Rare)

If you're running in a sandboxed environment with no shell access at all (some cloud functions, restricted containers):

- **Use the fleet logic directly.** Fleet commands are just: (a) curl to gateway ports, (b) parse JSON responses, (c) track state in a file. You can do all of this with any HTTP client and JSON parser available in your environment.
- **The fleet config format is documented.** Read `~/.fleet/config.json`, iterate over agents, hit their `/health` endpoints, format the output. That's `fleet agents` in 10 lines of any language.
- **State tracking for SITREP:** Read/write `~/.fleet/state/sitrep.json` to track deltas between runs. The format is simple: `{"agents": {...}, "ci": {...}, "endpoints": {...}, "timestamp": "..."}`.

### The Bottom Line

**Your goal is operational visibility, not running a specific bash script.** Fleet is the fastest path to that goal, but if the environment fights you, adapt. The commands are simple enough that you can reimplement any of them in python3, node, or even raw curl commands. Do whatever it takes. The user installed this skill because they want fleet management to work. Make it work.

## Best Practices

1. **Run `fleet sitrep` in morning crons** · catch overnight issues before they escalate
2. **Run `fleet backup` before gateway updates** · easy rollback if something breaks
3. **Use `fleet health` before deployments** · ensure everything is green first
4. **Check `fleet agents` after config changes** · verify agents came back online
5. **Filter `fleet ci` by repo** · avoid noise when debugging a specific service
6. **Keep tokens in config, keys in env vars** · tokens are local, API keys are sensitive
