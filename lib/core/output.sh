#!/bin/bash
# fleet/lib/core/output.sh — Colored output, formatting, and display helpers

# ── Colors (auto-disable if not a terminal) ─────────────────────────────────
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    CLR_GREEN="\033[32m"
    CLR_RED="\033[31m"
    CLR_YELLOW="\033[33m"
    CLR_BLUE="\033[34m"
    # shellcheck disable=SC2034
    CLR_CYAN="\033[36m"
    CLR_DIM="\033[2m"
    CLR_BOLD="\033[1m"
    CLR_RESET="\033[0m"
else
    CLR_GREEN="" CLR_RED="" CLR_YELLOW="" CLR_BLUE="" CLR_CYAN=""
    CLR_DIM="" CLR_BOLD="" CLR_RESET=""
fi

# ── Output helpers ──────────────────────────────────────────────────────────
out_ok()    { echo -e "  ${CLR_GREEN}✅${CLR_RESET} $*"; }
out_fail()  { echo -e "  ${CLR_RED}❌${CLR_RESET} $*"; }
out_warn()  { echo -e "  ${CLR_YELLOW}⚠️ ${CLR_RESET} $*"; }
out_info()  { echo -e "  ${CLR_BLUE}ℹ️ ${CLR_RESET} $*"; }
out_dim()   { echo -e "  ${CLR_DIM}$*${CLR_RESET}"; }

out_header() {
    echo ""
    echo -e "${CLR_BOLD}${CLR_BLUE}$*${CLR_RESET}"
    echo -e "${CLR_DIM}$(printf '%.0s─' $(seq 1 ${#1}))${CLR_RESET}"
}

out_section() {
    echo ""
    echo -e "${CLR_BOLD}$*${CLR_RESET}"
}

out_kv() {
    local key="$1" val="$2"
    printf "  ${CLR_DIM}%-20s${CLR_RESET} %s\n" "$key" "$val"
}

# ── HTTP helpers ────────────────────────────────────────────────────────────
http_check() {
    local url="$1" timeout="${2:-5}"
    local start code elapsed

    start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" "$url" 2>/dev/null)
    local end
    end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

    elapsed=$(( (end - start) / 1000000 ))

    echo "$code $elapsed"
}

http_check_auth() {
    local url="$1" token="$2" timeout="${3:-5}"
    local start code elapsed

    start=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$timeout" \
           -H "Authorization: Bearer $token" "$url" 2>/dev/null)
    local end
    end=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

    elapsed=$(( (end - start) / 1000000 ))

    echo "$code $elapsed"
}
