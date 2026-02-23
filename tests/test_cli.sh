#!/bin/bash
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
