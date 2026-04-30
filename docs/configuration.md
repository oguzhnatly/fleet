# Configuration Reference

Fleet reads from `~/.fleet/config.json` by default. Override with `FLEET_CONFIG` env var.

## Schema

```json
{
  "workspace": "string: path to your main workspace",
  "gateway": {
    "port": "number: main gateway port (default: 48391)",
    "name": "string: display name for the coordinator",
    "role": "string: role description (use 'coordinator' for the main agent)",
    "model": "string: model identifier",
    "token": "string: auth token for HTTP API calls to coordinator (required for fleet watch coordinator)"
  },
  "agents": [
    {
      "name": "string: unique agent name",
      "port": "number: gateway port",
      "role": "string: what this agent does",
      "model": "string: model identifier",
      "token": "string: auth token for HTTP API"
    }
  ],
  "runtimes": [
    {
      "name": "string: unique runtime name",
      "adapter": "string: openclaw, http, docker, process, or a custom adapter type",
      "role": "string: optional display role",
      "model": "string: optional display label",
      "host": "string: host for openclaw adapter (default: 127.0.0.1)",
      "port": "number: port for openclaw adapter",
      "url": "string: health URL for http adapter",
      "versionUrl": "string: optional version endpoint for http adapter",
      "expectedStatus": "number: expected HTTP status for http adapter (default: 200)",
      "method": "string: HTTP method for http adapter (default: GET)",
      "headers": "object: extra HTTP headers for http adapter",
      "container": "string: Docker container name or id for docker adapter",
      "process": "string: process name or pattern for process adapter",
      "matchFull": "boolean: use full command matching for process adapter"
    }
  ],
  "endpoints": [
    {
      "name": "string: display name",
      "url": "string: URL to health check",
      "expectedStatus": "number: expected HTTP status (default: 200)",
      "timeout": "number: request timeout in seconds (default: 6)"
    }
  ],
  "repos": [
    {
      "name": "string: display name",
      "repo": "string: GitHub owner/repo"
    }
  ],
  "services": [
    "string: systemd service names to monitor"
  ],
  "linear": {
    "teams": ["string: Linear team keys"],
    "apiKeyEnv": "string: env var name containing the API key"
  },
  "skillsDir": "string: path to ClawHub skills directory (optional)"
}
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FLEET_CONFIG` | Path to config file | `~/.fleet/config.json` |
| `FLEET_LOG` | Path to dispatch log file | `~/.fleet/log.jsonl` |
| `FLEET_WORKSPACE` | Override workspace path | Config value |
| `FLEET_STATE_DIR` | State persistence directory | `~/.fleet/state` |
| `FLEET_ADAPTER_TIMEOUT` | Maximum seconds for a single adapter health probe | `6` |
| `FLEET_ADAPTERS_DIR` | Directory for custom adapter scripts | `~/.fleet/adapters` |
| `NO_COLOR` | Disable colored output | (unset) |

## Auto-Detection

`fleet init` automatically detects:
- Running OpenClaw gateways by scanning common ports
- Workspace path from `~/.openclaw/openclaw.json`
- Additional agent gateways by scanning port ranges

## Patterns

See the `examples/` directory for recommended configurations:
- **solo-empire**: One coordinator + 2 employees
- **dev-team**: Team leads with specialized developers
- **research-lab**: Research director with analysts and writers

## Runtime Configuration (v4)

Fleet v4 adds a `runtimes` array for non coordinator targets. This is additive. Existing v1, v2, and v3 configs continue to work without a migration.

### Adapter fields

| Adapter | Required fields | Verification mode |
|---------|-----------------|-------------------|
| `openclaw` | `port` | verified through `/health` or authenticated `/v1/models` fallback |
| `http` | `url` | verified through configured HTTP response status |
| `docker` | `container` | verified through Docker daemon inspection when the Docker CLI is available |
| `process` | `process` | inferred through `pgrep`, no protocol handshake |

### Example

```json
{
  "runtimes": [
    {
      "name": "billing-api",
      "adapter": "http",
      "url": "http://127.0.0.1:8080/health",
      "versionUrl": "http://127.0.0.1:8080/version",
      "role": "api"
    },
    {
      "name": "worker",
      "adapter": "docker",
      "container": "worker-service"
    },
    {
      "name": "scheduler",
      "adapter": "process",
      "process": "cron"
    }
  ]
}
```

### Custom adapters

Drop a `<type>.sh` file into `~/.fleet/adapters/` or set `FLEET_ADAPTERS_DIR`. A custom adapter must define six functions named `adapter_<type>_describe`, `adapter_<type>_verified`, `adapter_<type>_required`, `adapter_<type>_health`, `adapter_<type>_info`, and `adapter_<type>_version`.

## Trust Configuration (v3)

The `trust` block configures the v3 reliability scoring engine.

```json
{
  "trust": {
    "windowHours": 72
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `windowHours` | number | `72` | Tasks within this window count 2× in trust scoring. Tasks within 7 days count 1×. Older tasks count 0.5×. |

### Trust Score Formula

```
trust_score = quality_score × speed_multiplier
```

**quality_score**: weighted average of per-task quality:

| Outcome | Base quality | Modifier |
|---------|-------------|----------|
| `success` | 1.0 | −0.15 per steer (min 0.70) |
| `steered` | 0.5 | −0.10 per additional steer (min 0.30) |
| `failure` | 0.0 | none |
| `timeout` | 0.0 | none |

**speed_multiplier**: derived from average task duration:

| Avg duration | Multiplier |
|-------------|------------|
| ≤ 5 min | 1.00 |
| ≤ 15 min | 0.90 |
| ≤ 30 min | 0.75 |
| > 30 min | ≥ 0.50 (degrades linearly) |

### Trust-Weighted Routing

`fleet parallel` automatically selects the highest-trust agent for each task type.
When no log data exists for a type, the agent's overall score is used with a 0.8× penalty.

### Environment Variables (v3)

| Variable | Description | Default |
|----------|-------------|---------|
| `FLEET_TRUST_WINDOW_HOURS` | Override trust recency window | `72` |
