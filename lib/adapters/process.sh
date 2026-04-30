#!/bin/bash
# fleet/lib/adapters/process.sh: OS process adapter.
# Inferred: presence of a matching process is detected via pgrep. There is
# no live handshake, so health is reported as inferred. Use this for daemons
# that lack a public health endpoint.

adapter_process_describe() {
    echo "OS process detected via pgrep, no protocol probe (inferred)"
}

adapter_process_verified() { echo "inferred"; }

adapter_process_required() { echo "process"; }

adapter_process_health() {
    local entry_json="$1"
    python3 - "$entry_json" "${FLEET_ADAPTER_TIMEOUT:-6}" <<'HEALTH_PY'
import json, shutil, subprocess, sys, time
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
timeout = sys.argv[2]
pat = e.get("process","")
match_full = bool(e.get("matchFull", False))
if not pat:
    print(json.dumps({"status":"error","code":"","elapsed_ms":0,"verified":False,"message":"process pattern required"}))
    sys.exit(0)
if not shutil.which("pgrep"):
    print(json.dumps({"status":"unknown","code":"","elapsed_ms":0,"verified":False,"message":"pgrep not available"}))
    sys.exit(0)
start = time.time()
args = ["pgrep","-f" if match_full else "-x", pat]
try:
    r = subprocess.run(args, capture_output=True, text=True, timeout=int(timeout))
except subprocess.TimeoutExpired:
    print(json.dumps({"status":"error","code":"","elapsed_ms":int((time.time()-start)*1000),"verified":False,"message":"pgrep timed out"}))
    sys.exit(0)
ms = int((time.time()-start)*1000)
pids = [p for p in (r.stdout or "").split() if p.strip()]
if pids:
    status = "online"
    code = f"pids:{len(pids)}"
    msg = "pids " + ",".join(pids[:5])
else:
    status = "offline"
    code = "pids:0"
    msg = "no matching processes"
print(json.dumps({"status":status,"code":code,"elapsed_ms":ms,"verified":False,"message":msg}))
HEALTH_PY
}

adapter_process_info() {
    local entry_json="$1"
    python3 - "$entry_json" <<'INFO_PY'
import json, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
print(json.dumps({
    "name": e.get("name",""),
    "type": "process",
    "endpoint": f"process:{e.get('process','')}",
    "model": e.get("model",""),
    "role": e.get("role",""),
    "verified": False
}))
INFO_PY
}

adapter_process_version() {
    # Most OS processes do not expose a version probe.
    printf '{"version":"","verified":false}\n'
}
