#!/bin/bash
# fleet/lib/core/adapters.sh: Cross runtime adapter registry and dispatcher.
#
# Each adapter lives in lib/adapters/<type>.sh and defines five functions:
#
#   adapter_<type>_describe
#       echo a one line human description, e.g.
#       "OpenClaw gateway via /health (verified)"
#
#   adapter_<type>_verified
#       echo "verified" or "inferred". Verified means the adapter actually
#       confirms a live response. Inferred means presence is detected without
#       a real handshake (e.g. pgrep matched a process).
#
#   adapter_<type>_required
#       echo a space separated list of required fields on the entry json.
#       Empty if no required fields.
#
#   adapter_<type>_health <entry_json>
#       Read entry json from arg 1, run a health probe, and print a JSON
#       object with at least: status (online|offline|unreachable|degraded),
#       code, elapsed_ms, verified (true|false), message.
#       Always exit 0; status is in the JSON.
#
#   adapter_<type>_info <entry_json>
#       Print a JSON object describing the entry as the adapter sees it:
#       name, type, endpoint, verified, optional model/role/extra fields.
#
#   adapter_<type>_version <entry_json>
#       Print a JSON object: { "version": "...", "verified": true|false }.
#       Adapters that cannot determine a version return version "" and
#       verified false.
#
# All adapter implementations must tolerate missing optional fields and
# must not crash on bad json. They must complete within FLEET_ADAPTER_TIMEOUT
# seconds (default 6) so a single bad runtime cannot stall the fleet.

# shellcheck disable=SC2034
FLEET_ADAPTER_TIMEOUT="${FLEET_ADAPTER_TIMEOUT:-6}"
FLEET_ADAPTERS_DIR_BUILTIN="$FLEET_ROOT/lib/adapters"
FLEET_ADAPTERS_DIR_USER="${FLEET_ADAPTERS_DIR:-$HOME/.fleet/adapters}"

# Registry: associative array of type to source path, populated by load_all.
declare -gA FLEET_ADAPTER_PATHS
declare -gA FLEET_ADAPTER_ORIGIN

