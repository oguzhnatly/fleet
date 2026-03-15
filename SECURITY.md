# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 3.x.x   | ✅ Current |
| 2.x.x   | ❌ End of life |
| 1.x.x   | ❌ End of life |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email: **info@oguzhanatalay.com**
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

You will receive an acknowledgment within 48 hours and a detailed response within 7 days.

## Security Considerations

Fleet is a CLI tool that runs locally and interacts with:

### Local Services
- OpenClaw gateways on localhost (configurable ports)
- Systemd services (read-only status checks)

### External Services
- GitHub API (via `gh` CLI, uses your existing auth)
- Linear API (optional, uses API key from environment variable)
- Configured endpoints (HTTP health checks only)

### Tokens and Credentials

Fleet reads:
- Agent gateway tokens from `~/.fleet/config.json` under `agents[].token` and `gateway.token`
- GitHub auth from `gh` CLI's existing session

Tokens are used for:
- Authenticating HTTP requests to OpenClaw agent gateways (`Authorization: Bearer <token>`)
- Routing dispatch sessions via `x-openclaw-session-key` header

### Session File Access (v2+)

`fleet watch` reads session transcript files directly from the OpenClaw profile directories:
- Coordinator: `~/.openclaw/agents/main/sessions/`
- Employees: `~/.openclaw-{agent}/agents/main/sessions/`

These files contain full conversation transcripts. Ensure profile directories are not readable by other users.

### Best Practices

- Keep `~/.fleet/config.json` readable only by your user: `chmod 600 ~/.fleet/config.json`
- Keep OpenClaw profile directories private: `chmod 700 ~/.openclaw ~/.openclaw-*`
- Rotate agent tokens periodically and update `~/.fleet/config.json` accordingly
- Review the config before sharing it (tokens are stored in plaintext)

## Scope

The following are **in scope** for security reports:
- Command injection via config values
- Credential exposure in logs or output
- Unauthorized access to local services
- Path traversal in file operations

The following are **out of scope**:
- Issues in OpenClaw itself (report to [OpenClaw](https://github.com/openclaw/openclaw))
- Issues in `gh` CLI (report to [GitHub CLI](https://github.com/cli/cli))
- Social engineering attacks
