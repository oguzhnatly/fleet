#!/bin/bash
# fleet runtime: register, test, list, and remove cross runtime entries.
# Runtimes are entries that are monitored alongside agents but use the v4
# adapter layer instead of the OpenClaw default. They live under the
# "runtimes" key in config.json.

cmd_runtime() {
    fleet_adapter_load_all
    local sub="${1:-}"
    case "$sub" in
        add)    shift; _runtime_add "$@" ;;
        test)   shift; _runtime_test "$@" ;;
        list|ls) shift; _runtime_list "$@" ;;
        rm|remove|delete) shift; _runtime_remove "$@" ;;
        ""|help|-h|--help) _runtime_help ;;
        *)
            echo "  Unknown runtime subcommand: $sub"
            echo "  Run 'fleet runtime help' for usage."
            return 1
            ;;
    esac
}

_runtime_help() {
    cat <<'HELP'

  fleet runtime: cross runtime registry (v4)

  USAGE
    fleet runtime add <name> <type> [options]   Register a new runtime
    fleet runtime test <name>                   One off health probe
    fleet runtime list                          List runtimes with status
    fleet runtime rm <name>                     Remove a runtime

  TYPES
    openclaw   OpenClaw gateway probe (port required)
    http       Generic HTTP probe (url required)
    docker     Docker container state (container required)
    process    OS process via pgrep (process required, inferred)

  OPTIONS
    --port=N             OpenClaw gateway port
    --host=H             OpenClaw host (default 127.0.0.1)
    --token=T            Bearer token for HTTP auth fallback
    --url=URL            HTTP probe URL
    --version-url=URL    Optional URL for version endpoint
    --expected-status=N  Expected HTTP status (default 200)
    --method=M           HTTP method (default GET)
    --container=NAME     Docker container name or id
    --process=PAT        Process pattern for pgrep
    --match-full         Match full command line (process adapter)
    --role=R             Operator label
    --model=M            Operator label
    --header K=V         Extra HTTP header (repeatable)

  EXAMPLES
    fleet runtime add billing-api http --url=https://api.example.com/health
    fleet runtime add postgres docker --container=postgres
    fleet runtime add tailscale process --process=tailscaled
    fleet runtime test billing-api

HELP
}

# Parse argv into a single JSON entry. Echo the JSON.
_runtime_parse_args() {
    local name="$1" type="$2"; shift 2
    python3 - "$name" "$type" "$@" <<'PARSE_PY'
import json, sys
name, atype = sys.argv[1], sys.argv[2]
entry = {"name": name, "adapter": atype}
i = 3
headers = {}
while i < len(sys.argv):
    arg = sys.argv[i]
    val = None
    key = None
    if arg.startswith("--"):
        if "=" in arg:
            key, val = arg[2:].split("=", 1)
        else:
            key = arg[2:]
            if i + 1 < len(sys.argv) and not sys.argv[i+1].startswith("--"):
                val = sys.argv[i+1]
                i += 1
            else:
                val = True
        i += 1
    else:
        i += 1
        continue
    norm = key.replace("-", "_")
    if norm == "port":
        try: entry["port"] = int(val)
        except: entry["port"] = val
    elif norm == "host": entry["host"] = val
    elif norm == "token": entry["token"] = val
    elif norm == "url": entry["url"] = val
    elif norm == "version_url": entry["versionUrl"] = val
    elif norm == "expected_status":
        try: entry["expectedStatus"] = int(val)
        except: entry["expectedStatus"] = val
    elif norm == "method": entry["method"] = val
    elif norm == "container": entry["container"] = val
    elif norm == "process": entry["process"] = val
    elif norm == "match_full": entry["matchFull"] = bool(val) if val is not True else True
    elif norm == "role": entry["role"] = val
    elif norm == "model": entry["model"] = val
    elif norm == "header" and isinstance(val, str) and "=" in val:
        k, v = val.split("=", 1)
        headers[k] = v
    else:
        entry[norm] = val
if headers:
    entry["headers"] = headers
print(json.dumps(entry))
PARSE_PY
}

