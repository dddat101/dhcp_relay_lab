#!/usr/bin/env bash
# Trigger a DHCP lease renewal from the LAN client without resetting the interface.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

select_client() {
    case "${DHCP_CLIENT:-auto}" in
        dhclient)
            command -v "${DHCLIENT_BIN:-dhclient}" >/dev/null 2>&1 ||
                die "dhclient requested but not installed."
            printf 'dhclient\n'
            ;;
        udhcpc)
            command -v "${UDHCPC_BIN:-udhcpc}" >/dev/null 2>&1 ||
                die "udhcpc requested but not installed."
            printf 'udhcpc\n'
            ;;
        auto)
            if command -v "${DHCLIENT_BIN:-dhclient}" >/dev/null 2>&1; then
                printf 'dhclient\n'
            elif command -v "${UDHCPC_BIN:-udhcpc}" >/dev/null 2>&1; then
                printf 'udhcpc\n'
            else
                die "No supported DHCP client found (dhclient or udhcpc)."
            fi
            ;;
        *)
            die "Unsupported DHCP_CLIENT=${DHCP_CLIENT}"
            ;;
    esac
}

renew_dhclient() {
    local leasefile="/var/lib/dhcp/dhclient-${NS_CLIENT}.leases"
    local pidfile="/run/dhclient-${NS_CLIENT}.pid"

    log_info "Triggering DHCP renewal via dhclient..."

    timeout "${DHCP_TIMEOUT_SEC}" \
        ip netns exec "${NS_CLIENT}" \
        "${DHCLIENT_BIN:-dhclient}" \
        -4 \
        -1 \
        -v \
        -lf "${leasefile}" \
        -pf "${pidfile}" \
        "${NS_CLIENT_IF}"
}

renew_udhcpc() {
    local udhcpc_script="${SCRIPT_DIR}/lib/udhcpc.script"
    local pidfile="/run/udhcpc-${NS_CLIENT}.pid"

    log_info "Triggering DHCP renewal via udhcpc..."

    if [[ -f "${pidfile}" ]] && kill -0 "$(cat "${pidfile}" 2>/dev/null)" 2>/dev/null; then
        local pid
        pid="$(cat "${pidfile}")"
        log_info "Sending SIGUSR1 to running udhcpc (PID ${pid})..."
        kill -USR1 "${pid}"
        sleep 1
    else
        timeout "${DHCP_TIMEOUT_SEC}" \
            ip netns exec "${NS_CLIENT}" \
            "${UDHCPC_BIN:-udhcpc}" \
            -f \
            -q \
            -n \
            -i "${NS_CLIENT_IF}" \
            -s "${udhcpc_script}"
    fi
}

main() {
    require_root
    load_config
    require_command ip
    require_command timeout

    validate_namespace_ready "${NS_CLIENT}" "${NS_CLIENT_IF}"

    local initial_ip
    initial_ip="$(get_client_ipv4 || true)"
    [[ -n "${initial_ip}" ]] || die "Client has no active IPv4 address. Run client_request.sh first."

    log_info "Current active client IP before renew: ${initial_ip}"

    local client
    client="$(select_client)"
    log_info "Using DHCP client for renewal: ${client}"

    case "${client}" in
        dhclient) renew_dhclient ;;
        udhcpc) renew_udhcpc ;;
    esac

    local renewed_ip
    renewed_ip="$(get_client_ipv4 || true)"
    [[ -n "${renewed_ip}" ]] || die "Client lost IPv4 address after renew attempt."

    if [[ "${renewed_ip}" != "${initial_ip}" ]]; then
        log_warn "Lease IP changed from ${initial_ip} to ${renewed_ip}."
    else
        log_info "Lease IP successfully maintained: ${renewed_ip}"
    fi

    cat >"${STATE_DIR}/client_renew.env" <<EOF
INITIAL_LEASE_IP='${initial_ip}'
RENEWED_LEASE_IP='${renewed_ip}'
RENEW_TIMESTAMP='$(date +%Y%m%d_%H%M%S)'
EOF

    log_info "DHCP Renew completed successfully."
}

main "$@"
