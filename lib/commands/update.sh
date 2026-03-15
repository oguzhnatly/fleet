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
    # Pass cache path as argument to avoid shell interpolation inside Python source
    if [[ -f "$FLEET_UPDATE_CACHE" ]]; then
        local cached_time
        cached_time=$(python3 - "$FLEET_UPDATE_CACHE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get("ts", 0))
except Exception:
    print(0)
PY
)
        local age=$(( now - cached_time ))
        if [[ $age -lt 86400 ]]; then
            python3 - "$FLEET_UPDATE_CACHE" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    print(d.get("tag", ""))
    print(d.get("url", ""))
except Exception:
    pass
PY
            return 0
        fi
    fi
    local resp tag url
    resp=$(_update_latest_version)
    tag=$(python3 - "$resp" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("tag", ""))
except Exception:
    print("")
PY
)
    url=$(python3 - "$resp" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("url", ""))
except Exception:
    print("")
PY
)
    local has_error
    has_error=$(python3 - "$resp" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("error", ""))
except Exception:
    print("parse_error")
PY
)
    if [[ -n "$tag" && -z "$has_error" ]]; then
        mkdir -p "$(dirname "$FLEET_UPDATE_CACHE")"
        # Write cache safely: pass tag, url, ts as argv to avoid injection from network values
        python3 - "$FLEET_UPDATE_CACHE" "$tag" "$url" "$now" <<'PY'
import json, sys
cache_path = sys.argv[1]
tag        = sys.argv[2]
url        = sys.argv[3]
ts         = int(sys.argv[4])
with open(cache_path, "w") as f:
    json.dump({"tag": tag, "url": url, "ts": ts}, f)
PY
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
    local checksum_file="${tmp_dir}/fleet.sha256"

    # Fetch tarball
    if ! curl -fsSL "$tarball_url" -o "$archive" 2>/dev/null; then
        out_fail "Download failed. Check your network connection."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Fetch checksum file published alongside the release (fleet.sha256)
    local checksum_url="https://github.com/${FLEET_UPDATE_REPO}/releases/download/${latest_tag}/fleet.sha256"
    if curl -fsSL "$checksum_url" -o "$checksum_file" 2>/dev/null && [[ -s "$checksum_file" ]]; then
        local expected_hash actual_hash
        expected_hash=$(awk '{print $1}' "$checksum_file")
        actual_hash=$(python3 -c "
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
" "$archive" 2>/dev/null)
        if [[ -z "$actual_hash" ]]; then
            out_fail "Could not compute SHA256 of downloaded archive."
            rm -rf "$tmp_dir"
            return 1
        fi
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            out_fail "SHA256 mismatch. Download may be corrupted or tampered."
            out_fail "  expected: ${expected_hash}"
            out_fail "  actual:   ${actual_hash}"
            rm -rf "$tmp_dir"
            return 1
        fi
        out_ok "SHA256 verified: ${actual_hash:0:16}..."
    else
        out_warn "No checksum file found for ${latest_tag}. Proceeding without verification."
        out_warn "To verify manually: sha256sum ${archive}"
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

    # Remove stale cache so next invocation re-fetches
    [[ -f "$FLEET_UPDATE_CACHE" ]] && rm -f "$FLEET_UPDATE_CACHE"

    out_ok "Updated to ${latest_tag}."
    echo
    out_info "Run  fleet --version  to confirm."
    echo
}

# ── Version banner helper (called from bin/fleet on every invocation) ─────────
# Prints a one-line update warning when a newer release is available.
# Silent when already up to date or when GitHub is unreachable.
fleet_update_banner() {
    local cache="$FLEET_UPDATE_CACHE"
    [[ -z "$FLEET_STATE_DIR" ]] && cache="${HOME}/.fleet/state/update_check.json"

    [[ ! -f "$cache" ]] && return 0

    # Pass cache path as argument to avoid interpolating it into Python source
    local latest_tag
    latest_tag=$(python3 - "$cache" <<'PY'
import json, os, time, sys
cache = sys.argv[1]
try:
    with open(cache) as f:
        d = json.load(f)
    if time.time() - d.get("ts", 0) < 86400:
        print(d.get("tag", ""))
except Exception:
    pass
PY
)

    [[ -z "$latest_tag" ]] && return 0

    local rel
    rel=$(_update_version_compare "$FLEET_VERSION" "$latest_tag")

    if [[ "$rel" == "older" ]]; then
        local Y="\033[33m" N="\033[0m" B="\033[1m"
        echo -e "${Y}${B}fleet ${latest_tag} is available${N}${Y}. Run  fleet update  to upgrade from ${FLEET_VERSION}.${N}" >&2
        echo >&2
    fi
}