# ── Loader ──────────────────────────────────────────────────────────────────
fleet_adapter_load_all() {
    FLEET_ADAPTER_PATHS=()
    FLEET_ADAPTER_ORIGIN=()
    local dir adapter type
    for dir in "$FLEET_ADAPTERS_DIR_BUILTIN" "$FLEET_ADAPTERS_DIR_USER"; do
        [ -d "$dir" ] || continue
        local origin="builtin"
        [ "$dir" = "$FLEET_ADAPTERS_DIR_USER" ] && origin="user"
        for adapter in "$dir"/*.sh; do
            [ -f "$adapter" ] || continue
            type="$(basename "$adapter" .sh)"
            # shellcheck source=/dev/null
            source "$adapter"
            FLEET_ADAPTER_PATHS["$type"]="$adapter"
            FLEET_ADAPTER_ORIGIN["$type"]="$origin"
        done
    done
}

fleet_adapter_types() {
    local t
    for t in "${!FLEET_ADAPTER_PATHS[@]}"; do echo "$t"; done | sort
}

fleet_adapter_exists() {
    local type="$1"
    [ -n "${FLEET_ADAPTER_PATHS[$type]:-}" ]
}

# Resolve which adapter type to use for a given entry.
# Order: entry.adapter, entry.type, default openclaw.
fleet_adapter_resolve() {
    local entry_json="$1"
    python3 - "$entry_json" <<'RESOLVE_PY'
import json, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
val = e.get("adapter") or e.get("type") or "openclaw"
print(val)
RESOLVE_PY
}

# Validate that an entry json has the fields the resolved adapter needs.
# Echo "ok" or a comma separated list of missing field names.
fleet_adapter_validate() {
    local entry_json="$1"
    local type
    type="$(fleet_adapter_resolve "$entry_json")"
    if ! fleet_adapter_exists "$type"; then
        echo "missing_adapter:$type"
        return 1
    fi
    local required
    required="$(adapter_"${type}"_required 2>/dev/null || echo "")"
    [ -z "$required" ] && { echo "ok"; return 0; }
    python3 - "$entry_json" "$required" <<'VALIDATE_PY'
import json, sys
try:
    e = json.loads(sys.argv[1])
except Exception:
    e = {}
required = sys.argv[2].split()
missing = [f for f in required if not e.get(f)]
print("ok" if not missing else ",".join(missing))
VALIDATE_PY
}

# Dispatch helpers. Each falls back to a clean error JSON if the adapter
# is missing or fails. Output is always parseable JSON on stdout.
fleet_adapter_health() {
    local entry_json="$1"
    local type
    type="$(fleet_adapter_resolve "$entry_json")"
    if ! fleet_adapter_exists "$type"; then
        printf '{"status":"error","code":"","elapsed_ms":0,"verified":false,"message":"unknown adapter: %s"}\n' "$type"
        return 0
    fi
    local out
    out="$(adapter_"${type}"_health "$entry_json" 2>/dev/null || echo "")"
    if [ -z "$out" ]; then
        printf '{"status":"error","code":"","elapsed_ms":0,"verified":false,"message":"adapter %s returned no output"}\n' "$type"
        return 0
    fi
    echo "$out"
}

fleet_adapter_info() {
    local entry_json="$1"
    local type
    type="$(fleet_adapter_resolve "$entry_json")"
    if ! fleet_adapter_exists "$type"; then
        printf '{"type":"%s","verified":false,"message":"unknown adapter"}\n' "$type"
        return 0
    fi
    adapter_"${type}"_info "$entry_json" 2>/dev/null || \
        printf '{"type":"%s","verified":false,"message":"info failed"}\n' "$type"
}

fleet_adapter_version() {
    local entry_json="$1"
    local type
    type="$(fleet_adapter_resolve "$entry_json")"
    if ! fleet_adapter_exists "$type"; then
        printf '{"version":"","verified":false}\n'
        return 0
    fi
    adapter_"${type}"_version "$entry_json" 2>/dev/null || \
        printf '{"version":"","verified":false}\n'
}

# Read all entries from config: agents and runtimes combined.
# Echoes each entry as a single JSON line, prefixed with "agent\t" or
# "runtime\t" so callers can tell them apart.
fleet_adapter_iter_entries() {
    local config_path="${1:-$FLEET_CONFIG_PATH}"
    [ -f "$config_path" ] || return 0
    python3 - "$config_path" <<'ITER_PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except Exception:
    sys.exit(0)
for a in c.get("agents", []):
    print("agent\t" + json.dumps(a))
for r in c.get("runtimes", []):
    print("runtime\t" + json.dumps(r))
ITER_PY
}

# Probe a list of entries (each a JSON line) in parallel and render a uniform
# row per entry. Used by `fleet runtime list`, `fleet agents` runtime section,
# and `fleet health` runtime section.
#
# Args: each entry json as a separate argument.
# Renders a status row per entry, animated while probes run on a TTY.
fleet_adapter_probe_parallel() {
    local n="$#"
    [ "$n" -eq 0 ] && return 0

    local tmpdir
    tmpdir="$(mktemp -d -t fleet_probe.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local i=0
    local entry
    local pids=()
    for entry in "$@"; do
        ( fleet_adapter_health "$entry" > "$tmpdir/$i.json" 2>/dev/null ) &
        pids+=($!)
        i=$((i+1))
    done

    if [ -t 1 ]; then
        local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local fi=0 done_count running
        while true; do
            running=0
            for p in "${pids[@]}"; do
                kill -0 "$p" 2>/dev/null && running=$((running+1))
            done
            [ "$running" -eq 0 ] && break
            done_count=$((n - running))
            printf "\r  ${CLR_CYAN}%s${CLR_RESET} probing %d/%d targets..." \
                "${frames[$((fi % 10))]}" "$done_count" "$n"
            fi=$((fi+1))
            sleep 0.08
        done
        printf "\r\033[K"
    else
        wait "${pids[@]}" 2>/dev/null
    fi
    wait "${pids[@]}" 2>/dev/null

    i=0
    for entry in "$@"; do
        local res
        res="$(cat "$tmpdir/$i.json" 2>/dev/null)"
        [ -z "$res" ] && res='{"status":"error","code":"","elapsed_ms":0,"verified":false,"message":"no output"}'
        local atype
        atype="$(fleet_adapter_resolve "$entry")"
        python3 - "$entry" "$res" "$atype" <<'ROW_PY'
import json, sys
e = json.loads(sys.argv[1]) if sys.argv[1] else {}
h = json.loads(sys.argv[2]) if sys.argv[2] else {}
atype = sys.argv[3]
G="\033[32m"; R="\033[31m"; Y="\033[33m"; D="\033[2m"; C="\033[36m"; B="\033[1m"; N="\033[0m"
status = h.get("status","?")
verified = h.get("verified", False)
ms = h.get("elapsed_ms", 0)
code = h.get("code","")
name = e.get("name","?")
endpoint = ""
if atype == "openclaw":
    host = e.get("host","127.0.0.1")
    endpoint = f"{host}:{e.get('port','')}"
elif atype == "http":
    endpoint = e.get("url","")
elif atype == "docker":
    endpoint = f"docker:{e.get('container','')}"
elif atype == "process":
    endpoint = f"proc:{e.get('process','')}"
else:
    endpoint = e.get("endpoint","")
verify_tag = f"{D}verified{N}" if verified else f"{Y}inferred{N}"
icon = f"{G}⬢{N}" if status == "online" else (f"{Y}⚠{N}" if status in ("starting","degraded","auth_failed") else f"{R}⬡{N}")
clr  = G if status == "online" else (Y if status in ("starting","degraded","auth_failed") else R)
# Truncate long names/endpoints for table alignment.
def trunc(s, n):
    s = str(s)
    return s if len(s) <= n else s[:n-1] + "…"
print(f"  {icon} {B}{trunc(name,18):<18}{N} {C}{atype:<9}{N} {trunc(endpoint,32):<32} {clr}{status:<11}{N} {verify_tag} {D}{ms}ms{N}")
ROW_PY
        i=$((i+1))
    done
}

fleet_runtime_get() {
    local name="$1" config_path="${2:-$FLEET_CONFIG_PATH}"
    [ -f "$config_path" ] || return 1
    python3 - "$config_path" "$name" <<'GET_PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
except Exception:
    sys.exit(1)
name = sys.argv[2]
for r in c.get("runtimes", []):
    if r.get("name") == name:
        print(json.dumps(r))
        sys.exit(0)
for a in c.get("agents", []):
    if a.get("name") == name:
        print(json.dumps(a))
        sys.exit(0)
sys.exit(1)
GET_PY
}
