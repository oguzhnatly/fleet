#!/bin/bash
# fleet runtime: register, probe, list, and remove cross runtime entries.

cmd_runtime() {
    fleet_adapter_load_all
    local sub="${1:-}"
    case "$sub" in
        add)              shift; _runtime_add "$@" ;;
        test|probe)       shift; _runtime_test "$@" ;;
        list|ls)          shift; _runtime_list "$@" ;;
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

  fleet runtime  cross runtime registry (v4)

  USAGE
    fleet runtime add <name> <type> [options]   Register a new runtime
    fleet runtime test <name>                   One off health probe
    fleet runtime list                          List runtimes with live status
    fleet runtime rm <name>                     Remove a runtime

  TYPES
    openclaw   OpenClaw gateway probe (port required, verified)
    http       Generic HTTP probe (url required, verified)
    docker     Docker container state (container required, verified)
    process    OS process via pgrep (process required, inferred)

  OPTIONS
    --port=N             OpenClaw port
    --host=H             OpenClaw host (default 127.0.0.1)
    --token=T            Bearer token for HTTP or OpenClaw auth
    --url=URL            HTTP probe URL
    --version-url=URL    Optional separate version endpoint
    --expected-status=N  Expected HTTP status (default 200)
    --method=M           HTTP method (default GET)
    --container=NAME     Docker container name or id
    --process=PAT        Process pattern for pgrep
    --match-full         Match full command line (process adapter)
    --role=R             Display label
    --model=M            Display label
    --header K=V         Extra HTTP header (repeatable)

  EXAMPLES
    fleet runtime add billing-api http --url=https://api.example.com/health
    fleet runtime add postgres docker --container=postgres
    fleet runtime add tailscale process --process=tailscaled
    fleet runtime test billing-api

HELP
}

# Parse argv into a single JSON entry and echo the JSON.
_runtime_parse_args() {
    local name="$1" type="$2"; shift 2
    python3 - "$name" "$type" "$@" <<'PARSE_PY'
import json, sys
name, atype = sys.argv[1], sys.argv[2]
entry = {"name": name, "adapter": atype}
i = 3
headers = {}
def parse_bool(value):
    if value is True:
        return True
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in ("false", "0", "no", "off", "n"):
            return False
        if lowered in ("true", "1", "yes", "on", "y"):
            return True
    return bool(value)
while i < len(sys.argv):
    arg = sys.argv[i]
    key = val = None
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
        except Exception: entry["port"] = val
    elif norm == "host":          entry["host"] = val
    elif norm == "token":         entry["token"] = val
    elif norm == "url":           entry["url"] = val
    elif norm == "version_url":   entry["versionUrl"] = val
    elif norm == "expected_status":
        try: entry["expectedStatus"] = int(val)
        except Exception: entry["expectedStatus"] = val
    elif norm == "method":        entry["method"] = val
    elif norm == "container":     entry["container"] = val
    elif norm == "process":       entry["process"] = val
    elif norm == "match_full":    entry["matchFull"] = parse_bool(val)
    elif norm == "role":          entry["role"] = val
    elif norm == "model":         entry["model"] = val
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
        printf "       Available types: %s\n" "$(fleet_adapter_types | tr '\n' ' ')"
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
        out_fail "Name '$name' is already used by an agent. Choose another name."
        return 1
    fi
    if [ "$action" = "updated" ]; then
        out_ok "Updated runtime '$name'  (adapter: $type)"
    else
        out_ok "Registered runtime '$name'  (adapter: $type)"
    fi
    out_dim "Probe now: fleet runtime test $name"
}

# Animated single-target probe with spinner and sectioned reveal.
_runtime_spinner() {
    local pid="$1" label="$2"
    local frames=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local i=0
    [ -t 1 ] || { wait "$pid" 2>/dev/null; return; }
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CLR_CYAN}%s${CLR_RESET}  %s${CLR_DIM}...${CLR_RESET}" \
            "${frames[$((i % 10))]}" "$label"
        i=$((i+1))
        sleep 0.07
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
    local atype_verified
    atype_verified="$(adapter_"${atype}"_verified 2>/dev/null || echo "unknown")"
    local atype_desc
    atype_desc="$(adapter_"${atype}"_describe 2>/dev/null || echo "")"

    echo ""
    printf "  ${CLR_BOLD}Probe${CLR_RESET}  %s\n" "$name"
    printf "  %s\n" "$(printf '%.0s─' {1..56})"
    printf "  %-14s %s\n" "adapter" "${CLR_CYAN}${atype}${CLR_RESET}"
    if [ "$atype_verified" = "verified" ]; then
        printf "  %-14s %s\n" "mode" "${CLR_GREEN}verified${CLR_RESET}"
    else
        printf "  %-14s %s\n" "mode" "${CLR_YELLOW}inferred${CLR_RESET}"
    fi
    printf "  %-14s %s\n" "description" "${CLR_DIM}${atype_desc}${CLR_RESET}"
    echo ""

    local tmp_health tmp_info tmp_ver
    tmp_health="$(mktemp -t fleet_health.XXXXXX)"
    tmp_info="$(mktemp -t fleet_info.XXXXXX)"
    tmp_ver="$(mktemp -t fleet_ver.XXXXXX)"

    fleet_adapter_info    "$entry_json" > "$tmp_info" &
    fleet_adapter_version "$entry_json" > "$tmp_ver"  &
    local pid_i=$! pid_v=$!

    ( fleet_adapter_health "$entry_json" > "$tmp_health" ) &
    local pid_h=$!
    _runtime_spinner "$pid_h" "running health probe"
    wait "$pid_i" "$pid_v" 2>/dev/null

    # Health section
    printf "  %sHealth%s\n" "$CLR_BOLD" "$CLR_RESET"
    CLR_GREEN="$CLR_GREEN" CLR_RED="$CLR_RED" CLR_YELLOW="$CLR_YELLOW" \
    CLR_DIM="$CLR_DIM" CLR_BOLD="$CLR_BOLD" CLR_RESET="$CLR_RESET" \
    python3 - "$(cat "$tmp_health")" <<'HEALTH_PY'