_runtime_add() {
    if [ "$#" -lt 2 ]; then
        echo "  Usage: fleet runtime add <name> <type> [options]"
        echo "  Run 'fleet runtime help' for full options."
        return 1
    fi
    local name="$1" type="$2"
    if ! fleet_adapter_exists "$type"; then
        out_fail "Unknown adapter type: $type"
        echo "       Available types: $(fleet_adapter_types | tr '\n' ' ')"
        return 1
    fi
    fleet_validate_config 2>/dev/null || {
        out_fail "No config at $FLEET_CONFIG_PATH"
        echo "       Run: fleet init"
        return 1
    }
    local entry_json
    entry_json="$(_runtime_parse_args "$@")"

    local validation
    validation="$(fleet_adapter_validate "$entry_json")"
    if [ "$validation" != "ok" ]; then
        out_fail "Missing required fields for $type adapter: $validation"
        echo "       Run 'fleet runtime help' for the option list."
        return 1
    fi

    local action
    action="$(python3 - "$FLEET_CONFIG_PATH" "$entry_json" <<'ADD_PY'
import json, os, sys
config_path = sys.argv[1]
entry = json.loads(sys.argv[2])
with open(config_path) as f:
    cfg = json.load(f)
cfg.setdefault("runtimes", [])
if any(a.get("name") == entry["name"] for a in cfg.get("agents", [])):
    print("DUPLICATE_AGENT")
    sys.exit(2)
existing = next((i for i,r in enumerate(cfg["runtimes"]) if r.get("name") == entry["name"]), -1)
if existing >= 0:
    cfg["runtimes"][existing] = entry
    action = "updated"
else:
    cfg["runtimes"].append(entry)
    action = "added"
tmp = config_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, config_path)
try: os.chmod(config_path, 0o600)
except Exception: pass
print(action)
ADD_PY
)"
    local rc=$?
    if [ $rc -eq 2 ] || [ "$action" = "DUPLICATE_AGENT" ]; then
        out_fail "Name '$name' already used by an agent. Pick another name."
        return 1
    fi
    if [ "$action" = "updated" ]; then
        out_ok "Updated runtime '$name' (type: $type)"
    else
        out_ok "Registered runtime '$name' (type: $type)"
    fi
    out_dim "Probe it now: fleet runtime test $name"
}

# Animated probe with a small spinner so a slow runtime is visibly working.
_runtime_spinner() {
    local pid="$1" label="$2"
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    [ -t 1 ] || { wait "$pid" 2>/dev/null; return; }
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CLR_CYAN}%s${CLR_RESET} %s" "${frames[$((i % 10))]}" "$label"
        i=$((i + 1))
        sleep 0.08
    done
    printf "\r\033[K"
    wait "$pid" 2>/dev/null
}

