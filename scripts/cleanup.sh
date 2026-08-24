#!/usr/bin/env bash
# Idempotent cleanup for DHCP relay functional lab (physical or virtual mode).

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main() {
    require_root
    load_config

    stop_pidfile "${STATE_DIR}/cap_client.pid"
    stop_pidfile "${STATE_DIR}/cap_server.pid"
    stop_pidfile "${STATE_DIR}/dnsmasq.pid"
    stop_pidfile "${STATE_DIR}/relay_agent.pid"
    stop_pidfile "${STATE_DIR}/dhclient.pid"
    stop_pidfile "${STATE_DIR}/udhcpc.pid"

    local topo_mode="physical"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/topology_state.env"
        topo_mode="${TOPOLOGY_MODE:-physical}"
    fi

    local relay_ns="${NS_RELAY:-ns-relay}"
    if ns_exists "${relay_ns}"; then
        ip netns del "${relay_ns}" || true
    fi

    if [[ "${topo_mode}" == "physical" ]]; then
        if ns_exists "${NS_CLIENT}"; then
            restore_if_from_ns "${NS_CLIENT}" "${NS_CLIENT_IF}" "${LAN_TEST_IF}"
        fi

        if ns_exists "${NS_SERVER}"; then
            restore_if_from_ns "${NS_SERVER}" "${NS_SERVER_IF}" "${SRV_TEST_IF}"
        fi
    fi

    if ns_exists "${NS_CLIENT}"; then
        ip netns del "${NS_CLIENT}" || true
    fi

    if ns_exists "${NS_SERVER}"; then
        ip netns del "${NS_SERVER}" || true
    fi

    # Clean any orphan veth interfaces in root namespace
    for veth in "veth-c" "veth-s" "veth-r-lan" "veth-r-wan"; do
        if iface_exists_root "${veth}"; then
            ip link del "${veth}" 2>/dev/null || true
        fi
    done

    if [[ "${topo_mode}" == "physical" ]]; then
        if iface_exists_root "${LAN_TEST_IF}"; then
            ip addr flush dev "${LAN_TEST_IF}" 2>/dev/null || true
            ip link set dev "${LAN_TEST_IF}" down 2>/dev/null || true
        fi

        if iface_exists_root "${SRV_TEST_IF}"; then
            ip addr flush dev "${SRV_TEST_IF}" 2>/dev/null || true
            ip link set dev "${SRV_TEST_IF}" down 2>/dev/null || true
        fi
    fi

    rm -f \
        "${STATE_DIR}/dnsmasq-relay.conf" \
        "${STATE_DIR}/dnsmasq-relay-agent.conf" \
        "${STATE_DIR}/dnsmasq.leases" \
        "${STATE_DIR}/dnsmasq.log" \
        "${STATE_DIR}/dnsmasq.stdout.log" \
        "${STATE_DIR}/dnsmasq-relay-agent.log" \
        "${STATE_DIR}/dnsmasq-relay-agent.stdout.log" \
        "${STATE_DIR}/dnsmasq.pid.internal" \
        "${STATE_DIR}/last_capture.env" \
        "${STATE_DIR}/client_lease.env" \
        "${STATE_DIR}/scenario_result.txt" \
        "${STATE_DIR}/topology_state.env"

    log_info "Cleanup completed successfully."

    if [[ "${topo_mode}" == "physical" ]]; then
        printf '\nHost interface status (in root namespace):\n'
        if iface_exists_root "${LAN_TEST_IF}"; then
            printf '  %s: ' "${LAN_TEST_IF}"; ip -br link show dev "${LAN_TEST_IF}"
        else
            printf '  %s: <not detected in root netns>\n' "${LAN_TEST_IF}"
        fi

        if iface_exists_root "${SRV_TEST_IF}"; then
            printf '  %s: ' "${SRV_TEST_IF}"; ip -br link show dev "${SRV_TEST_IF}"
        else
            printf '  %s: <not detected in root netns>\n' "${SRV_TEST_IF}"
        fi

        printf '\nNote: Test interfaces are kept DOWN to prevent unmanaged traffic.\n'
        printf '      Use "ifconfig -a" or "ip link" to view all interfaces (including DOWN).\n'
    fi
}

main "$@"
