# Cross Runtime Example

This example shows one Fleet config monitoring four runtime styles through the v4 adapter layer.

## Included targets

| Name | Adapter | What it probes |
|------|---------|----------------|
| `local-openclaw` | `openclaw` | Local OpenClaw gateway health and authenticated model endpoint fallback |
| `billing-api` | `http` | Any operator configured HTTP health endpoint |
| `worker-container` | `docker` | Docker container state and embedded health status when present |
| `scheduler` | `process` | OS process presence through `pgrep`, labeled inferred |

## Try it safely

```bash
FLEET_CONFIG=examples/cross-runtime/config.json fleet adapters
FLEET_CONFIG=examples/cross-runtime/config.json fleet runtime list
FLEET_CONFIG=examples/cross-runtime/config.json fleet runtime test billing-api
```

The example uses placeholder ports, URLs, container names, and process names. Update them to your local targets before expecting green health checks.

## Add your own runtime

```bash
fleet runtime add search-api http --url http://127.0.0.1:8080/health --version-url http://127.0.0.1:8080/version
fleet runtime add queue docker --container redis
fleet runtime add scheduler process --process cron
```

## Expected output shape

`fleet runtime list` renders one row per runtime with adapter type, endpoint, status, verification mode, and latency. Verified adapters perform a protocol or daemon handshake. Inferred adapters detect presence without a protocol handshake.
