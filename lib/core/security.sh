#!/usr/bin/env bash
# fleet/lib/core/security.sh: local safety gates and secret helpers

fleet_assume_yes() {
    case "${FLEET_ASSUME_YES:-${FLEET_YES:-}}" in
        1|true|TRUE|yes|YES|y|Y|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

fleet_confirm_action() {
    local action="$1"
    local details="${2:-}"
    local assume_yes="${3:-false}"

    if [ "$assume_yes" = "true" ] || fleet_assume_yes; then
        return 0
    fi

    if [ ! -t 0 ]; then
        out_fail "Confirmation required for ${action}."
        [ -n "$details" ] && echo "       $details"
        echo "       Re-run with --yes only after explicit operator approval."
        return 1
    fi

    out_warn "Confirm ${action}"
    [ -n "$details" ] && echo "       $details"
    printf '  Continue? [y/N] '
    local answer=""
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) out_dim "Cancelled."; return 1 ;;
    esac
}

fleet_env_token() {
    local env_name="$1"
    case "$env_name" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
        [0-9]*) return 1 ;;
    esac
    printf '%s' "${!env_name:-}"
}
