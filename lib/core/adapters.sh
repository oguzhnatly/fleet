#!/bin/bash
# fleet/lib/core/adapters.sh: Cross runtime adapter registry and dispatcher.
#
# Each adapter lives in lib/adapters/<type>.sh and defines six functions:
#
#   adapter_<type>_describe
#       Echo a one line human description.
#
#   adapter_<type>_verified
#       Echo "verified" or "inferred". Verified means the adapter actually
#       confirms a live response. Inferred means presence is detected without
#       a real handshake (e.g. pgrep matched a process).
#
#   adapter_<type>_required
#       Echo a space separated list of required entry fields. Empty if none.
#
#   adapter_<type>_health <entry_json>
#       Read entry json from arg 1, run a health probe, print a JSON object
#       with at least: status (online|offline|unreachable|degraded|starting|
#       auth_failed|unknown|error), code, elapsed_ms, verified (true|false),
#       message. Always exit 0; status is in the JSON.
#
#   adapter_<type>_info <entry_json>
#       Print a JSON object describing the entry as the adapter sees it:
#       name, type, endpoint, verified, optional model, role, extras.
#
#   adapter_<type>_version <entry_json>
#       Print { "version": "...", "verified": true|false }. Adapters that
#       cannot determine a version return version "" and verified false.
#
# All adapter implementations must tolerate missing optional fields, must not
# crash on bad json, and must complete within FLEET_ADAPTER_TIMEOUT seconds
# (default 6) so a single bad runtime cannot stall the fleet.

# shellcheck disable=SC2034
FLEET_ADAPTER_TIMEOUT="${FLEET_ADAPTER_TIMEOUT:-6}"
FLEET_ADAPTERS_DIR_BUILTIN="$FLEET_ROOT/lib/adapters"
FLEET_ADAPTERS_DIR_USER="${FLEET_ADAPTERS_DIR:-$HOME/.fleet/adapters}"

# Registry: associative arrays of type to source path and origin.
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

# Validate entry json against the resolved adapter's required fields.
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

# Dispatch helpers. Each falls back to a clean error JSON if the adapter is
# missing or fails. Output is always parseable JSON on stdout.
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

# Iterate config entries: agents and runtimes, each prefixed "agent\t" or
# "runtime\t" so callers can distinguish them. Streams JSON lines on stdout.
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

# ── Pretty status row ──────────────────────────────────────────────────────
# Render a single row given entry json and health json. The adapter mode
# label (verified | inferred) reflects the adapter's intrinsic category,
# computed via adapter_<type>_verified, not the per-probe verified flag.
_fleet_adapter_render_row() {
    local entry="$1" health="$2" atype="$3" inflight="${4:-0}"
    local mode="unknown"
    if fleet_adapter_exists "$atype"; then
        mode="$(adapter_"${atype}"_verified 2>/dev/null || echo unknown)"
    fi
    CLR_GREEN="$CLR_GREEN" CLR_RED="$CLR_RED" CLR_YELLOW="$CLR_YELLOW" \
    CLR_DIM="$CLR_DIM" CLR_CYAN="$CLR_CYAN" CLR_BOLD="$CLR_BOLD" CLR_RESET="$CLR_RESET" \
    python3 - "$entry" "$health" "$atype" "$inflight" "$mode" <<'ROW_PY'
import json, os, sys
e = json.loads(sys.argv[1]) if sys.argv[1] else {}
h = json.loads(sys.argv[2]) if sys.argv[2] else {}
atype = sys.argv[3]
inflight = sys.argv[4] == "1"
mode = sys.argv[5]
G=os.environ.get("CLR_GREEN",""); R=os.environ.get("CLR_RED",""); Y=os.environ.get("CLR_YELLOW",""); D=os.environ.get("CLR_DIM",""); C=os.environ.get("CLR_CYAN",""); B=os.environ.get("CLR_BOLD",""); N=os.environ.get("CLR_RESET","")
status = h.get("status","?")
ms = h.get("elapsed_ms", 0)
name = e.get("name","?")
endpoint = ""
if atype == "openclaw":
    endpoint = f"{e.get('host','127.0.0.1')}:{e.get('port','')}"
elif atype == "http":
    endpoint = e.get("url","")
elif atype == "docker":
    endpoint = f"docker:{e.get('container','')}"
elif atype == "process":
    endpoint = f"proc:{e.get('process','')}"
else:
    endpoint = e.get("endpoint","")
def trunc(s, n):
    s = str(s)
    return s if len(s) <= n else s[:n-1] + "…"
if mode == "verified":
    mode_tag = f"{D}verified{N}"
elif mode == "inferred":
    mode_tag = f"{Y}inferred{N}"
else:
    mode_tag = f"{D}unknown {N}"
if inflight:
    icon = f"{C}◌{N}"; clr = D
    status_text = "probing"
    ms_text = ""
    mode_tag = D + "        " + N
else:
    if status == "online":
        icon = f"{G}⬢{N}"; clr = G
    elif status in ("starting","degraded","auth_failed"):
        icon = f"{Y}◐{N}"; clr = Y
    elif status == "unknown":
        icon = f"{D}◌{N}"; clr = D
    else:
        icon = f"{R}⬡{N}"; clr = R
    status_text = status
    ms_text = f"{D}{ms}ms{N}" if ms else f"{D}--{N}"
print(f"  {icon} {B}{trunc(name,18):<18}{N} {C}{atype:<9}{N} {trunc(endpoint,32):<32} {clr}{status_text:<11}{N} {mode_tag} {ms_text}")
ROW_PY
}

