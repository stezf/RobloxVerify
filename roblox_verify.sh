#!/usr/bin/env bash
#
# roblox_verify.sh - Roblox presence monitor.
#
# Polls the Roblox Presence API for a configurable list of users and sends an
# ntfy.sh notification every time one of them goes online, starts playing or
# goes offline.
#
# All configuration lives in the .env file next to this script:
#   USERS=("1493909199:Name" "370166776:Name")   # <robloxUserId>:<label>
#   TOPIC="my_ntfy_topic"
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROBLOX_VERIFY_CONFIG:-${SCRIPT_DIR}/.env}"

# --- Configuration loading ----------------------------------------------------

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: config file not found: ${CONFIG_FILE}" >&2
    echo "       Copy .env.example to .env and fill in your users and topic." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# Sanity checks on the loaded configuration.
if ! declare -p USERS >/dev/null 2>&1 || [[ "${#USERS[@]}" -eq 0 ]]; then
    echo "ERROR: USERS is not set or is empty in ${CONFIG_FILE}" >&2
    exit 1
fi

if [[ -z "${TOPIC:-}" ]]; then
    echo "ERROR: TOPIC is not set in ${CONFIG_FILE}" >&2
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

# Initialise every tracked user to an "unknown" state so the first poll cycle
# does not fire a notification.
declare -A LAST_STATUSES
for entry in "${USERS[@]}"; do
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
            # Skip the very first observation of each user.
            if [[ "${last_status}" -ne -1 ]]; then
                notify "${friend_name} $(describe_status "${status}")"
            fi
            LAST_STATUSES[${user_id}]=${status}
            echo "Change detected for ${friend_name} -> status ${status}"
        fi

        # Per-user cooldown so we do not hammer the Presence API.
        sleep "${REQUEST_DELAY}"
    done

    # Global cooldown between cycles.
    sleep "${CYCLE_DELAY}"
done