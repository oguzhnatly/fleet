#!/bin/bash
# fleet update  Check for newer fleet release on GitHub and install it.
# Usage: fleet update [--check] [--force]
#
# Fetches the latest release tag from oguzhnatly/fleet on GitHub,
# compares with the installed version, and upgrades when a newer one exists.
# The version cache is refreshed every 24 hours automatically.
#
# Options:
#   --check   Only report available updates. Never install anything.
#   --force   Install the latest release even when already up to date.

FLEET_UPDATE_REPO="${FLEET_UPDATE_REPO:-oguzhnatly/fleet}"
FLEET_UPDATE_CACHE="${FLEET_STATE_DIR:-${HOME}/.fleet/state}/update_check.json"
FLEET_INSTALL_DIR="$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")"

_update_latest_version() {
    local api_url="https://api.github.com/repos/${FLEET_UPDATE_REPO}/releases/latest"
    python3 - "$api_url" <<'PY'
import urllib.request, json, sys
try:
    req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "fleet-cli/updater"})
    with urllib.request.urlopen(req, timeout=8) as r:
        data = json.loads(r.read())
    tag = data.get("tag_name", "")
    url = data.get("tarball_url", "")
    print(json.dumps({"tag": tag, "url": url}))
except Exception as e:
    print(json.dumps({"error": str(e)}))
PY
}

_update_version_compare() {
    python3 - "$1" "$2" <<'PY'
import sys
def norm(v):
    v = v.lstrip("vV")
    try:
        return tuple(int(x) for x in v.split("."))
    except Exception:
        return (0,)
a, b = norm(sys.argv[1]), norm(sys.argv[2])
print("newer" if b > a else ("same" if b == a else "older"))
PY
}

_update_cached_latest() {
    local now
    now=$(date +%s)
    if [[ -f "$FLEET_UPDATE_CACHE" ]]; then
        local cached_time tag
        cached_time=$(python3 -c "import json; d=json.load(open('$FLEET_UPDATE_CACHE')); print(d.get('ts',0))" 2>/dev/null || echo 0)
        local age=$(( now - cached_time ))
        if [[ $age -lt 86400 ]]; then
            python3 -c "import json; d=json.load(open('$FLEET_UPDATE_CACHE')); print(d.get('tag','')); print(d.get('url',''))" 2>/dev/null
            return 0
        fi
    fi
    local resp tag url
    resp=$(_update_latest_version)
    tag=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('tag',''))" "$resp" 2>/dev/null)
    url=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('url',''))" "$resp" 2>/dev/null)
    if [[ -n "$tag" && -z "$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('error',''))" "$resp" 2>/dev/null)" ]]; then
        mkdir -p "$(dirname "$FLEET_UPDATE_CACHE")"
        python3 -c "
import json
data = {'tag': '$tag', 'url': '$url', 'ts': $now}
with open('$FLEET_UPDATE_CACHE', 'w') as f:
    json.dump(data, f)
" 2>/dev/null
    fi
    printf '%s\n%s\n' "$tag" "$url"
}

cmd_update() {
    local check_only=false force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|-c)  check_only=true; shift ;;
            --force|-f)  force=true; shift ;;
            --help|-h)
                echo -e "  \\033[1mfleet update\\033[0m"
                cat <<'HELP'

  Usage: fleet update [--check] [--force]

  Check for a newer fleet release on GitHub and install it automatically.

  Options:
    --check   Only show whether an update is available. Never install.
    --force   Reinstall even when already on the latest version.

  The version check result is cached for 24 hours.

