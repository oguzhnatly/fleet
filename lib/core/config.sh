#!/bin/bash
# fleet/lib/core/config.sh: Configuration loader and resolver
# Reads ~/.fleet/config.json (or $FLEET_CONFIG) and provides accessor functions.

# shellcheck disable=SC2034
FLEET_VERSION="4.0.1"
FLEET_CONFIG_PATH="${FLEET_CONFIG:-$HOME/.fleet/config.json}"
FLEET_LOG_FILE="${FLEET_LOG:-$HOME/.fleet/log.jsonl}"

# ── JSON helper (portable, no jq dependency) ────────────────────────────────
_json_get() {
    local file="$1" key="$2" default="${3:-}"
    if [ ! -f "$file" ]; then echo "$default"; return; fi
    python3 - "$file" "$key" "$default" <<'PY_JSON_GET' 2>/dev/null
import json, sys
path, key, default = sys.argv[1:4]
try:
    with open(path) as f:
        c = json.load(f)
    v = c
    for k in key.split('.'):
        if isinstance(v, dict):
            v = v[k]
        elif isinstance(v, list):
            v = v[int(k)]
        else:
            raise KeyError
    if isinstance(v, (dict, list)):
        print(json.dumps(v))
    else:
        print(v)
except (KeyError, TypeError, IndexError, ValueError, OSError, json.JSONDecodeError):
    print(default)
PY_JSON_GET
}

_json_array_len() {
    local file="$1" key="$2"
    if [ ! -f "$file" ]; then echo "0"; return; fi
    python3 - "$file" "$key" <<'PY_JSON_LEN' 2>/dev/null || echo "0"
import json, sys
try:
    with open(sys.argv[1]) as f:
        c = json.load(f)
    v = c
    for k in sys.argv[2].split('.'):
        v = v.get(k, []) if isinstance(v, dict) else []
    print(len(v) if isinstance(v, list) else 0)
except Exception:
    print(0)
PY_JSON_LEN
}

# ── Config accessors ────────────────────────────────────────────────────────
fleet_workspace() {
    local ws="${FLEET_WORKSPACE:-$(_json_get "$FLEET_CONFIG_PATH" "workspace" "")}"
    # Expand tilde
    ws="${ws/#\~/$HOME}"
    echo "${ws:-$HOME}"
}

fleet_gateway_port() {
    _json_get "$FLEET_CONFIG_PATH" "gateway.port" "48391"
}

fleet_gateway_name() {
    _json_get "$FLEET_CONFIG_PATH" "gateway.name" "coordinator"
}

fleet_has_config() {
    [ -f "$FLEET_CONFIG_PATH" ]
}

# ── Config validation ───────────────────────────────────────────────────────
fleet_validate_config() {
    if [ ! -f "$FLEET_CONFIG_PATH" ]; then
        echo "No config found at $FLEET_CONFIG_PATH"
        echo ""
        echo "Create one with: fleet init"
        echo "Or set FLEET_CONFIG to point to your config file."
        return 1
    fi

    # Validate JSON
    python3 - "$FLEET_CONFIG_PATH" <<'PY_VALIDATE_CONFIG' 2>/dev/null || return 1
import json, sys
try:
    with open(sys.argv[1]) as f:
        json.load(f)
except json.JSONDecodeError as e:
    print(f'Invalid JSON in config: {e}')
    sys.exit(1)
except OSError as e:
    print(f'Cannot read config: {e}')
    sys.exit(1)
PY_VALIDATE_CONFIG
}
