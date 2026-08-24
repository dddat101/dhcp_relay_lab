#!/usr/bin/env bash
# Upstream DHCP server manager.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    printf 'Usage: %s start|stop|status\n' "$(basename "$0")"
}

start_server() {
    require_root
    require_command "${DNSMASQ_BIN:-dnsmasq}"
    validate_namespace_ready "${NS_SERVER}" "${NS_SERVER_IF}"

    stop_server

    local conf="${STATE_DIR}/dnsmasq-relay.conf"
    local pidfile="${STATE_DIR}/dnsmasq.pid"

    [[ -f "${conf}" ]] || die "Missing ${conf}. Run setup.sh first."

    ip netns exec "${NS_SERVER}" \
        "${DNSMASQ_BIN:-dnsmasq}" \
        --no-daemon \
        --conf-file="${conf}" \
        >"${STATE_DIR}/dnsmasq.stdout.log" 2>&1 &

    printf '%s\n' "$!" >"${pidfile}"
    sleep 0.3

    if ! is_pidfile_running "${pidfile}"; then
        tail -n 50 "${STATE_DIR}/dnsmasq.stdout.log" >&2 || true
        die "dnsmasq failed to start."
    fi

    log_info "DHCP server started (PID $(cat "${pidfile}"))."
}

stop_server() {
    require_root
    stop_pidfile "${STATE_DIR}/dnsmasq.pid"
}

show_status() {
    if is_pidfile_running "${STATE_DIR}/dnsmasq.pid"; then
        printf 'RUNNING pid=%s\n' "$(cat "${STATE_DIR}/dnsmasq.pid")"
    else
        printf 'STOPPED\n'
    fi
}

main() {
    load_config

    case "${1:-}" in
        start) start_server ;;
        stop) require_root; stop_server; log_info "DHCP server stopped." ;;
        status) show_status ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
