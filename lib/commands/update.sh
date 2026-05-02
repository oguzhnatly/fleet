#!/bin/bash
# fleet update: Check for newer Fleet release. Installation is explicit.
# Usage: fleet update [--check] [--install] [--force] [--yes]

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
        chmod 700 "$(dirname "$FLEET_UPDATE_CACHE")" 2>/dev/null || true
        python3 - "$FLEET_UPDATE_CACHE" "$tag" "$url" "$now" <<'PY'
import json, os, sys
cache_path = sys.argv[1]
tag        = sys.argv[2]
url        = sys.argv[3]
ts         = int(sys.argv[4])
with open(cache_path, "w") as f:
    json.dump({"tag": tag, "url": url, "ts": ts}, f)
try:
    os.chmod(cache_path, 0o600)
except Exception:
    pass
PY
    fi
    printf '%s\n%s\n' "$tag" "$url"
}

cmd_update() {
    local check_only=false force=false install=false assume_yes=false allow_unverified=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check|-c)  check_only=true; shift ;;
            --install)   install=true; shift ;;
            --force|-f)  force=true; shift ;;
            --yes|-y)    assume_yes=true; shift ;;
            --allow-unverified) allow_unverified=true; shift ;;
            --help|-h)
                echo -e "  \\033[1mfleet update\\033[0m"
                cat <<'HELP'

  Usage: fleet update [--check] [--install] [--force] [--yes]

  Check the latest GitHub release. The default command only reports status.
  Installation requires --install and approval.

  Options:
    --check              Report available update without installing.
    --install            Install after confirmation.
    --force              Reinstall even when already on the latest version.
    --yes                Skip confirmation after explicit operator approval.
    --allow-unverified   Permit install when no release checksum is published.

HELP
                return 0 ;;
            *) shift ;;
        esac
    done

    echo -e "  \\033[1mfleet update\\033[0m"
    echo

    if [[ "$FLEET_UPDATE_REPO" != "oguzhnatly/fleet" && -z "${FLEET_ALLOW_CUSTOM_UPDATE_REPO:-}" ]]; then
        out_fail "Refusing update check from custom update repo: ${FLEET_UPDATE_REPO}"
        out_info "Set FLEET_ALLOW_CUSTOM_UPDATE_REPO=1 only if you intentionally trust it."
        return 1
    fi

    out_info "Current version: ${FLEET_VERSION}"
    out_info "Checking ${FLEET_UPDATE_REPO} for updates..."
    echo

    local info latest_tag tarball_url
    info=$(_update_cached_latest)
    latest_tag=$(echo "$info" | head -1)
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

    if [[ "$rel" == "older" ]]; then
        out_info "Latest release: ${latest_tag}  (you are ahead, development build)"
        if [[ "$force" == "false" ]]; then
            echo
            return 0
        fi
    fi

    if [[ "$rel" == "newer" ]]; then
        out_warn "New version available: ${latest_tag}"
    fi

    if [[ "$check_only" == "true" ]] || [[ "$install" == "false" ]]; then
        echo
        out_info "Review the release first. Install with: fleet update --install"
        echo
        return 0
    fi

    fleet_confirm_action "install ${latest_tag} from ${FLEET_UPDATE_REPO}" "This replaces the local Fleet files from a GitHub release archive." "$assume_yes" || return 1

    out_info "Installing ${latest_tag} from ${FLEET_UPDATE_REPO}..."
    echo

    local tmp_dir archive checksum_file
    tmp_dir=$(mktemp -d)
    archive="${tmp_dir}/fleet.tar.gz"
    checksum_file="${tmp_dir}/fleet.sha256"

    if ! curl -fsSL "$tarball_url" -o "$archive" 2>/dev/null; then
        out_fail "Download failed. Check your network connection."
        rm -rf "$tmp_dir"
        return 1
    fi

    local checksum_url="https://github.com/${FLEET_UPDATE_REPO}/releases/download/${latest_tag}/fleet.sha256"
    if curl -fsSL "$checksum_url" -o "$checksum_file" 2>/dev/null && [[ -s "$checksum_file" ]]; then
        local expected_hash actual_hash
        expected_hash=$(awk '{print $1}' "$checksum_file")
        actual_hash=$(python3 - "$archive" <<'PY_HASH' 2>/dev/null
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    print(hashlib.sha256(f.read()).hexdigest())
PY_HASH
)
        if [[ -z "$actual_hash" ]]; then
            out_fail "Could not compute SHA256 of downloaded archive."
            rm -rf "$tmp_dir"
            return 1
        fi
        if [[ "$actual_hash" != "$expected_hash" ]]; then
            out_fail "SHA256 mismatch. Download may be corrupted or tampered."
            rm -rf "$tmp_dir"
            return 1
        fi
        out_ok "SHA256 verified."
    elif [[ "$allow_unverified" == "true" ]]; then
        out_warn "No checksum file found. Proceeding because --allow-unverified was provided."
    else
        out_fail "No checksum file found for ${latest_tag}. Install blocked."
        out_info "Use --allow-unverified only after manually verifying the release."
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

    local install_target install_dir
    install_target=$(which fleet 2>/dev/null || echo "${HOME}/.local/bin/fleet")
    install_dir=$(dirname "$install_target")

    if [[ ! -w "$install_dir" ]]; then
        out_fail "Cannot write to ${install_dir}. Install manually from the release archive."
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
    [[ -f "$FLEET_UPDATE_CACHE" ]] && rm -f "$FLEET_UPDATE_CACHE"

    out_ok "Updated to ${latest_tag}."
    echo
    out_info "Run  fleet --version  to confirm."
    echo
}

fleet_update_banner() {
    local cache="$FLEET_UPDATE_CACHE"
    [[ -z "$FLEET_STATE_DIR" ]] && cache="${HOME}/.fleet/state/update_check.json"

    [[ ! -f "$cache" ]] && return 0

    local latest_tag
    latest_tag=$(python3 - "$cache" <<'PY'
import json, time, sys
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
        echo -e "${Y}${B}fleet ${latest_tag} is available${N}${Y}. Run  fleet update --check  to review from ${FLEET_VERSION}.${N}" >&2
        echo >&2
    fi
}
