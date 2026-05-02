# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 4.x.x   | Current |
| 3.x.x   | Security fixes only |
| 2.x.x   | End of life |
| 1.x.x   | End of life |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. Do not open a public issue
2. Email: info@oguzhanatalay.com
3. Include the vulnerability, reproduction steps, impact, and suggested fix if available

You will receive an acknowledgment within 48 hours and a detailed response within 7 days.

## Security Considerations

Fleet is a local CLI for multi-agent fleet management. It interacts with:

### Local Services

- OpenClaw gateways on loopback ports configured by the operator
- Runtime probes configured by the operator
- Local process and Docker state when those adapters are configured

### External Services

- GitHub API through the operator's existing `gh` CLI auth for CI reads
- GitHub release metadata for Fleet update checks
- Operator-configured endpoint URLs for health checks

### Tokens and Credentials

Fleet prefers environment-backed tokens:

```json
{
  "name": "coder",
  "port": 48520,
  "tokenEnv": "FLEET_CODER_TOKEN"
}
```

Legacy inline `token` fields are still supported for backwards compatibility, but `fleet audit` warns when inline tokens are present. `fleet init` writes `~/.fleet/config.json` with mode 600 and detected agents use `tokenEnv` placeholders by default.

Tokens are used only for loopback requests to the operator's own OpenClaw agent gateways. Fleet never transmits agent tokens to external services.

### High Impact Actions

The following actions require confirmation by default, or `--yes` only after explicit operator approval:

- `fleet task`
- `fleet steer`
- `fleet parallel` execution
- `fleet kill`
- `fleet restore`
- `fleet backup --include-secrets`
- `fleet backup --include-auth`
- `fleet update --install`
- `fleet watch --all`

### Setup Writes

`fleet init` creates only `~/.fleet/config.json` by default. It does not create a symlink and does not edit shell rc files.

Optional writes:

- `fleet init --link` creates `~/.local/bin/fleet`
- `fleet init --path` may append `~/.local/bin` to the user's shell rc files after confirmation

### Update Safety

`fleet update` is check-only by default. Installation requires `fleet update --install`, confirmation, and the default updater refuses custom repositories unless `FLEET_ALLOW_CUSTOM_UPDATE_REPO=1` is set intentionally.

Install is blocked unless a release checksum is available, or the operator explicitly adds `--allow-unverified` after manually verifying the archive.

### Backup Safety

`fleet backup` creates a safe backup by default:

- Backup directory mode is 700
- Backup files are mode 600
- Fleet config token values are redacted unless `--include-secrets` is used
- OpenClaw OpenClaw login profile files are excluded unless `--include-auth` is used

### Session File Access

`fleet watch <agent>` reads only the fleet-named session for that agent by default. `fleet watch <agent> --all` can display full main session history and is confirmation-gated because transcripts may contain private prompts, outputs, or secrets.

Keep OpenClaw profile directories private:

```bash
chmod 700 ~/.openclaw ~/.openclaw-* 2>/dev/null || true
```

## Best Practices

- Prefer `tokenEnv` over inline tokens
- Keep `~/.fleet/config.json` at mode 600
- Keep OpenClaw profile directories at mode 700
- Use `fleet audit` before sharing configs or running high impact operations
- Avoid putting secrets in agent chat transcripts
- Keep configured agent and runtime lists narrow
- Use `fleet parallel --dry-run` before execution

## Scope

The following are in scope for security reports:

- Command injection via config values
- Credential exposure in logs, backups, or output
- Unauthorized access to local services
- Path traversal in file operations
- Unsafe update or restore behavior

The following are out of scope:

- Issues in OpenClaw itself
- Issues in GitHub CLI itself
- Social engineering attacks