_runtime_test() {
    if [ "$#" -lt 1 ]; then
        echo "  Usage: fleet runtime test <name>"
        return 1
    fi
    local name="$1"
    local entry_json
    entry_json="$(fleet_runtime_get "$name")" || {
        out_fail "No runtime or agent named '$name'"
        return 1
    }
    local atype
    atype="$(fleet_adapter_resolve "$entry_json")"

    out_header "Probe: $name"
    out_kv "adapter" "$atype"
    out_kv "verified" "$(adapter_"${atype}"_verified 2>/dev/null || echo unknown)"
    out_kv "describe" "$(adapter_"${atype}"_describe 2>/dev/null || echo "")"

    local tmp_health tmp_info tmp_ver
    tmp_health="$(mktemp -t fleet_health.XXXXXX)"
    tmp_info="$(mktemp -t fleet_info.XXXXXX)"
    tmp_ver="$(mktemp -t fleet_ver.XXXXXX)"
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_health' '$tmp_info' '$tmp_ver'" RETURN

    ( fleet_adapter_health "$entry_json" >"$tmp_health" ) &
    local pid=$!
    _runtime_spinner "$pid" "running health probe..."

    fleet_adapter_info "$entry_json" >"$tmp_info" &
    local pid_i=$!
    fleet_adapter_version "$entry_json" >"$tmp_ver" &
    local pid_v=$!
    wait "$pid_i" "$pid_v" 2>/dev/null

    out_section "Health"
    python3 - "$(cat "$tmp_health")" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  could not parse adapter response")
    sys.exit(0)
status = d.get("status","?"); code = d.get("code",""); ms = d.get("elapsed_ms",0)
verified = d.get("verified", False); msg = d.get("message","")
G="\033[32m"; R="\033[31m"; Y="\033[33m"; D="\033[2m"; N="\033[0m"
icon = G+"⬢"+N if status == "online" else (Y+"⚠"+N if status in ("starting","degraded","auth_failed") else R+"⬡"+N)
clr  = G if status == "online" else (Y if status in ("starting","degraded","auth_failed") else R)
print(f"  {icon} {clr}{status}{N} {D}code={code} {ms}ms verified={str(verified).lower()}{N}")
if msg: print(f"  {D}note: {msg}{N}")
PY

    out_section "Info"
    python3 - "$(cat "$tmp_info")" <<'PY'
import json, sys
try: d = json.loads(sys.argv[1])
except Exception: d = {}
for k in ("type","endpoint","role","model"):
    v = d.get(k,"")
    if v: print(f"  {k:10} {v}")
PY

    out_section "Version"
    python3 - "$(cat "$tmp_ver")" <<'PY'
import json, sys
try: d = json.loads(sys.argv[1])
except Exception: d = {}
v = d.get("version",""); ver_ok = d.get("verified", False)
if v:
    tag = "verified" if ver_ok else "best effort"
    print(f"  {v}  ({tag})")
else:
    print(f"  unknown")
PY
    echo ""
}

_runtime_list() {
    fleet_validate_config 2>/dev/null || {
        out_fail "No config at $FLEET_CONFIG_PATH"
        return 1
    }
    out_header "Runtimes"

    local entries=()
    local line kind
    while IFS= read -r line; do
        kind="${line%%$'\t'*}"
        [ "$kind" = "runtime" ] || continue
        entries+=("${line#*$'\t'}")
    done < <(fleet_adapter_iter_entries)

    if [ "${#entries[@]}" -eq 0 ]; then
        out_dim "No runtimes registered."
        out_dim "Add one with: fleet runtime add <name> <type> [options]"
        echo ""
        return 0
    fi

    fleet_adapter_probe_parallel "${entries[@]}"
    echo ""
    out_dim "$(printf '%d runtime%s probed via %s adapters' \
        "${#entries[@]}" "$([ ${#entries[@]} -eq 1 ] && echo '' || echo 's')" "$(fleet_adapter_types | tr '\n' ' ' | sed 's/ $//')")"
    echo ""
}

_runtime_remove() {
    if [ "$#" -lt 1 ]; then
        echo "  Usage: fleet runtime rm <name>"
        return 1
    fi
    local name="$1"
    fleet_validate_config 2>/dev/null || {
        out_fail "No config at $FLEET_CONFIG_PATH"
        return 1
    }
    local result
    result="$(python3 - "$FLEET_CONFIG_PATH" "$name" <<'RM_PY'
import json, os, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
runtimes = cfg.get("runtimes", [])
new = [r for r in runtimes if r.get("name") != name]
if len(new) == len(runtimes):
    print("not_found")
    sys.exit(0)
cfg["runtimes"] = new
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, path)
try: os.chmod(path, 0o600)
except Exception: pass
print("removed")
RM_PY
)"
    if [ "$result" = "not_found" ]; then
        out_fail "No runtime named '$name'"
        return 1
    fi
    out_ok "Removed runtime '$name'"
}
