#!/bin/bash
# fleet health — Check gateway and all configured endpoints

cmd_health() {
    out_header "Fleet Health Check"

    # Main gateway
    local gw_port gw_name
    gw_port=$(fleet_gateway_port)
    gw_name=$(fleet_gateway_name)

    local result code ms
    result=$(http_check "http://127.0.0.1:$gw_port/health" 3)
    code=$(echo "$result" | cut -d' ' -f1)
    ms=$(echo "$result" | cut -d' ' -f2)

    if [ "$code" = "200" ]; then
        out_ok "$gw_name (:$gw_port) ${CLR_DIM}${ms}ms${CLR_RESET}"
    elif [ "$code" = "000" ]; then
        out_fail "$gw_name (:$gw_port) UNREACHABLE"
    else
        out_fail "$gw_name (:$gw_port) HTTP $code"
    fi

    # Configured endpoints
    if fleet_has_config; then
        local count
        count=$(_json_array_len "$FLEET_CONFIG_PATH" "endpoints")
        if [ "$count" -gt 0 ]; then
            out_section "Endpoints"
            python3 - "$FLEET_CONFIG_PATH" <<'PY'
import json, subprocess, sys, time

with open(sys.argv[1]) as f:
    config = json.load(f)

for ep in config.get("endpoints", []):
    name = ep.get("name", ep.get("url", "?"))
    url = ep.get("url", "")
    expected = ep.get("expectedStatus", 200)
    timeout = ep.get("timeout", 6)

    try:
        start = time.time()
        r = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
             "--max-time", str(timeout), url],
            capture_output=True, text=True
        )
        code = r.stdout.strip()
        ms = int((time.time() - start) * 1000)

        if code == str(expected):
            print(f"  ✅ {name} ({code}) {ms}ms")
        elif code == "000":
            print(f"  ❌ {name} UNREACHABLE")
        else:
            print(f"  ❌ {name} HTTP {code} (expected {expected})")
    except Exception as e:
        print(f"  ❌ {name} error: {e}")
PY
        fi
    fi

    # Systemd services (if any configured)
    if fleet_has_config; then
        local svc_count
        svc_count=$(_json_array_len "$FLEET_CONFIG_PATH" "services")
        if [ "$svc_count" -gt 0 ]; then
            out_section "Services"
            python3 - "$FLEET_CONFIG_PATH" <<'PY'
import json, subprocess, sys

with open(sys.argv[1]) as f:
    config = json.load(f)

for svc in config.get("services", []):
    name = svc if isinstance(svc, str) else svc.get("name", "?")
    try:
        r = subprocess.run(
            ["systemctl", "--user", "is-active", name],
            capture_output=True, text=True
        )
        status = r.stdout.strip()
        if status == "active":
            print(f"  ✅ {name}")
        else:
            print(f"  ❌ {name} ({status})")
    except Exception:
        print(f"  ⚠️  {name} (cannot check)")
PY
        fi
    fi
}
