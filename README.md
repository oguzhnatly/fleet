<p align="center">
  <img src="assets/banner.svg" alt="Fleet" width="600" />
</p>

<h3 align="center">Multi-agent fleet management for <a href="https://openclaw.ai">OpenClaw</a></h3>

<p align="center">
  <strong>One CLI to monitor, manage, and orchestrate your entire AI agent fleet.</strong>
</p>

<p align="center">
  <a href="https://github.com/oguzhnatly/fleet/actions"><img src="https://github.com/oguzhnatly/fleet/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://clawhub.com"><img src="https://img.shields.io/badge/ClawHub-fleet-blue" alt="ClawHub" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License" /></a>
  <a href="#"><img src="https://img.shields.io/badge/bash-4%2B-orange" alt="Bash 4+" /></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#commands">Commands</a> •
  <a href="#patterns">Patterns</a> •
  <a href="#configuration">Configuration</a> •
  <a href="docs/">Docs</a>
</p>

---

## The Problem

You're running multiple [OpenClaw](https://openclaw.ai) gateways — a coordinator that thinks, employees that code, review, deploy, and research. But your coordinator is blind. It can't see which employees are up, which CI is red, or what changed overnight.

**Fleet gives your coordinator eyes.**

## The Solution

```bash
$ fleet sitrep

SITREP | 2026-02-23 08:00 UTC | vs 2026-02-22 23:00
────────────────────────────────────────────────────────────

Agents  6/6 online
  ⬢ coordinator
  ⬢ coder
  ⬢ reviewer
  ⬢ deployer
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
  → CI backend: green → RED
  → Linear tickets: +3

Resources  mem 45% | disk 7%
```

One command. Full visibility. Delta tracking shows only what changed.

## Quick Start

```bash
# Install via ClawHub
clawhub install fleet

# Or clone directly
git clone https://github.com/oguzhnatly/fleet.git
ln -sf $(pwd)/fleet/bin/fleet ~/.local/bin/fleet

# Initialize (auto-detects running gateways)
fleet init

# Check your fleet
fleet agents
fleet health
fleet sitrep
```

## Commands

### Monitoring

| Command | Description |
|---------|-------------|
| `fleet health` | Health check all gateways and endpoints |
| `fleet agents` | Show agent fleet with live status and latency |
| `fleet sitrep [hours]` | Full SITREP with delta tracking |

### Development

| Command | Description |
|---------|-------------|
| `fleet ci [filter]` | GitHub CI status across all repos |
| `fleet skills` | List installed ClawHub skills |

### Operations

| Command | Description |
|---------|-------------|
| `fleet backup` | Backup gateway configs, cron jobs, auth profiles |
| `fleet restore` | Restore from latest backup |
| `fleet init` | Interactive setup with auto-detection |

## Patterns

Fleet supports any agent organization pattern. Three common ones:

### Solo Empire
> One brain, many hands. The indie hacker setup.

```
         Coordinator (Opus)
        /     |      \
    Coder  Reviewer  Deployer
   (Codex)  (Codex)   (Codex)
```

### Development Team
> Team leads managing specialized developers.

```
              Orchestrator (Opus)
            /        |         \
      FE Lead     BE Lead     QA Lead
     (Sonnet)    (Sonnet)    (Sonnet)
       / \          |           |
    Dev1  Dev2    Dev1       Tester
   (Codex)(Codex)(Codex)    (Codex)
```

### Research Lab
> Specialized agents for knowledge work.

```
            Director (Opus)
          /     |      \       \
    Scraper  Analyst  Writer  Fact-Check
   (Codex)  (Sonnet) (Sonnet)  (Codex)
```

See [`docs/patterns.md`](docs/patterns.md) for detailed guides and [`examples/`](examples/) for ready-to-use configs.

## Configuration

Fleet reads `~/.fleet/config.json`. Create one with `fleet init` or manually:

```json
{
  "workspace": "~/workspace",
  "gateway": {
    "port": 48391,
    "name": "coordinator"
  },
  "agents": [
    { "name": "coder", "port": 48520, "role": "implementation", "model": "codex" },
    { "name": "reviewer", "port": 48540, "role": "code-review", "model": "codex" }
  ],
  "endpoints": [
    { "name": "website", "url": "https://myapp.com" },
    { "name": "api", "url": "https://api.myapp.com/health" }
  ],
  "repos": [
    { "name": "frontend", "repo": "myorg/frontend" },
    { "name": "backend", "repo": "myorg/backend" }
  ]
}
```

Everything is configurable. No hardcoded ports, models, or names. Your fleet, your way.

See [`docs/configuration.md`](docs/configuration.md) for the full schema.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FLEET_CONFIG` | Config file path | `~/.fleet/config.json` |
| `FLEET_WORKSPACE` | Workspace override | Config value |
| `FLEET_STATE_DIR` | State persistence | `~/.fleet/state` |
| `NO_COLOR` | Disable colors | _(unset)_ |

## Architecture

```
fleet/
├── bin/fleet              # Entry point
├── lib/
│   ├── core/              # Config, output, state management
│   │   ├── config.sh      # JSON config loader
│   │   ├── output.sh      # Colors, formatting, HTTP helpers
│   │   └── state.sh       # Delta state persistence
│   └── commands/           # One file per command
│       ├── agents.sh       # Agent fleet status
│       ├── backup.sh       # Config backup/restore
│       ├── ci.sh           # GitHub CI integration
│       ├── health.sh       # Endpoint health checks
│       ├── init.sh         # Interactive setup
│       ├── sitrep.sh       # Structured status reports
│       └── skills.sh       # ClawHub skill listing
├── templates/configs/      # Config templates
├── examples/               # Architecture pattern examples
│   ├── solo-empire/
│   ├── dev-team/
│   └── research-lab/
├── docs/                   # Documentation
├── tests/                  # Integration tests
├── SKILL.md                # ClawHub agent instructions
└── .github/workflows/      # CI pipeline
```

Modular by design. Each command is a separate file. Add your own by dropping a `.sh` file in `lib/commands/`.

## For AI Agents

Fleet ships with a [`SKILL.md`](SKILL.md) that any OpenClaw agent can read. Install via ClawHub and your coordinator automatically knows how to manage the fleet:

```bash
clawhub install fleet
```

The agent reads the skill file, learns the commands, and runs health checks autonomously during heartbeat cycles.

## Requirements

- bash 4+ and python3 3.10+ (no pip packages needed)
- [OpenClaw](https://openclaw.ai) with gateway support
- `curl` (pre-installed on most systems)
- [`gh` CLI](https://cli.github.com/) (optional, for CI commands)

## Contributing

Issues and PRs welcome. Built by a solo operation, for solo operations.

## License

[MIT](LICENSE) — Oguzhan Atalay
