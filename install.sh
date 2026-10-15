#!/usr/bin/env bash
#
# install.sh - Instala y habilita el monitor de presencia de Roblox como
#              servicio systemd, detectando automaticamente el usuario y
#              el directorio de instalacion.
#
# Uso:
#   sudo ./install.sh              # instala con valores detectados
#   sudo ./install.sh --uninstall  # elimina el servicio
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="roblox-verify"
SERVICE_TEMPLATE="${SCRIPT_DIR}/${SERVICE_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Utilidades ---------------------------------------------------------------

info()  { printf '\033[0;36m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

# --- Deteccion del usuario ----------------------------------------------------

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

    [[ -z "${user}" || "${user}" == "root" ]] && die "No se pudo detectar el usuario objetivo. Usa: SERVICE_USER=tu_usuario sudo -E ./install.sh"
    id -u "${user}" &>/dev/null || die "El usuario '${user}' no existe en el sistema."

    printf '%s' "${user}"
}

# --- Comprobaciones previas --------------------------------------------------

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Ejecuta este script como root (sudo ./install.sh)"
}

require_dependencies() {
    local missing=()
    local cmd
    for cmd in systemctl curl jq bash; do
        command -v "${cmd}" &>/dev/null || missing+=("${cmd}")
    done

    if (( ${#missing[@]} > 0 )); then
        error "Faltan dependencias: ${missing[*]}"
        warn "Instálalas con: sudo pacman -S ${missing[*]}   # Arch/CachyOS"
        exit 1
    fi
}

# --- Operaciones -------------------------------------------------------------

uninstall() {
    require_root
    info "Deshabilitando y deteniendo ${SERVICE_NAME}.service"
    systemctl --quiet disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "${SERVICE_PATH}"
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true
    info "Servicio eliminado. El script en ${SCRIPT_DIR} no se tocó."
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

    # Make sure the target user can read the script and the config.
    sudo -u "${target_user}" test -r "${SCRIPT_DIR}/roblox_verify.sh" \
        || die "User '${target_user}' cannot read ${SCRIPT_DIR}/roblox_verify.sh"

    if ! sudo -u "${target_user}" test -r "${SCRIPT_DIR}/.env"; then
        warn "Fixing permissions on ${SCRIPT_DIR}/.env"
        chmod 0644 "${SCRIPT_DIR}/.env"
    fi

    info "Usuario detectado: ${target_user}"
    info "Directorio de trabajo: ${SCRIPT_DIR}"

    local rendered
    rendered="$(mktemp)"
    sed -e "s|__USER__|${target_user}|g" \
        -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
        "${SERVICE_TEMPLATE}" > "${rendered}"

    # Valida la unidad antes de instalarla.
    if command -v systemd-analyze &>/dev/null; then
        systemd-analyze verify "${rendered}" >/dev/null 2>&1 \
            || warn "systemd-analyze reportó avisos en la unidad (revisá con: systemd-analyze verify ${rendered})"
    fi

    info "Instalando ${SERVICE_PATH}"
    install -m 0644 "${rendered}" "${SERVICE_PATH}"
    rm -f "${rendered}"

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.service"

    info "Servicio habilitado y en ejecución."
    echo
    systemctl --no-pager --lines=10 status "${SERVICE_NAME}.service" || true
    echo
    info "Comandos útiles:"
    echo "  journalctl -u ${SERVICE_NAME}.service -f     # ver logs en vivo"
    echo "  systemctl restart ${SERVICE_NAME}.service        # reiniciar"
    echo "  sudo ${SCRIPT_DIR}/install.sh --uninstall      # desinstalar"
}

main() {
    case "${1:-install}" in
        install)   install ;;
        uninstall) uninstall ;;
        -h|--help|help)
            sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//'
            ;;
        *) die "Opción desconocida: $1 (usá --help)" ;;
    esac
}

main "$@"