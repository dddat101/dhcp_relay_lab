#!/usr/bin/env bash
# Request a DHCP lease from the LAN-side namespace.

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

clear_client_address() {
    ip -n "${NS_CLIENT}" addr flush dev "${NS_CLIENT_IF}"
}

run_dhclient() {
    local leasefile="/var/lib/dhcp/dhclient-${NS_CLIENT}.leases"
    local pidfile="/run/dhclient-${NS_CLIENT}.pid"

    install -d -m 0755 /var/lib/dhcp /run
    rm -f "${leasefile}" "${pidfile}"
    : > "${leasefile}"

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

run_udhcpc() {
    local udhcpc_script="${SCRIPT_DIR}/lib/udhcpc.script"

    timeout "${DHCP_TIMEOUT_SEC}" \
        ip netns exec "${NS_CLIENT}" \
        "${UDHCPC_BIN:-udhcpc}" \
        -f \
        -q \
        -n \
        -i "${NS_CLIENT_IF}" \
        -s "${udhcpc_script}"
}

main() {
    require_root
    load_config
    require_command ip
    require_command timeout

    validate_namespace_ready "${NS_CLIENT}" "${NS_CLIENT_IF}"
    clear_client_address

    local client
    local leased_ip

    client="$(select_client)"
    log_info "Using DHCP client: ${client}"

    case "${client}" in
        dhclient) run_dhclient ;;
        udhcpc) run_udhcpc ;;
    esac

    leased_ip="$(get_client_ipv4 || true)"
    [[ -n "${leased_ip}" ]] || die "No IPv4 lease installed on client interface."

    if ! ipv4_in_range \
        "${leased_ip}" "${CLIENT_POOL_START}" "${CLIENT_POOL_END}"; then
        die "Unexpected lease ${leased_ip}; expected ${CLIENT_POOL_START}..${CLIENT_POOL_END}"
    fi

    cat >"${STATE_DIR}/client_lease.env" <<EOF
CLIENT_LEASE_IP='${leased_ip}'
EOF

    log_info "Client lease acquired: ${leased_ip}"
}

main "$@"
