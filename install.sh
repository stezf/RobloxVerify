#!/usr/bin/env bash
#
# install.sh - Installs the Roblox monitor as a systemd service, detecting the
# target user and the install directory automatically.
#
# Usage:
#   sudo ./install.sh              # install with detected values
#   sudo ./install.sh --uninstall  # remove the service
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="roblox-verify"
SERVICE_TEMPLATE="${SCRIPT_DIR}/${SERVICE_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Helpers -----------------------------------------------------------------

info()  { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

detect_user() {
    local user=""
    if [[ -n "${SUDO_USER:-}" ]]; then
        user="${SUDO_USER}"
    elif [[ -n "${PKEXEC_UID:-}" ]]; then
        user="$(getent passwd "${PKEXEC_UID}" | cut -d: -f1)"
    elif [[ -n "${USER:-}" && "${USER}" != "root" ]]; then
        user="${USER}"
    else
        user="$(logname 2>/dev/null || true)"
    fi

    [[ -z "${user}" || "${user}" == "root" ]] && die "Could not detect the target user. Use: SERVICE_USER=your_user sudo -E ./install.sh"
    id -u "${user}" &>/dev/null || die "User '${user}' does not exist."

    printf '%s' "${user}"
}

# --- Checks ------------------------------------------------------------------

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run this script as root (sudo ./install.sh)"
}

require_dependencies() {
    local missing=()
    local cmd
    for cmd in systemctl curl jq bash; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done

    if (( ${#missing[@]} > 0 )); then
        error "Missing dependencies: ${missing[*]}"
        warn "Install them with: sudo pacman -S ${missing[*]}   # Arch/CachyOS"
        exit 1
    fi
}

# --- Operations ----------------------------------------------------------------

uninstall() {
    require_root
    info "Disabling and stopping ${SERVICE_NAME}.service"
    systemctl --quiet disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${SERVICE_PATH}"
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
    info "Service removed. The script in ${SCRIPT_DIR} was left untouched."
}

install() {
    require_root
    require_dependencies

    local target_user="${SERVICE_USER:-$(detect_user)}"
    [[ -f "${SERVICE_TEMPLATE}" ]] || die "Service template not found: ${SERVICE_TEMPLATE}"

    # The monitor reads its configuration from .env next to the script.
    if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
        die "Missing ${SCRIPT_DIR}/.env - copy .env.example to .env and set USERS and TOPIC first"
    fi

    sudo -u "${target_user}" test -r "${SCRIPT_DIR}/roblox_verify.sh" \
        || die "User '${target_user}' cannot read ${SCRIPT_DIR}/roblox_verify.sh"

    # The config must stay private to the service user.
    if ! sudo -u "${target_user}" test -r "${SCRIPT_DIR}/.env"; then
        warn "Restricting permissions on ${SCRIPT_DIR}/.env"
        chown "${target_user}" "${SCRIPT_DIR}/.env"
        chmod 0600 "${SCRIPT_DIR}/.env"
    fi

    # .env holds the Roblox IDs and the ntfy topic, so it must never be committed.
    if git -C "${SCRIPT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
        if git -C "${SCRIPT_DIR}" ls-files --error-unmatch .env >/dev/null 2>&1; then
            die ".env is tracked by git! Run: git rm --cached .env"
        fi
        if ! git -C "${SCRIPT_DIR}" check-ignore -q .env; then
            warn ".env is not covered by .gitignore - it could be committed by accident."
        fi
    fi

    info "Detected user: ${target_user}"
    info "Working directory: ${SCRIPT_DIR}"

    local rendered
    rendered="$(mktemp)"
    sed -e "s|__USER__|${target_user}|g" \
        -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
        "${SERVICE_TEMPLATE}" > "${rendered}"

    # Validate the unit before installing it.
    if command -v systemd-analyze &>/dev/null; then
        systemd-analyze verify "${rendered}" >/dev/null 2>&1 \
            || warn "systemd-analyze reported warnings (see: systemd-analyze verify ${SERVICE_PATH})"
    fi

    info "Installing ${SERVICE_PATH}"
    install -m 0644 "${rendered}" "${SERVICE_PATH}"
    rm -f "${rendered}"

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.service"

    info "Service enabled and running."
    echo
    systemctl --no-pager --lines=10 status "${SERVICE_NAME}.service" || true
    echo
    info "Useful commands:"
    echo "  journalctl -u ${SERVICE_NAME}.service -f     # follow logs"
    echo "  systemctl restart ${SERVICE_NAME}.service        # restart"
    echo "  sudo ${SCRIPT_DIR}/install.sh --uninstall      # remove"
}

main() {
    case "${1:-install}" in
        install)   install ;;
        uninstall) uninstall ;;
        -h|--help|help)
            # Print the header comment block, minus the leading "#".
            awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
            ;;
        *) die "Unknown option: $1 (use --help)" ;;
    esac
}

main "$@"