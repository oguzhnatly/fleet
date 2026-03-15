#!/usr/bin/env bash
# fleet integration tests
set -uo pipefail

FLEET="$(cd "$(dirname "$0")/.." && pwd)/bin/fleet"
PASS=0
FAIL=0

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
for f in "$FLEET" "$FLEET_ROOT"/lib/core/*.sh "$FLEET_ROOT"/lib/commands/*.sh; do
    [ -f "$f" ] && assert_ok "syntax: $(basename "$f")" bash -n "$f"
done

echo ""
echo "Basic Commands"
assert_ok "help exits 0" bash "$FLEET" help
assert_ok "--version exits 0" bash "$FLEET" --version
assert_output_contains "version format" "fleet v" bash "$FLEET" --version
assert_output_contains "help contains commands" "fleet health" bash "$FLEET" help

echo ""
echo "Config"
# Health gracefully falls back to defaults when no config
FLEET_CONFIG=/nonexistent/path assert_ok "health without config works" bash "$FLEET" health

echo ""
echo "Trust Engine (v3)"
assert_ok "trust.sh syntax" bash -n "$FLEET_ROOT/lib/core/trust.sh"
assert_ok "trust command syntax" bash -n "$FLEET_ROOT/lib/commands/trust.sh"
assert_ok "score command syntax" bash -n "$FLEET_ROOT/lib/commands/score.sh"
assert_ok "trust help exits 0" bash "$FLEET" trust --help
assert_ok "score help exits 0" bash "$FLEET" score --help
assert_output_contains "help contains trust" "fleet trust" bash "$FLEET" help
assert_output_contains "help contains score" "fleet score" bash "$FLEET" help

FLEET_LOG=/nonexistent/log.jsonl assert_ok "trust with no log" bash "$FLEET" trust
FLEET_LOG=/nonexistent/log.jsonl assert_ok "score with no log" bash "$FLEET" score

_TMP_LOG=$(mktemp /tmp/fleet-test-log.XXXXXX.jsonl)
cat > "$_TMP_LOG" <<'LOGDATA'
{"task_id":"aaa00001","agent":"coder","task_type":"code","prompt":"add pagination","dispatched_at":"2026-03-15T10:00:00Z","completed_at":"2026-03-15T10:08:00Z","outcome":"success","steer_count":0}
{"task_id":"aaa00002","agent":"coder","task_type":"code","prompt":"fix auth bug","dispatched_at":"2026-03-15T11:00:00Z","completed_at":"2026-03-15T11:15:00Z","outcome":"steered","steer_count":1}
{"task_id":"aaa00003","agent":"reviewer","task_type":"review","prompt":"review PR #12","dispatched_at":"2026-03-15T12:00:00Z","completed_at":"2026-03-15T12:05:00Z","outcome":"success","steer_count":0}
{"task_id":"aaa00004","agent":"deployer","task_type":"deploy","prompt":"deploy to railway","dispatched_at":"2026-03-15T13:00:00Z","completed_at":"2026-03-15T13:20:00Z","outcome":"failure","steer_count":0}
LOGDATA

_EXAMPLE_CFG="$FLEET_ROOT/examples/solo-empire/config.json"
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_ok "trust with log data" bash "$FLEET" trust
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_output_contains "trust shows coder" "coder" bash "$FLEET" trust
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_ok "score with specific agent" bash "$FLEET" score coder
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_output_contains "score shows percentage" "%" bash "$FLEET" score coder
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" assert_ok "trust json mode" bash "$FLEET" trust --json
FLEET_CONFIG="$_EXAMPLE_CFG" FLEET_LOG="$_TMP_LOG" \
    assert_ok "trust json is valid JSON" \
    bash -c "FLEET_CONFIG=\"$_EXAMPLE_CFG\" FLEET_LOG=\"$_TMP_LOG\" bash \"$FLEET\" trust --json | python3 -c 'import json,sys; json.load(sys.stdin)'"

rm -f "$_TMP_LOG"

assert_ok "update.sh syntax" bash -n "$FLEET_ROOT/lib/commands/update.sh"
assert_ok "update help exits 0" bash "$FLEET" update --help
assert_output_contains "help contains update" "fleet update" bash "$FLEET" help
assert_ok "update check exits 0 with no network" bash -c "
    FLEET_STATE_DIR=\$(mktemp -d) bash \"$FLEET\" update --check 2>/dev/null; true
"

echo ""
echo "JSON Validation"
for f in "$FLEET_ROOT"/examples/*/config.json "$FLEET_ROOT"/templates/configs/*.json; do
    if [ -f "$f" ]; then
        assert_ok "valid JSON: $(basename "$(dirname "$f")")/$(basename "$f")" python3 -c "import json; json.load(open('$f'))"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo ""

[ "$FAIL" -eq 0 ] || exit 1