HELP
                return 0 ;;
            *) shift ;;
        esac
    done

    echo -e "  \\033[1mfleet update\\033[0m"
    echo

    out_info "Current version: ${FLEET_VERSION}"
    out_info "Checking ${FLEET_UPDATE_REPO} for updates..."
    echo

    local info
    info=$(_update_cached_latest)
    local latest_tag
    latest_tag=$(echo "$info" | head -1)
    local tarball_url
    tarball_url=$(echo "$info" | tail -1)

    if [[ -z "$latest_tag" ]]; then
        out_warn "Could not reach GitHub. Check your network connection."
        return 1
    fi

    local rel
    rel=$(_update_version_compare "$FLEET_VERSION" "$latest_tag")

    if [[ "$rel" == "same" ]] && [[ "$force" == "false" ]]; then
        out_ok "Already on the latest version (${latest_tag})."
        echo
        return 0
    fi

    if [[ "$rel" == "newer" ]]; then
        out_info "Latest release: ${latest_tag}  (you are ahead, development build)"
        if [[ "$force" == "false" ]]; then
            echo
            return 0
        fi
    fi

    if [[ "$rel" == "older" ]]; then
        out_warn "New version available: ${latest_tag}"
    fi

    if [[ "$check_only" == "true" ]]; then
        echo
        out_info "Run  fleet update  to install."
        echo
        return 0
    fi

    out_info "Installing ${latest_tag} from ${FLEET_UPDATE_REPO}..."
    echo

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local archive="${tmp_dir}/fleet.tar.gz"

    if ! curl -fsSL "$tarball_url" -o "$archive" 2>/dev/null; then
        out_fail "Download failed. Check your network connection."
        rm -rf "$tmp_dir"
        return 1
    fi

    tar -xzf "$archive" -C "$tmp_dir" 2>/dev/null
    local extracted_dir
    extracted_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)

    if [[ -z "$extracted_dir" ]]; then
        out_fail "Archive extraction failed."
        rm -rf "$tmp_dir"
        return 1
    fi

    if [[ ! -f "${extracted_dir}/bin/fleet" ]]; then
        out_fail "Unexpected archive layout. Could not find bin/fleet."
        rm -rf "$tmp_dir"
        return 1
    fi

    local install_target
    install_target=$(which fleet 2>/dev/null || echo "${HOME}/.local/bin/fleet")
    local install_dir
    install_dir=$(dirname "$install_target")

    if [[ ! -w "$install_dir" ]]; then
        out_fail "Cannot write to ${install_dir}. Try: sudo fleet update"
        rm -rf "$tmp_dir"
        return 1
    fi

    cp "${extracted_dir}/bin/fleet" "$install_target"
    chmod +x "$install_target"

    for sub in lib assets docs templates; do
        if [[ -d "${extracted_dir}/${sub}" && -d "${FLEET_INSTALL_DIR}/${sub}" ]]; then
            cp -r "${extracted_dir}/${sub}/." "${FLEET_INSTALL_DIR}/${sub}/"
        fi
    done

    rm -rf "$tmp_dir"

    python3 -c "
import json, os
cache = '$FLEET_UPDATE_CACHE'
if os.path.exists(cache):
    os.remove(cache)
" 2>/dev/null

    out_ok "Updated to ${latest_tag}."
    echo
    out_info "Run  fleet --version  to confirm."
    echo
}

# ── Version banner helper (called from bin/fleet on every invocation) ─────────
# Prints a one-line update warning when a newer release is available.
# Silent when already up to date or when GitHub is unreachable.
# The GitHub check happens at most once per 24 hours (cache-backed).
fleet_update_banner() {
    local cache="$FLEET_UPDATE_CACHE"
    [[ -z "$FLEET_STATE_DIR" ]] && cache="${HOME}/.fleet/state/update_check.json"

    if [[ ! -f "$cache" ]]; then
        return 0
    fi

    local latest_tag
    latest_tag=$(python3 -c "
import json, os, time
cache = '$cache'
try:
    d = json.load(open(cache))
    if time.time() - d.get('ts', 0) < 86400:
        print(d.get('tag', ''))
except Exception:
    pass
" 2>/dev/null)

    [[ -z "$latest_tag" ]] && return 0

    local rel
    rel=$(_update_version_compare "$FLEET_VERSION" "$latest_tag")

    if [[ "$rel" == "older" ]]; then
        local Y="\033[33m" N="\033[0m" B="\033[1m"
        echo -e "${Y}${B}fleet ${latest_tag} is available${N}${Y}. Run  fleet update  to upgrade from ${FLEET_VERSION}.${N}" >&2
        echo >&2
    fi
}
