#!/usr/bin/env bash
#
# Roblox presence monitor: polls the Roblox API for a list of users and
# notifies via ntfy.sh when one goes online, starts playing or disconnects.
#
# Config: environment variables first, then the gitignored .env:
#   USERS=("149390999:Name" "37016676:Name")   # <robloxUserId>:<label>
#   TOPIC="my_ntfy_topic"
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROBLOX_VERIFY_CONFIG:-${SCRIPT_DIR}/.env}"

# --- Config ------------------------------------------------------------------

# Imports a "declare -p" assignment unless that variable is already set in the
# environment, so the environment always wins over .env.
apply_if_unset() {
    local declaration="$1" name

    [[ "${declaration}" =~ ^declare[[:space:]]+-[a-zA-Z-]*[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]] || return 0
    name="${BASH_REMATCH[1]}"

    [[ -n "${!name+defined}" ]] && return 0

    eval "${declaration/#declare /declare -g }" 2>/dev/null || true
}

load_config() {
    local declarations

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "WARNING: config file not found: ${CONFIG_FILE}" >&2
        echo "         Relying on environment variables only." >&2
        return 0
    fi

    # env -i drops inherited names (PAM exports USERS), and sourcing in a
    # subshell lets us keep only the variables the file actually defines.
    declarations="$(env -i bash -c '
        before=" $(compgen -v) "
        source "$1" || exit 1
        for name in $(compgen -v); do
            case "${before}" in *" ${name} "*) continue ;; esac
            declare -p "${name}" 2>/dev/null || true
        done
    ' _ "${CONFIG_FILE}" 2>/dev/null)" || {
        echo "ERROR: could not parse ${CONFIG_FILE}" >&2
        exit 1
    }

    local line
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        apply_if_unset "${line}"
    done <<< "${declarations}"
}

load_config

# Environment variables cannot hold arrays, so USERS may arrive comma-separated.
if ! declare -p USERS 2>/dev/null | grep -q '^declare -a'; then
    users_value="${USERS_STR:-${USERS:-}}"
    declare -g -a USERS=()
    if [[ -n "${users_value}" ]]; then
        IFS=',' read -r -a USERS <<< "${users_value}"
    fi
    unset users_value
fi

# Sanity checks on the loaded configuration.
if ! declare -p USERS >/dev/null 2>&1 || [[ "${#USERS[@]}" -eq 0 ]]; then
    echo "ERROR: USERS is not set or is empty (set it in ${CONFIG_FILE})" >&2
    exit 1
fi

if [[ -z "${TOPIC:-}" ]]; then
    echo "ERROR: TOPIC is not set (set it in ${CONFIG_FILE})" >&2
    exit 1
fi

for cmd in curl jq; do
    command -v "${cmd}" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: ${cmd}" >&2
        exit 1
    }
done

# --- Timings ------------------------------------------------------------------

REQUEST_DELAY="${REQUEST_DELAY:-3}"   # Seconds between single-user requests
CYCLE_DELAY="${CYCLE_DELAY:-35}"      # Seconds between full polling cycles

# Roblox presence types
readonly STATUS_OFFLINE=0
readonly STATUS_ONLINE=1
readonly STATUS_IN_GAME=2

# --- Helpers ------------------------------------------------------------------

notify() {
    curl -s -d "$1" "ntfy.sh/${TOPIC}" >/dev/null
}

describe_status() {
    case "$1" in
        "${STATUS_ONLINE}")  echo "is online (Web/App)" ;;
        "${STATUS_IN_GAME}") echo "started playing" ;;
        *)                   echo "went offline" ;;
    esac
}

# --- State --------------------------------------------------------------------

declare -A LAST_STATUSES
for entry in "${USERS[@]}"; do
    # -1 means "unknown", so the first poll only records a baseline.
    LAST_STATUSES["${entry%%:*}"]=-1
done

echo "Monitor started: tracking ${#USERS[@]} user(s), topic '${TOPIC}'."

# --- Main loop ----------------------------------------------------------------

while true; do
    for entry in "${USERS[@]}"; do
        user_id="${entry%%:*}"
        friend_name="${entry#*:}"

        response=$(curl -s -X POST "https://presence.roblox.com/v1/presence/users" \
            -H "Content-Type: application/json" \
            -d "{\"userIds\": [${user_id}]}")

        status=$(echo "${response}" | jq '.userPresences[0].userPresenceType // 0')
        last_status="${LAST_STATUSES[${user_id}]}"

        if [[ "${status}" -ne "${last_status}" ]]; then
            if [[ "${last_status}" -ne -1 ]]; then   # skip the first observation
                notify "${friend_name} $(describe_status "${status}")"
            fi
            LAST_STATUSES[${user_id}]=${status}
            echo "Change detected for ${friend_name} -> status ${status}"
        fi

        sleep "${REQUEST_DELAY}"   # per-user cooldown
    done

    sleep "${CYCLE_DELAY}"      # cooldown between cycles
done