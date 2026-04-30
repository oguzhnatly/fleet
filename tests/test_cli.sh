#!/usr/bin/env bash
# fleet integration tests
set -uo pipefail

FLEET="$(cd "$(dirname "$0")/.." && pwd)/bin/fleet"
PASS=0
FAIL=0

# Use homebrew bash on macOS; fall back to whatever bash is on PATH
FBASH=/opt/homebrew/bin/bash
[ -x "$FBASH" ] || FBASH=bash

assert_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "  ✅ $desc"
        ((PASS++))
    else
        echo "  ❌ $desc"
        ((FAIL++))
    fi
}

assert_output_contains() {
    local desc="$1" expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1)
    if echo "$output" | grep -q "$expected"; then
        echo "  ✅ $desc"
        ((PASS++))
    else
        echo "  ❌ $desc (expected '$expected')"
        ((FAIL++))
    fi
}

echo ""
echo "Fleet CLI Tests"
echo "═══════════════"

echo ""
echo "Syntax"
FLEET_ROOT="$(cd "$(dirname "$FLEET")/.." && pwd)"
for f in "$FLEET" "$FLEET_ROOT"/lib/core/*.sh "$FLEET_ROOT"/lib/adapters/*.sh "$FLEET_ROOT"/lib/commands/*.sh; do
    [ -f "$f" ] && assert_ok "syntax: $(basename "$f")" bash -n "$f"
done

echo ""
echo "Basic Commands"
assert_ok "help exits 0" "$FBASH" "$FLEET" help
assert_ok "--version exits 0" "$FBASH" "$FLEET" --version
assert_output_contains "version format" "fleet v" "$FBASH" "$FLEET" --version
assert_output_contains "help contains commands" "fleet health" "$FBASH" "$FLEET" help

echo ""
echo "Config"
# Health gracefully falls back to defaults when no config
FLEET_CONFIG=/nonexistent/path assert_ok "health without config works" "$FBASH" "$FLEET" health

echo ""
echo "JSON Validation"
for f in "$FLEET_ROOT"/examples/*/config.json "$FLEET_ROOT"/templates/configs/*.json; do
    if [ -f "$f" ]; then
        assert_ok "valid JSON: $(basename "$(dirname "$f")")/$(basename "$f")" python3 -c "import json; json.load(open('$f'))"
    fi
done

echo ""
echo "Operator Constitution"
assert_output_contains "help contains policy" "fleet policy" "$FBASH" "$FLEET" help
_TMP_POLICY_CFG=$(mktemp /tmp/fleet-policy-cfg.XXXXXX.json)
cat > "$_TMP_POLICY_CFG" <<'CFGDATA'
{"workspace":"~/workspace","agents":[{"name":"coder","port":48520}],"constitution":{"enabled":true,"title":"Team Constitution","rules":["Never rewrite shared history","Run verification before completion"]}}
CFGDATA
assert_output_contains "policy show lists configured rule" "Never rewrite shared history" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG' '$FLEET' policy"
assert_output_contains "policy preview injects rule" "Run verification before completion" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG' '$FLEET' policy preview coder 'fix tests' --type code"
assert_ok "policy apply prepends task" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG'; source '$FLEET_ROOT/lib/core/config.sh'; source '$FLEET_ROOT/lib/core/policy.sh'; out=\$(fleet_policy_apply 'fix tests' coder code); echo \"\$out\" | grep -q 'Team Constitution'; echo \"\$out\" | grep -q 'Task:'"
cat > "$_TMP_POLICY_CFG" <<'CFGDATA'
{"workspace":"~/workspace","agents":[{"name":"coder","port":48520}],"constitution":{"enabled":false,"rules":["Should not appear"]}}
CFGDATA
assert_ok "disabled policy leaves prompt unchanged" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG'; source '$FLEET_ROOT/lib/core/config.sh'; source '$FLEET_ROOT/lib/core/policy.sh'; out=\$(fleet_policy_apply 'fix tests' coder code); [ \"\$out\" = 'fix tests' ]"
assert_ok "policy enable command updates config" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG' '$FLEET' policy enable >/dev/null; python3 -c 'import json; d=json.load(open(\"$_TMP_POLICY_CFG\")); assert d[\"constitution\"][\"enabled\"] is True'"
assert_ok "policy add command appends rule" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG' '$FLEET' policy add 'Require local tests' >/dev/null; python3 -c 'import json; d=json.load(open(\"$_TMP_POLICY_CFG\")); assert \"Require local tests\" in d[\"constitution\"][\"rules\"]'"
assert_ok "policy rm command removes rule" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG' '$FLEET' policy rm 1 >/dev/null; python3 -c 'import json; d=json.load(open(\"$_TMP_POLICY_CFG\")); assert \"Should not appear\" not in d[\"constitution\"][\"rules\"]'"
assert_ok "policy title command updates title" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG' '$FLEET' policy title 'Team Rules' >/dev/null; python3 -c 'import json; d=json.load(open(\"$_TMP_POLICY_CFG\")); assert d[\"constitution\"][\"title\"] == \"Team Rules\"'"
assert_ok "policy clear command empties rules" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_POLICY_CFG' '$FLEET' policy clear >/dev/null; python3 -c 'import json; d=json.load(open(\"$_TMP_POLICY_CFG\")); assert d[\"constitution\"][\"rules\"] == []'"
rm -f "$_TMP_POLICY_CFG"

echo ""
echo "Trust Engine (v3)"
assert_ok "trust.sh syntax" bash -n "$FLEET_ROOT/lib/core/trust.sh"
assert_ok "trust command syntax" bash -n "$FLEET_ROOT/lib/commands/trust.sh"
assert_ok "score command syntax" bash -n "$FLEET_ROOT/lib/commands/score.sh"
assert_ok "trust help exits 0" "$FBASH" "$FLEET" trust --help
assert_ok "score help exits 0" "$FBASH" "$FLEET" score --help
assert_output_contains "help contains trust" "fleet trust" "$FBASH" "$FLEET" help
assert_output_contains "help contains score" "fleet score" "$FBASH" "$FLEET" help

# trust with no log: verify graceful exit
FLEET_LOG=/nonexistent/log.jsonl assert_ok "trust with no log" "$FBASH" "$FLEET" trust
FLEET_LOG=/nonexistent/log.jsonl assert_ok "score with no log" "$FBASH" "$FLEET" score

# trust with minimal synthetic log
_TMP_LOG=$(mktemp /tmp/fleet-test-log.XXXXXX.jsonl)
cat > "$_TMP_LOG" <<'LOGDATA'
{"task_id":"aaa00001","agent":"coder","task_type":"code","prompt":"add pagination","dispatched_at":"2026-03-15T10:00:00Z","completed_at":"2026-03-15T10:08:00Z","outcome":"success","steer_count":0}
{"task_id":"aaa00002","agent":"coder","task_type":"code","prompt":"fix auth bug","dispatched_at":"2026-03-15T11:00:00Z","completed_at":"2026-03-15T11:15:00Z","outcome":"steered","steer_count":1}
{"task_id":"aaa00003","agent":"reviewer","task_type":"review","prompt":"review PR #12","dispatched_at":"2026-03-15T12:00:00Z","completed_at":"2026-03-15T12:05:00Z","outcome":"success","steer_count":0}
{"task_id":"aaa00004","agent":"deployer","task_type":"deploy","prompt":"deploy to railway","dispatched_at":"2026-03-15T13:00:00Z","completed_at":"2026-03-15T13:20:00Z","outcome":"failure","steer_count":0}
LOGDATA

_EXAMPLE_CFG="$FLEET_ROOT/examples/solo-empire/config.json"
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_ok "trust with log data" "$FBASH" "$FLEET" trust
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_output_contains "trust shows coder" "coder" "$FBASH" "$FLEET" trust
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_ok "score with specific agent" "$FBASH" "$FLEET" score coder
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_output_contains "score shows percentage" "%" "$FBASH" "$FLEET" score coder
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_ok "trust json mode" "$FBASH" "$FLEET" trust --json
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" \
    assert_ok "trust json is valid JSON" \
    "$FBASH" -c "FLEET_CONFIG=\"$_EXAMPLE_CFG\" FLEET_LOG=\"$_TMP_LOG\" \"$FBASH\" \"$FLEET\" trust --json | python3 -c 'import json,sys; json.load(sys.stdin)'"

rm -f "$_TMP_LOG"

# update command
assert_ok "update.sh syntax" bash -n "$FLEET_ROOT/lib/commands/update.sh"
assert_ok "update help exits 0" "$FBASH" "$FLEET" update --help
assert_output_contains "help contains update" "fleet update" "$FBASH" "$FLEET" help
assert_ok "update check exits 0 with no network" "$FBASH" -c "
    FLEET_STATE_DIR=\$(mktemp -d) \"$FBASH\" \"$FLEET\" update --check 2>/dev/null; true
"
assert_ok "update install dir detection" "$FBASH" -c "
    type fleet >/dev/null 2>&1 || export PATH=\"\$PATH:\$(dirname \"$FLEET\")\"
    true
"

echo ""
echo "Adapter Layer (v4)"
assert_ok "adapters.sh (core) syntax" bash -n "$FLEET_ROOT/lib/core/adapters.sh"
assert_ok "adapters.sh (command) syntax" bash -n "$FLEET_ROOT/lib/commands/adapters.sh"
assert_ok "runtime.sh (command) syntax" bash -n "$FLEET_ROOT/lib/commands/runtime.sh"
for _a in openclaw http docker process; do
    assert_ok "adapter/$_a.sh syntax" bash -n "$FLEET_ROOT/lib/adapters/$_a.sh"
done

# each built-in adapter must define the full six-function contract
for _a in openclaw http docker process; do
    _af="$FLEET_ROOT/lib/adapters/$_a.sh"
    for _fn in describe verified required health info version; do
        assert_ok "adapter $_a: defines adapter_${_a}_${_fn}" grep -q "adapter_${_a}_${_fn}()" "$_af"
    done
done

# fleet adapters command
assert_ok "fleet adapters exits 0" "$FBASH" "$FLEET" adapters
assert_output_contains "fleet adapters lists openclaw" "openclaw" "$FBASH" "$FLEET" adapters
assert_output_contains "fleet adapters lists http" "http" "$FBASH" "$FLEET" adapters
assert_output_contains "fleet adapters lists docker" "docker" "$FBASH" "$FLEET" adapters
assert_output_contains "fleet adapters lists process" "process" "$FBASH" "$FLEET" adapters

# fleet runtime subcommands
assert_ok "fleet runtime (no args) exits 0" "$FBASH" "$FLEET" runtime
assert_ok "fleet runtimes alias exits 0" "$FBASH" "$FLEET" runtimes
assert_output_contains "help contains fleet adapters" "fleet adapters" "$FBASH" "$FLEET" help
assert_output_contains "help contains fleet runtime" "fleet runtime" "$FBASH" "$FLEET" help

# fleet runtime list shows a helpful error (not a crash) when config is missing
FLEET_CONFIG=/nonexistent/path assert_output_contains "runtime list no config: prompts init" "fleet init" "$FBASH" "$FLEET" runtime list

# cross-runtime example JSON
assert_ok "cross-runtime example valid JSON" \
    python3 -c "import json; d=json.load(open('$FLEET_ROOT/examples/cross-runtime/config.json')); assert 'runtimes' in d"
assert_ok "cross-runtime example has all adapter types" python3 -c "
import json
d = json.load(open('$FLEET_ROOT/examples/cross-runtime/config.json'))
types = {r['adapter'] for r in d['runtimes']}
assert 'openclaw' in types and 'http' in types and 'docker' in types and 'process' in types, types
"

# runtime lifecycle: add, list, test, rm using a temp config
_TMP_CFG=$(mktemp /tmp/fleet-test-cfg.XXXXXX.json)
cat > "$_TMP_CFG" <<'CFGDATA'
{"workspace":"~/workspace","agents":[],"runtimes":[]}
CFGDATA

assert_ok "runtime add (process adapter)" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG' \"$FBASH\" '$FLEET' runtime add test-proc process --process bash"
assert_ok "runtime list shows added entry" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG' \"$FBASH\" '$FLEET' runtime list 2>&1 | grep -q 'test-proc'"
assert_ok "runtime rm removes entry" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG' \"$FBASH\" '$FLEET' runtime rm test-proc"
assert_ok "runtime list empty after rm" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG' \"$FBASH\" '$FLEET' runtime list 2>&1; true"
assert_ok "runtime rm nonexistent exits nonzero" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG' \"$FBASH\" '$FLEET' runtime rm no-such-runtime 2>/dev/null; [ \$? -ne 0 ]"

rm -f "$_TMP_CFG"

echo ""
echo "Adapter Layer (v4) deeper checks"

# Adapter resolution via "type" field as well as "adapter"
assert_ok "resolve via adapter field" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_resolve '{\"adapter\":\"http\",\"url\":\"x\"}'); [ \"\$r\" = http ]"
assert_ok "resolve via type field fallback" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_resolve '{\"type\":\"docker\",\"container\":\"x\"}'); [ \"\$r\" = docker ]"
assert_ok "resolve default openclaw" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_resolve '{\"port\":48391}'); [ \"\$r\" = openclaw ]"

# Validation: ok and missing field cases
assert_ok "validate ok with full http entry" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_validate '{\"adapter\":\"http\",\"url\":\"https://x\"}'); [ \"\$r\" = ok ]"
assert_ok "validate fails on missing http url" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_validate '{\"adapter\":\"http\"}'); [ \"\$r\" = url ]"
assert_ok "validate fails on missing docker container" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_validate '{\"adapter\":\"docker\"}'); [ \"\$r\" = container ]"
assert_ok "validate fails on missing process pattern" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_validate '{\"adapter\":\"process\"}'); [ \"\$r\" = process ]"
assert_ok "validate flags unknown adapter" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_validate '{\"adapter\":\"nope\"}' 2>/dev/null); echo \"\$r\" | grep -q missing_adapter"

# adapter health emits valid JSON for every built-in adapter, even with empty input
for _a in openclaw http docker process; do
    assert_ok "adapter $_a health emits valid JSON for empty entry" \
        "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; fleet_adapter_health '{\"adapter\":\"$_a\"}' | python3 -c 'import json,sys; json.load(sys.stdin)'"
done

# OpenClaw adapter fallback uses authenticated model endpoint when health is not available
_TMP_OPENCLAW_SERVER=$(mktemp /tmp/fleet-openclaw-server.XXXXXX.py)
cat > "$_TMP_OPENCLAW_SERVER" <<'PY_SERVER'
from http.server import BaseHTTPRequestHandler, HTTPServer
import os
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(404)
            self.end_headers()
        elif self.path == "/v1/models":
            self.send_response(401)
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, *args):
        pass
HTTPServer(("127.0.0.1", int(os.environ["PORT"])), Handler).serve_forever()
PY_SERVER
_OPENCLAW_PORT=39292
PORT="$_OPENCLAW_PORT" python3 "$_TMP_OPENCLAW_SERVER" &
_OPENCLAW_PID=$!
sleep 1
assert_ok "openclaw token fallback reaches auth endpoint" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; fleet_adapter_health '{\"adapter\":\"openclaw\",\"port\":$_OPENCLAW_PORT,\"token\":\"x\"}' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"status\"]==\"auth_failed\", d; assert d[\"verified\"] is True, d'"
kill "$_OPENCLAW_PID" 2>/dev/null || true
rm -f "$_TMP_OPENCLAW_SERVER"

# Probe parallel handles zero entries cleanly
assert_ok "probe_parallel zero entries no error" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; fleet_adapter_probe_parallel; true"

# Runtime add idempotency: add same name twice and verify single entry
_TMP_CFG2=$(mktemp /tmp/fleet-test-cfg-idem.XXXXXX.json)
cat > "$_TMP_CFG2" <<'CFGDATA'
{"workspace":"~/workspace","agents":[],"runtimes":[]}
CFGDATA
assert_ok "runtime add (first time)" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG2' \"$FBASH\" '$FLEET' runtime add edge process --process bash"
assert_ok "runtime add (idempotent: same name updates)" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG2' \"$FBASH\" '$FLEET' runtime add edge process --process zsh"
assert_ok "single runtime entry after re-add" \
    python3 -c "import json; d=json.load(open('$_TMP_CFG2')); rs=[r for r in d['runtimes'] if r['name']=='edge']; assert len(rs)==1, len(rs)"
assert_ok "second add updates process pattern" \
    python3 -c "import json; d=json.load(open('$_TMP_CFG2')); rs=[r for r in d['runtimes'] if r['name']=='edge']; assert rs[0]['process']=='zsh', rs[0]"

# Runtime add refuses agent-name conflict
cat > "$_TMP_CFG2" <<'CFGDATA'
{"workspace":"~/workspace","agents":[{"name":"coder","port":48520}],"runtimes":[]}
CFGDATA
assert_ok "runtime add rejects existing agent name" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG2' \"$FBASH\" '$FLEET' runtime add coder process --process bash 2>/dev/null; [ \$? -ne 0 ]"

# Runtime add validates required field at the CLI layer
cat > "$_TMP_CFG2" <<'CFGDATA'
{"workspace":"~/workspace","agents":[],"runtimes":[]}
CFGDATA
assert_ok "runtime add http without url is rejected" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG2' \"$FBASH\" '$FLEET' runtime add billing http 2>/dev/null; [ \$? -ne 0 ]"

# fleet runtime test on unknown name returns non-zero
assert_ok "runtime test unknown name fails" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG2' \"$FBASH\" '$FLEET' runtime test no-such 2>/dev/null; [ \$? -ne 0 ]"

# Custom adapter directory: drop a fake adapter and verify it loads
_TMP_ADAPTERS_DIR=$(mktemp -d /tmp/fleet-test-adapters.XXXXXX)
cat > "$_TMP_ADAPTERS_DIR/dummy.sh" <<'ADAPTER'
adapter_dummy_describe() { echo "Dummy adapter for tests"; }
adapter_dummy_verified() { echo "verified"; }
adapter_dummy_required() { echo "magic"; }
adapter_dummy_health() {
    echo '{"status":"online","code":"DUMMY","elapsed_ms":1,"verified":true,"message":""}'
}
adapter_dummy_info() {
    echo '{"name":"dummy","type":"dummy","endpoint":"none","verified":true}'
}
adapter_dummy_version() {
    echo '{"version":"1.0","verified":true}'
}
ADAPTER
assert_ok "user adapter directory loads custom adapter" \
    "$FBASH" -c "FLEET_ADAPTERS_DIR='$_TMP_ADAPTERS_DIR' \"$FBASH\" '$FLEET' adapters 2>&1 | grep -q dummy"
assert_ok "user adapter validation requires field" \
    "$FBASH" -c "FLEET_ADAPTERS_DIR='$_TMP_ADAPTERS_DIR' FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_adapter_validate '{\"adapter\":\"dummy\"}'); [ \"\$r\" = magic ]"
assert_ok "user adapter health JSON valid" \
    "$FBASH" -c "FLEET_ADAPTERS_DIR='$_TMP_ADAPTERS_DIR' FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; fleet_adapter_health '{\"adapter\":\"dummy\",\"magic\":\"x\"}' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"status\"]==\"online\"'"
rm -rf "$_TMP_ADAPTERS_DIR"

# fleet_runtime_get returns agent or runtime by name
cat > "$_TMP_CFG2" <<'CFGDATA'
{"workspace":"~/workspace","agents":[{"name":"coder","port":48520}],"runtimes":[{"name":"db","adapter":"docker","container":"postgres"}]}
CFGDATA
assert_ok "runtime_get returns agent" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/config.sh'; FLEET_CONFIG='$_TMP_CFG2' FLEET_CONFIG_PATH='$_TMP_CFG2'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_runtime_get coder '$_TMP_CFG2'); echo \"\$r\" | grep -q '\"name\": \"coder\"'"
assert_ok "runtime_get returns runtime" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/config.sh'; FLEET_CONFIG='$_TMP_CFG2' FLEET_CONFIG_PATH='$_TMP_CFG2'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; r=\$(fleet_runtime_get db '$_TMP_CFG2'); echo \"\$r\" | grep -q '\"name\": \"db\"'"
assert_ok "runtime_get unknown returns failure" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/config.sh'; FLEET_CONFIG='$_TMP_CFG2' FLEET_CONFIG_PATH='$_TMP_CFG2'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; fleet_runtime_get nope '$_TMP_CFG2' 2>/dev/null; [ \$? -ne 0 ]"

# fleet adapters table headers and legend present
assert_output_contains "fleet adapters shows mode column" "MODE" "$FBASH" "$FLEET" adapters
assert_output_contains "fleet adapters shows legend" "Legend" "$FBASH" "$FLEET" adapters

# Probe row and footer renderers do not crash
for _a in openclaw http docker process; do
    assert_ok "probe row renders for $_a" \
        "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/output.sh'; source '$FLEET_ROOT/lib/core/adapters.sh'; fleet_adapter_load_all; _fleet_adapter_render_row '{\"name\":\"x\",\"adapter\":\"$_a\"}' '{\"status\":\"offline\",\"elapsed_ms\":1,\"verified\":false}' '$_a' 0 >/dev/null"
done
_TMP_FOOT=$(mktemp -d /tmp/fleet-test-foot.XXXXXX)
echo '{"status":"online","elapsed_ms":12,"verified":true}'  > "$_TMP_FOOT/0.json"
echo '{"status":"offline","elapsed_ms":3,"verified":true}'  > "$_TMP_FOOT/1.json"
assert_ok "probe footer renders" \
    "$FBASH" -c "FLEET_ROOT='$FLEET_ROOT'; source '$FLEET_ROOT/lib/core/adapters.sh'; _fleet_adapter_render_footer '$_TMP_FOOT' 2 | grep -q online"
rm -rf "$_TMP_FOOT"

# Non TTY output should stay machine friendly and contain no ANSI escapes
cat > "$_TMP_CFG2" <<'CFGDATA'
{"workspace":"~/workspace","agents":[],"runtimes":[{"name":"shell","adapter":"process","process":"zsh"}]}
CFGDATA
assert_ok "runtime list pipe output has no ANSI escapes" \
    "$FBASH" -c "FLEET_CONFIG='$_TMP_CFG2' '$FLEET' runtime list > /tmp/fleet-no-ansi.out; ! LC_ALL=C grep -q \\$'\\033' /tmp/fleet-no-ansi.out"

rm -f "$_TMP_CFG2"

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[ "$FAIL" -eq 0 ] || exit 1
