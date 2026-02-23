# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 1.x.x   | ✅ Current |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email: **oguzhnatly@gmail.com**
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

Fleet **never stores credentials itself**. It reads:
- API keys from environment variables (never from config files)
- Agent tokens from `~/.fleet/config.json` (local file, user-controlled)
- GitHub auth from `gh` CLI's existing session

### Best Practices

- Keep `~/.fleet/config.json` readable only by your user (`chmod 600`)
- Use environment variables for API keys, not config files
- Rotate agent tokens periodically
- Review the config before sharing it (tokens may be present)

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
