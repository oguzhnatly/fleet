#!/bin/bash
# fleet/lib/adapters/openclaw.sh: OpenClaw gateway adapter.
# Verified: probes /health on 127.0.0.1:<port>, falls back to authenticated
# /v1/models when /health returns non 200 and a token is present. This is the
# default adapter and preserves v3 behavior exactly.

adapter_openclaw_describe() {
    echo "OpenClaw gateway via /health and /v1/models (verified)"
}

adapter_openclaw_verified() { echo "verified"; }

adapter_openclaw_required() { echo "port"; }

_openclaw_probe() {
    # Args: url, timeout, optional bearer token
    # Echo: "code elapsed_ms"
    local url="$1" timeout="$2" token="${3:-}"
    local start end code
    start=$(python3 -c "import time; print(int(time.time()*1e9))")
    if [ -n "$token" ]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" \
            -H "Authorization: Bearer $token" "$url" 2>/dev/null)
    else
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null)
    fi
    end=$(python3 -c "import time; print(int(time.time()*1e9))")
    echo "$code $(( (end - start) / 1000000 ))"
}

adapter_openclaw_health() {
    local entry_json="$1"
    python3 - "$entry_json" "${FLEET_ADAPTER_TIMEOUT:-6}" <<'HEALTH_PY'
import json, os, subprocess, sys, time
e = {}
try:
    e = json.loads(sys.argv[1])
except Exception:
    pass
timeout = sys.argv[2]
host = e.get("host", "127.0.0.1")
port = e.get("port")
token = os.environ.get(e.get("tokenEnv") or e.get("token_env") or "", "") or e.get("token", "")
if not port:
    print(json.dumps({"status":"error","code":"","elapsed_ms":0,"verified":False,"message":"port required"}))
    sys.exit(0)
url = f"http://{host}:{port}/health"
def probe(url, headers=None):
    start = time.time()
    args = ["curl","-s","-o","/dev/null","-w","%{http_code}","--max-time",str(timeout),url]
    if headers:
        for h in headers:
            args.extend(["-H", h])
    r = subprocess.run(args, capture_output=True, text=True)
    return r.stdout.strip(), int((time.time()-start)*1000)
code, ms = probe(url)
auth_used = False
if code != "200" and token:
    auth_url = f"http://{host}:{port}/v1/models"
    code2, ms2 = probe(auth_url, headers=[f"Authorization: Bearer {token}"])
    if code2 in ("200","401"):
        code, ms = code2, ms2
        auth_used = True
status = "online" if code == "200" else ("auth_failed" if code == "401" else ("unreachable" if code == "000" else "offline"))
verified = code in ("200","401","403")
msg = f"auth_endpoint:{auth_used}" if auth_used else ""
print(json.dumps({"status":status,"code":code,"elapsed_ms":ms,"verified":verified,"message":msg}))
HEALTH_PY
}

adapter_openclaw_info() {
    local entry_json="$1"
    python3 - "$entry_json" <<'INFO_PY'
import json, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
print(json.dumps({
    "name": e.get("name",""),
    "type": "openclaw",
    "endpoint": f"http://{e.get('host','127.0.0.1')}:{e.get('port','')}",
    "model": e.get("model","default"),
    "role": e.get("role",""),
    "verified": True
}))
INFO_PY
}

adapter_openclaw_version() {
    local entry_json="$1"
    python3 - "$entry_json" "${FLEET_ADAPTER_TIMEOUT:-6}" <<'VERSION_PY'
import json, subprocess, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
host = e.get("host","127.0.0.1")
port = e.get("port")
if not port:
    print(json.dumps({"version":"","verified":False}))
    sys.exit(0)
timeout = sys.argv[2]
url = f"http://{host}:{port}/version"
try:
    r = subprocess.run(["curl","-s","--max-time",str(timeout),url],
                       capture_output=True, text=True)
    body = r.stdout.strip()
    ver = ""
    if body:
        try:
            data = json.loads(body)
            ver = data.get("version") or data.get("openclaw",{}).get("version") or ""
        except Exception:
            stripped = body.lstrip()
            if (not stripped.startswith("<")
                    and len(stripped) <= 64
                    and "\n" not in stripped):
                ver = stripped
    print(json.dumps({"version":ver,"verified":bool(ver)}))
except Exception:
    print(json.dumps({"version":"","verified":False}))
VERSION_PY
}
