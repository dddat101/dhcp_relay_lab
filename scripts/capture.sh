#!/usr/bin/env bash
# Capture manager for LAN-side and server-side DHCP traffic.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    printf 'Usage: %s start|stop|status\n' "$(basename "$0")"
}

start_capture() {
    require_root

    validate_namespace_ready "${NS_CLIENT}" "${NS_CLIENT_IF}"
    validate_namespace_ready "${NS_SERVER}" "${NS_SERVER_IF}"

    stop_capture

    local timestamp
    local ext="pcap"
    local cap_tool="tcpdump"
    local client_file
    local server_file
    local client_log
    local server_log
    local client_pid
    local server_pid

    if command -v "${TCPDUMP_BIN:-tcpdump}" >/dev/null 2>&1; then
        cap_tool="tcpdump"
        ext="pcap"
    elif command -v "${TSHARK_BIN:-tshark}" >/dev/null 2>&1; then
        cap_tool="tshark"
        ext="pcapng"
    else
        die "Neither tcpdump (${TCPDUMP_BIN:-tcpdump}) nor tshark (${TSHARK_BIN:-tshark}) is installed."
    fi

    timestamp="$(date +%Y%m%d_%H%M%S)"
    client_file="${CAPTURE_DIR}/dhcp_relay_lan_${timestamp}.${ext}"
    server_file="${CAPTURE_DIR}/dhcp_relay_server_${timestamp}.${ext}"
    client_log="${STATE_DIR}/cap_client.log"
    server_log="${STATE_DIR}/cap_server.log"

    if [[ "${cap_tool}" == "tcpdump" ]]; then
        nohup ip netns exec "${NS_CLIENT}" "${TCPDUMP_BIN:-tcpdump}" \
            -ni "${NS_CLIENT_IF}" -s 0 -U -w "${client_file}" \
            "${CAPTURE_FILTER}" \
            > "${client_log}" 2>&1 &
        client_pid="$!"
        printf '%s\n' "${client_pid}" > "${STATE_DIR}/cap_client.pid"

        nohup ip netns exec "${NS_SERVER}" "${TCPDUMP_BIN:-tcpdump}" \
            -ni "${NS_SERVER_IF}" -s 0 -U -w "${server_file}" \
            "${CAPTURE_FILTER}" \
            > "${server_log}" 2>&1 &
        server_pid="$!"
        printf '%s\n' "${server_pid}" > "${STATE_DIR}/cap_server.pid"
    else
        nohup ip netns exec "${NS_CLIENT}" "${TSHARK_BIN:-tshark}" \
            -i "${NS_CLIENT_IF}" -f "${CAPTURE_FILTER}" -l \
            -w "${client_file}" \
            > "${client_log}" 2>&1 &
        client_pid="$!"
        printf '%s\n' "${client_pid}" > "${STATE_DIR}/cap_client.pid"

        nohup ip netns exec "${NS_SERVER}" "${TSHARK_BIN:-tshark}" \
            -i "${NS_SERVER_IF}" -f "${CAPTURE_FILTER}" -l \
            -w "${server_file}" \
            > "${server_log}" 2>&1 &
        server_pid="$!"
        printf '%s\n' "${server_pid}" > "${STATE_DIR}/cap_server.pid"
    fi

    # Verify processes stayed alive
    sleep 0.5

    if ! is_pidfile_running "${STATE_DIR}/cap_client.pid"; then
        log_error "LAN capture failed to start. Log output:"
        tail -n 20 "${client_log}" >&2 || true
        stop_capture
        die "Failed to start capture on ${NS_CLIENT}/${NS_CLIENT_IF}."
    fi

    if ! is_pidfile_running "${STATE_DIR}/cap_server.pid"; then
        log_error "Server capture failed to start. Log output:"
        tail -n 20 "${server_log}" >&2 || true
        stop_capture
        die "Failed to start capture on ${NS_SERVER}/${NS_SERVER_IF}."
    fi

    cat >"${STATE_DIR}/last_capture.env" <<EOF
LAST_LAN_PCAP='${client_file}'
LAST_SERVER_PCAP='${server_file}'
EOF

    log_info "Captures started (${cap_tool}):"
    log_info "  LAN capture:    ${client_file} (PID ${client_pid})"
    log_info "  Server capture: ${server_file} (PID ${server_pid})"
}

stop_capture() {
    require_root
    stop_pidfile "${STATE_DIR}/cap_client.pid"
    stop_pidfile "${STATE_DIR}/cap_server.pid"
    log_info "Captures stopped."
}

show_status() {
    printf '== Capture Status ==\n'
    if is_pidfile_running "${STATE_DIR}/cap_client.pid"; then
        printf 'LAN capture:    RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/cap_client.pid")"
    else
        printf 'LAN capture:    STOPPED\n'
    fi

    if is_pidfile_running "${STATE_DIR}/cap_server.pid"; then
        printf 'Server capture: RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/cap_server.pid")"
    else
        printf 'Server capture: STOPPED\n'
    fi

    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        printf '\nLatest Capture Files:\n'
        printf '  LAN:    %s\n' "${LAST_LAN_PCAP:-<none>}"
        printf '  SERVER: %s\n' "${LAST_SERVER_PCAP:-<none>}"
    fi
}

main() {
    load_config

    case "${1:-}" in
        start) start_capture ;;
        stop)  stop_capture ;;
        status) show_status ;;
        *)     usage; exit 2 ;;
    esac
}

main "$@"