# Compute aggregate footer line for a probed batch.
_fleet_adapter_render_footer() {
    local results_dir="$1" total="$2"
    CLR_GREEN="$CLR_GREEN" CLR_RED="$CLR_RED" CLR_YELLOW="$CLR_YELLOW" \
    CLR_DIM="$CLR_DIM" CLR_BOLD="$CLR_BOLD" CLR_RESET="$CLR_RESET" \
    python3 - "$results_dir" "$total" <<'FOOT_PY'
import json, os, sys
d, total = sys.argv[1], int(sys.argv[2])
G=os.environ.get("CLR_GREEN",""); R=os.environ.get("CLR_RED",""); Y=os.environ.get("CLR_YELLOW",""); D=os.environ.get("CLR_DIM",""); B=os.environ.get("CLR_BOLD",""); N=os.environ.get("CLR_RESET","")
online = degraded = offline = 0
ms_list = []
for i in range(total):
    p = os.path.join(d, f"{i}.json")
    try:
        with open(p) as f:
            h = json.load(f)
    except Exception:
        h = {}
    s = h.get("status","")
    if s == "online":
        online += 1
    elif s in ("degraded","starting","auth_failed"):
        degraded += 1
    else:
        offline += 1
    if isinstance(h.get("elapsed_ms",0), int) and h.get("elapsed_ms",0) > 0:
        ms_list.append(h["elapsed_ms"])
avg = (sum(ms_list)//len(ms_list)) if ms_list else 0
parts = [f"{G}{online} online{N}"]
if degraded: parts.append(f"{Y}{degraded} degraded{N}")
if offline:  parts.append(f"{R}{offline} offline{N}")
parts.append(f"{D}avg {avg}ms{N}")
print(f"  {D}└─{N} {B}{total} probe" + ("s" if total != 1 else "") + f"{N}  " + f" {D}·{N} ".join(parts))
FOOT_PY
}

# Probe a list of entries (each a JSON line) in parallel and render rows
# progressively. As each probe completes, the corresponding queued row is
# overwritten in place with the resolved status. On non TTY output, results
# are printed in a single pass at the end.
#
# Args: each entry json as a separate argument.
fleet_adapter_probe_parallel() {
    local n="$#"
    [ "$n" -eq 0 ] && return 0

    local tmpdir
    tmpdir="$(mktemp -d -t fleet_probe.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local i=0 entry pids=() entries=()
    for entry in "$@"; do
        entries+=("$entry")
        ( fleet_adapter_health "$entry" > "$tmpdir/$i.json" 2>/dev/null ) &
        pids+=($!)
        i=$((i+1))
    done

    if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
        # Print queued placeholder rows so terminals that scroll do not lose context.
        local atype
        for ((i=0; i<n; i++)); do
            atype="$(fleet_adapter_resolve "${entries[$i]}")"
            _fleet_adapter_render_row "${entries[$i]}" '{"status":"queued","elapsed_ms":0,"verified":false}' "$atype" 1
        done
        # Move cursor up n lines to the start of the block.
        printf "\033[%dA" "$n"

        local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        local fi=0 done_mask=()
        for ((i=0; i<n; i++)); do done_mask[i]=0; done

        local running=$n loop_count=0
        while [ "$running" -gt 0 ] && [ "$loop_count" -lt 600 ]; do
            running=0
            for ((i=0; i<n; i++)); do
                if [ "${done_mask[$i]}" = "0" ]; then
                    if [ -s "$tmpdir/$i.json" ] && ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        # Probe finished: render real row.
                        local res atype2
                        res="$(cat "$tmpdir/$i.json" 2>/dev/null)"
                        atype2="$(fleet_adapter_resolve "${entries[$i]}")"
                        printf "\033[%dB\r\033[K" "$i"
                        _fleet_adapter_render_row "${entries[$i]}" "$res" "$atype2" 0
                        printf "\033[%dA" "$((i+1))"
                        done_mask[i]=1
                    else
                        running=$((running+1))
                        # Animate this row's spinner in place.
                        local frame="${frames[$((fi % 10))]}"
                        printf "\033[%dB\r  \033[36m%s\033[0m" "$i" "$frame"
                        printf "\033[%dA\r" "$((i+1))"
                    fi
                fi
            done
            fi=$((fi+1))
            loop_count=$((loop_count+1))
            sleep 0.07
        done
        # Move cursor down past the block.
        printf "\033[%dB" "$n"
        # Final pass to ensure any rows missed by the loop are correctly drawn.
        printf "\033[%dA" "$n"
        for ((i=0; i<n; i++)); do
            if [ "${done_mask[$i]}" = "0" ]; then
                local res atype2
                res="$(cat "$tmpdir/$i.json" 2>/dev/null)"
                [ -z "$res" ] && res='{"status":"error","code":"","elapsed_ms":0,"verified":false,"message":"no output"}'
                atype2="$(fleet_adapter_resolve "${entries[$i]}")"
                printf "\r\033[K"
                _fleet_adapter_render_row "${entries[$i]}" "$res" "$atype2" 0
            else
                printf "\033[1B"
            fi
        done
    else
        wait "${pids[@]}" 2>/dev/null
        for ((i=0; i<n; i++)); do
            local res atype2
            res="$(cat "$tmpdir/$i.json" 2>/dev/null)"
            [ -z "$res" ] && res='{"status":"error","code":"","elapsed_ms":0,"verified":false,"message":"no output"}'
            atype2="$(fleet_adapter_resolve "${entries[$i]}")"
            _fleet_adapter_render_row "${entries[$i]}" "$res" "$atype2" 0
        done
    fi
    wait "${pids[@]}" 2>/dev/null

    # Footer summary line.
    if [ "$n" -gt 0 ]; then
        _fleet_adapter_render_footer "$tmpdir" "$n"
    fi
}

# Look up a runtime or agent by name from config.
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