import json, os, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("  could not parse adapter response")
    sys.exit(0)
G=os.environ.get("CLR_GREEN",""); R=os.environ.get("CLR_RED",""); Y=os.environ.get("CLR_YELLOW",""); D=os.environ.get("CLR_DIM",""); B=os.environ.get("CLR_BOLD",""); N=os.environ.get("CLR_RESET","")
status = d.get("status","?"); code = d.get("code",""); ms = d.get("elapsed_ms",0)
verified = d.get("verified", False); msg = d.get("message","")
if status == "online":
    icon = G+"⬢"+N; badge = G+"● online"+N
elif status in ("starting","degraded","auth_failed"):
    icon = Y+"◐"+N; badge = Y+f"● {status}"+N
else:
    icon = R+"⬡"+N; badge = R+f"● {status}"+N
ver_tag = (D+"verified"+N) if verified else (Y+"inferred"+N)
print(f"  {icon}  {badge}  {D}code={code}  {ms}ms  [{ver_tag}{D}]{N}")
if msg: print(f"  {D}note: {msg}{N}")
HEALTH_PY

    echo ""

    # Info section
    printf "  %sInfo%s\n" "$CLR_BOLD" "$CLR_RESET"
    CLR_DIM="$CLR_DIM" CLR_CYAN="$CLR_CYAN" CLR_RESET="$CLR_RESET" \
    python3 - "$(cat "$tmp_info")" <<'INFO_PY'
import json, os, sys
try: d = json.loads(sys.argv[1])
except Exception: d = {}
D=os.environ.get("CLR_DIM",""); C=os.environ.get("CLR_CYAN",""); N=os.environ.get("CLR_RESET","")
for k in ("type","endpoint","role","model"):
    v = d.get(k,"")
    if v: print(f"  {D}{k:<12}{N} {C}{v}{N}")
INFO_PY

    echo ""

    # Version section
    printf "  %sVersion%s\n" "$CLR_BOLD" "$CLR_RESET"
    CLR_GREEN="$CLR_GREEN" CLR_YELLOW="$CLR_YELLOW" CLR_DIM="$CLR_DIM" CLR_RESET="$CLR_RESET" \
    python3 - "$(cat "$tmp_ver")" <<'VER_PY'
import json, os, sys
try: d = json.loads(sys.argv[1])
except Exception: d = {}
G=os.environ.get("CLR_GREEN",""); Y=os.environ.get("CLR_YELLOW",""); D=os.environ.get("CLR_DIM",""); N=os.environ.get("CLR_RESET","")
v = d.get("version",""); ok = d.get("verified", False)
if v:
    tag = (G+"verified"+N) if ok else (Y+"best effort"+N)
    print(f"  {v}  {D}({N}{tag}{D}){N}")
else:
    print(f"  {D}unknown{N}")
VER_PY

    echo ""

    # Verdict footer
    CLR_GREEN="$CLR_GREEN" CLR_RED="$CLR_RED" CLR_YELLOW="$CLR_YELLOW" \
    CLR_DIM="$CLR_DIM" CLR_BOLD="$CLR_BOLD" CLR_RESET="$CLR_RESET" \
    python3 - "$(cat "$tmp_health")" "$name" "$atype" <<'VERDICT_PY'
import json, os, sys
try:
    h = json.loads(sys.argv[1])
except Exception:
    h = {}
name, atype = sys.argv[2], sys.argv[3]
G=os.environ.get("CLR_GREEN",""); R=os.environ.get("CLR_RED",""); Y=os.environ.get("CLR_YELLOW",""); D=os.environ.get("CLR_DIM",""); B=os.environ.get("CLR_BOLD",""); N=os.environ.get("CLR_RESET","")
s = h.get("status","?"); ms = h.get("elapsed_ms",0)
if s == "online":
    icon = G+"✔"+N; label = G+f"{name} is reachable"+N
elif s in ("starting","degraded"):
    icon = Y+"●"+N; label = Y+f"{name} is {s}"+N
elif s == "auth_failed":
    icon = Y+"●"+N; label = Y+f"{name}: auth failed, check token"+N
else:
    icon = R+"✘"+N; label = R+f"{name} is {s}"+N
print(f"  {D}{'─'*56}{N}")
print(f"  {icon}  {B}{label}{N}  {D}via {atype}  {ms}ms{N}")
print()
VERDICT_PY
    rm -f "$tmp_health" "$tmp_info" "$tmp_ver"
}

_runtime_list() {
    fleet_validate_config 2>/dev/null || {
        out_fail "No config at $FLEET_CONFIG_PATH"
        echo "       Run: fleet init"
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
