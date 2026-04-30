#!/bin/bash
# fleet/lib/adapters/docker.sh: Docker container adapter.
# Verified: queries the local docker daemon for container state and the
# embedded health check, when one is configured. If the docker CLI is
# missing, the adapter degrades gracefully and reports verified false.

adapter_docker_describe() {
    echo "Docker container state and health (verified when docker CLI present)"
}

adapter_docker_verified() { echo "verified"; }

adapter_docker_required() { echo "container"; }

adapter_docker_health() {
    local entry_json="$1"
    python3 - "$entry_json" "${FLEET_ADAPTER_TIMEOUT:-6}" <<'HEALTH_PY'
import json, shutil, subprocess, sys, time
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
timeout = sys.argv[2]
container = e.get("container","")
if not container:
    print(json.dumps({"status":"error","code":"","elapsed_ms":0,"verified":False,"message":"container required"}))
    sys.exit(0)
if not shutil.which("docker"):
    print(json.dumps({"status":"unknown","code":"","elapsed_ms":0,"verified":False,"message":"docker CLI not installed"}))
    sys.exit(0)
start = time.time()
try:
    r = subprocess.run(
        ["docker","inspect","--format",
         "{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.ExitCode}}",
         container],
        capture_output=True, text=True, timeout=int(timeout)
    )
except subprocess.TimeoutExpired:
    print(json.dumps({"status":"error","code":"","elapsed_ms":int((time.time()-start)*1000),"verified":False,"message":"docker inspect timed out"}))
    sys.exit(0)
ms = int((time.time()-start)*1000)
if r.returncode != 0:
    msg = (r.stderr or "").strip().splitlines()[0:1]
    msg = msg[0] if msg else "container not found"
    print(json.dumps({"status":"unreachable","code":"","elapsed_ms":ms,"verified":True,"message":msg[:160]}))
    sys.exit(0)
parts = (r.stdout or "").strip().split("|")
state = parts[0] if len(parts) > 0 else ""
health = parts[1] if len(parts) > 1 else "none"
exit_code = parts[2] if len(parts) > 2 else "0"
if health == "healthy":
    status = "online"
elif health == "starting":
    status = "starting"
elif health == "unhealthy":
    status = "degraded"
elif state == "running":
    status = "online"
elif state in ("exited","dead","created"):
    status = "offline"
elif state == "paused":
    status = "degraded"
elif state == "restarting":
    status = "starting"
else:
    status = state or "unknown"
print(json.dumps({"status":status,"code":state,"elapsed_ms":ms,"verified":True,"message":f"health:{health} exit:{exit_code}"}))
HEALTH_PY
}

adapter_docker_info() {
    local entry_json="$1"
    python3 - "$entry_json" <<'INFO_PY'
import json, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
print(json.dumps({
    "name": e.get("name",""),
    "type": "docker",
    "endpoint": f"docker://{e.get('container','')}",
    "model": e.get("model",""),
    "role": e.get("role",""),
    "verified": True
}))
INFO_PY
}

adapter_docker_version() {
    local entry_json="$1"
    python3 - "$entry_json" "${FLEET_ADAPTER_TIMEOUT:-6}" <<'VERSION_PY'
import json, shutil, subprocess, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
container = e.get("container","")
if not container or not shutil.which("docker"):
    print(json.dumps({"version":"","verified":False}))
    sys.exit(0)
timeout = sys.argv[2]
try:
    r = subprocess.run(
        ["docker","inspect","--format","{{.Config.Image}}",container],
        capture_output=True, text=True, timeout=int(timeout)
    )
    image = (r.stdout or "").strip()
    if r.returncode != 0 or not image:
        print(json.dumps({"version":"","verified":False}))
        sys.exit(0)
    ver = image.split(":")[-1] if ":" in image else "latest"
    print(json.dumps({"version":ver,"verified":True}))
except Exception:
    print(json.dumps({"version":"","verified":False}))
VERSION_PY
}
