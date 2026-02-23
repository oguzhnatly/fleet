---
name: fleet
description: "Multi-agent fleet management CLI for OpenClaw. Use when: (1) checking health of agent gateways, (2) running structured status reports (SITREP) with delta tracking, (3) monitoring CI across repos, (4) listing installed skills, (5) backing up agent configs. Triggers: 'check agents', 'fleet status', 'run sitrep', 'health check', 'backup config', 'show agents', 'fleet report'."
---

# Fleet — Multi-Agent Fleet Management

CLI toolkit for managing a fleet of OpenClaw agent gateways. Designed for the coordinator agent to monitor and manage employee agents.

## Quick Reference

| Situation | Command |
|-----------|---------|
| Check if all agents are alive | `fleet agents` |
| Full status with change tracking | `fleet sitrep` |
| Health check endpoints | `fleet health` |
| CI status across repos | `fleet ci` |
| List installed skills | `fleet skills` |
| Backup all configs | `fleet backup` |
| First-time setup | `fleet init` |

## Installation

```bash
clawhub install fleet
# Then link the binary:
ln -sf ~/.openclaw/skills/fleet/bin/fleet ~/.local/bin/fleet
chmod +x ~/.openclaw/skills/fleet/bin/fleet
```

## Configuration

Fleet reads `~/.fleet/config.json`. Generate one with `fleet init` or create manually.

Key config fields:
- `gateway.port` — Your main OpenClaw gateway port
- `agents[]` — Array of employee gateways with name, port, role, model, token
- `endpoints[]` — URLs to health check (name + url)
- `repos[]` — GitHub repos for CI monitoring (name + owner/repo)
- `linear.teams[]` — Linear team keys for ticket counts

See `examples/` for recommended patterns (solo-empire, dev-team, research-lab).

## Commands

### `fleet agents`
Shows all configured agent gateways with live health status, response time, and role.

### `fleet sitrep [hours]`
The most important command. Generates a structured status report showing:
- Agent fleet status (online/offline)
- CI status per repo (green/RED/running)
- Endpoint health
- Linear ticket counts
- VPS resource usage (memory, disk)
- **Delta tracking**: only shows what CHANGED since last run

State is saved to `~/.fleet/state/sitrep.json` for delta computation.

### `fleet health`
Quick health check of the main gateway, all configured endpoints, and systemd services.

### `fleet ci [filter]`
Shows GitHub CI status for all configured repos. Uses `gh` CLI. Optional filter to show one repo.

### `fleet skills`
Lists all installed ClawHub skills with version and description.

### `fleet backup` / `fleet restore`
Backs up openclaw.json, cron jobs, fleet config, and auth profiles to `~/.fleet/backups/`.

### `fleet init`
Interactive setup. Auto-detects running gateways and creates initial config.

## Environment Variables

| Variable | Description |
|----------|-------------|
| `FLEET_CONFIG` | Config file path (default: `~/.fleet/config.json`) |
| `FLEET_WORKSPACE` | Override workspace path |
| `FLEET_STATE_DIR` | State directory (default: `~/.fleet/state`) |

## Requirements

- bash 4+, python3 3.10+, curl
- OpenClaw with gateway support
- `gh` CLI for CI commands (optional)

## Architecture

Fleet is modular:
```
bin/fleet           — Entry point, command router
lib/core/           — Config, output, state management
lib/commands/       — One file per command
templates/configs/  — Config templates
examples/           — Architecture pattern examples
```
