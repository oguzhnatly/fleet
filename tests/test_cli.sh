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

# each built-in adapter must define the full five-function contract
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
echo "Results: $PASS passed, $FAIL failed"
echo ""

[ "$FAIL" -eq 0 ] || exit 1
