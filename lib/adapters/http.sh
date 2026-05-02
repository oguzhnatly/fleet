#!/bin/bash
# fleet/lib/adapters/http.sh: Generic HTTP adapter.
# Verified: any service that exposes a URL and returns an expected status.
# Use it for vendor APIs, internal services, and OpenClaw nodes that already
# have a custom URL.

adapter_http_describe() {
    echo "Generic HTTP probe with expected status (verified)"
}

adapter_http_verified() { echo "verified"; }

adapter_http_required() { echo "url"; }

adapter_http_health() {
    local entry_json="$1"
    python3 - "$entry_json" "${FLEET_ADAPTER_TIMEOUT:-6}" <<'HEALTH_PY'
import json, os, subprocess, sys, time
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
timeout = sys.argv[2]
url = e.get("url","")
expected = str(e.get("expectedStatus", 200))
method = e.get("method","GET").upper()
token = os.environ.get(e.get("tokenEnv") or e.get("token_env") or "", "") or e.get("token","")
extra_headers = e.get("headers", {}) or {}
if not url:
    print(json.dumps({"status":"error","code":"","elapsed_ms":0,"verified":False,"message":"url required"}))
    sys.exit(0)
args = ["curl","-s","-o","/dev/null","-w","%{http_code}","-X",method,"--max-time",str(timeout)]
if token:
    args += ["-H", f"Authorization: Bearer {token}"]
for k, v in extra_headers.items():
    args += ["-H", f"{k}: {v}"]
args.append(url)
start = time.time()
try:
    r = subprocess.run(args, capture_output=True, text=True)
    code = (r.stdout or "").strip()
except Exception as ex:
    print(json.dumps({"status":"error","code":"","elapsed_ms":0,"verified":False,"message":str(ex)[:120]}))
    sys.exit(0)
ms = int((time.time()-start)*1000)
if code == expected:
    status = "online"
elif code == "000":
    status = "unreachable"
elif code in ("301","302","307","308") and not expected.startswith(("3","4","5")):
    status = "online"
elif code in ("401","403"):
    status = "auth_failed"
else:
    status = "offline"
verified = code not in ("","000")
print(json.dumps({"status":status,"code":code,"elapsed_ms":ms,"verified":verified,"message":""}))
HEALTH_PY
}

adapter_http_info() {
    local entry_json="$1"
    python3 - "$entry_json" <<'INFO_PY'
import json, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
print(json.dumps({
    "name": e.get("name",""),
    "type": "http",
    "endpoint": e.get("url",""),
    "model": e.get("model",""),
    "role": e.get("role",""),
    "verified": True
}))
INFO_PY
}

adapter_http_version() {
    local entry_json="$1"
    python3 - "$entry_json" "${FLEET_ADAPTER_TIMEOUT:-6}" <<'VERSION_PY'
import json, subprocess, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
url = e.get("versionUrl") or e.get("url","")
if not url:
    print(json.dumps({"version":"","verified":False}))
    sys.exit(0)
timeout = sys.argv[2]
try:
    r = subprocess.run(["curl","-s","--max-time",str(timeout),url],
                       capture_output=True, text=True)
    body = (r.stdout or "").strip()
    ver = ""
    if body:
        try:
            data = json.loads(body)
            ver = data.get("version","") or data.get("build","") or ""
        except Exception:
            ver = body.splitlines()[0][:64]
    print(json.dumps({"version":ver,"verified":bool(ver)}))
except Exception:
    print(json.dumps({"version":"","verified":False}))
VERSION_PY
}
