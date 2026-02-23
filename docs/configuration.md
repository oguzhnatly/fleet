# Configuration Reference

Fleet reads from `~/.fleet/config.json` by default. Override with `FLEET_CONFIG` env var.

## Schema

```json
{
  "workspace": "string · path to your main workspace",
  "gateway": {
    "port": "number · main gateway port (default: 48391)",
    "name": "string · display name for the coordinator",
    "role": "string · role description",
    "model": "string · model identifier"
  },
  "agents": [
    {
      "name": "string · unique agent name",
      "port": "number · gateway port",
      "role": "string · what this agent does",
      "model": "string · model identifier",
      "token": "string · auth token for HTTP API"
    }
  ],
  "endpoints": [
    {
      "name": "string · display name",
      "url": "string · URL to health check",
      "expectedStatus": "number · expected HTTP status (default: 200)",
      "timeout": "number · request timeout in seconds (default: 6)"
    }
  ],
  "repos": [
    {
      "name": "string · display name",
      "repo": "string · GitHub owner/repo"
    }
  ],
  "services": [
    "string · systemd service names to monitor"
  ],
  "linear": {
    "teams": ["string · Linear team keys"],
    "apiKeyEnv": "string · env var name containing the API key"
  },
  "skillsDir": "string · path to ClawHub skills directory (optional)"
}
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FLEET_CONFIG` | Path to config file | `~/.fleet/config.json` |
| `FLEET_WORKSPACE` | Override workspace path | Config value |
| `FLEET_STATE_DIR` | State persistence directory | `~/.fleet/state` |
| `NO_COLOR` | Disable colored output | (unset) |

## Auto-Detection

`fleet init` automatically detects:
- Running OpenClaw gateways by scanning common ports
- Workspace path from `~/.openclaw/openclaw.json`
- Additional agent gateways by scanning port ranges

## Patterns

See the `examples/` directory for recommended configurations:
- **solo-empire** · One coordinator + 2 employees
- **dev-team** · Team leads with specialized developers
- **research-lab** · Research director with analysts and writers
