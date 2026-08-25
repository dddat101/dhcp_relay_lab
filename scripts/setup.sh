#!/usr/bin/env bash
# Create isolated namespaces, assign physical or virtual veth interfaces, and provision DHCP Relay lab topology.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SETUP_ACTIVE=0

usage() {
    cat <<'EOF'
Usage:
  sudo ./scripts/setup.sh [OPTIONS]

Options:
  --no-dut, --virtual   Create a fully virtual topology on local PC (no physical DUT or NICs required).
                        Simulates the DUT DHCP Relay agent inside a virtual 'ns-relay' namespace.
                        Ideal for learning, verifying packet flows, and automated CI/testing.
  --physical            (Default) Provision physical test topology using dedicated NICs connected to DUT.
  -h, --help            Show this help message.

Environment override:
  TOPOLOGY_MODE=virtual sudo -E ./scripts/setup.sh
EOF
}

rollback_setup() {
    local exit_code="$1"
    local line_number="$2"

    if (( SETUP_ACTIVE == 0 )); then
        return
    fi

    trap - ERR
    log_error "Setup failed near line ${line_number}; rolling back partial configuration."

    "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1 || true

    log_error "Rollback complete. Original error code: ${exit_code}"
    exit "${exit_code}"
}

generate_dnsmasq_config() {
    local conf="${STATE_DIR}/dnsmasq-relay.conf"

    cat >"${conf}" <<EOF
port=0
no-resolv
no-hosts
log-dhcp
bind-interfaces
interface=${NS_SERVER_IF}
dhcp-authoritative

# ------------------------------------------------------------------------------
# Pool 1: Direct WAN Subnet (for DUT WAN DHCP client)
# ------------------------------------------------------------------------------
dhcp-range=set:wan,${WAN_POOL_START:-172.20.0.20},${WAN_POOL_END:-172.20.0.50},${WAN_NETMASK:-255.255.255.0},${DHCP_LEASE_TIME}s
dhcp-option=tag:wan,option:dns-server,${DHCP_DNS_IP}

# ------------------------------------------------------------------------------
# Pool 2: Remote LAN1 Subnet (192.168.1.0/24 via DHCP Relay giaddr 192.168.1.1)
# ------------------------------------------------------------------------------
dhcp-range=set:lan1,${CLIENT_POOL_START},${CLIENT_POOL_END},${CLIENT_NETMASK},${DHCP_LEASE_TIME}s
dhcp-option=tag:lan1,option:router,${DUT_LAN_IP}
dhcp-option=tag:lan1,option:dns-server,${DHCP_DNS_IP}

# ------------------------------------------------------------------------------
# Pool 3: Remote LAN2 Subnet (192.168.2.0/24 via DHCP Relay giaddr 192.168.2.1)
# ------------------------------------------------------------------------------
dhcp-range=set:lan2,${CLIENT2_POOL_START:-192.168.2.100},${CLIENT2_POOL_END:-192.168.2.150},${CLIENT2_NETMASK:-255.255.255.0},${DHCP_LEASE_TIME}s
dhcp-option=tag:lan2,option:router,${DUT_LAN2_IP:-192.168.2.1}
dhcp-option=tag:lan2,option:dns-server,${DHCP_DNS_IP}

dhcp-leasefile=${STATE_DIR}/dnsmasq.leases
log-facility=${STATE_DIR}/dnsmasq.log
EOF

    log_info "Generated DHCP server config (WAN, LAN1, LAN2 pools): ${conf}"
}

generate_and_start_relay_agent() {
    local relay_ns="$1"
    local conf="${STATE_DIR}/dnsmasq-relay-agent.conf"
    local pidfile="${STATE_DIR}/relay_agent.pid"
    local logfile="${STATE_DIR}/dnsmasq-relay-agent.log"
    local stdout_log="${STATE_DIR}/dnsmasq-relay-agent.stdout.log"

    stop_pidfile "${pidfile}"

    cat >"${conf}" <<EOF
port=0
no-resolv
no-hosts
bind-interfaces
interface=eth-lan
interface=eth-wan
dhcp-relay=${DUT_LAN_IP},${SERVER_IP}
log-dhcp
log-facility=${logfile}
EOF

    log_info "Generated software DHCP Relay config: ${conf}"
    log_info "Starting software DHCP Relay agent in namespace ${relay_ns}..."

    ip netns exec "${relay_ns}" \
        "${DNSMASQ_BIN:-dnsmasq}" \
        --no-daemon \
        --conf-file="${conf}" \
        >"${stdout_log}" 2>&1 &

    printf '%s\n' "$!" >"${pidfile}"
    sleep 0.3

    if ! is_pidfile_running "${pidfile}"; then
        log_error "Software DHCP Relay agent failed to start. Log output:"
        tail -n 20 "${stdout_log}" >&2 || true
        die "Failed to start relay agent in ${relay_ns}."
    fi

    log_info "Software DHCP Relay agent running (PID $(cat "${pidfile}"))."
}

setup_virtual() {
    local relay_ns="${NS_RELAY:-ns-relay}"

    log_info "=============================================================================="
    log_info " Mode: VIRTUAL / NO-DUT (Simulated Software DHCP Relay)"
    log_info "=============================================================================="
    log_info "Creating virtual network namespaces: ${NS_CLIENT}, ${relay_ns}, ${NS_SERVER}"

    ns_create "${NS_CLIENT}"
    ns_create "${NS_SERVER}"
    ns_create "${relay_ns}"

    log_info "Creating virtual ethernet (veth) pairs."
    # Clean any stale veths in root if exist
    for veth in "veth-c" "veth-s" "veth-r-lan" "veth-r-wan"; do
        if iface_exists_root "${veth}"; then
            ip link del "${veth}" 2>/dev/null || true
        fi
    done

    ip link add name "veth-c" type veth peer name "veth-r-lan"
    ip link add name "veth-s" type veth peer name "veth-r-wan"

    # Attach veths to namespaces
    ip link set dev "veth-c" netns "${NS_CLIENT}"
    ip link set dev "veth-r-lan" netns "${relay_ns}"

    ip link set dev "veth-s" netns "${NS_SERVER}"
    ip link set dev "veth-r-wan" netns "${relay_ns}"

    # Configure Client namespace
    log_info "Configuring ${NS_CLIENT}/${NS_CLIENT_IF} (Client side)."
    ip -n "${NS_CLIENT}" link set dev "veth-c" name "${NS_CLIENT_IF}"
    ip -n "${NS_CLIENT}" addr flush dev "${NS_CLIENT_IF}" 2>/dev/null || true
    ip -n "${NS_CLIENT}" link set dev "${NS_CLIENT_IF}" up

    # Configure Server namespace
    log_info "Configuring ${NS_SERVER}/${NS_SERVER_IF} with IP ${SERVER_IP}/${SERVER_PREFIX}."
    ip -n "${NS_SERVER}" link set dev "veth-s" name "${NS_SERVER_IF}"
    ip -n "${NS_SERVER}" addr flush dev "${NS_SERVER_IF}" 2>/dev/null || true
    ip -n "${NS_SERVER}" addr add "${SERVER_IP}/${SERVER_PREFIX}" dev "${NS_SERVER_IF}"
    ip -n "${NS_SERVER}" link set dev "${NS_SERVER_IF}" up
    # Add return routes for client subnets via Relay WAN
    ip -n "${NS_SERVER}" route add "${CLIENT_SUBNET}/${CLIENT_PREFIX}" via "${DUT_WAN_IP}" dev "${NS_SERVER_IF}" 2>/dev/null || true
    ip -n "${NS_SERVER}" route add "${CLIENT2_SUBNET:-192.168.2.0}/${CLIENT2_PREFIX:-24}" via "${DUT_WAN_IP}" dev "${NS_SERVER_IF}" 2>/dev/null || true

    # Configure Relay namespace (Simulated DUT)
    log_info "Configuring ${relay_ns} (Relay LAN: ${DUT_LAN_IP}/${CLIENT_PREFIX}, WAN: ${DUT_WAN_IP}/${SERVER_PREFIX})."
    ip -n "${relay_ns}" link set dev "veth-r-lan" name "eth-lan"
    ip -n "${relay_ns}" addr flush dev "eth-lan" 2>/dev/null || true
    ip -n "${relay_ns}" addr add "${DUT_LAN_IP}/${CLIENT_PREFIX}" dev "eth-lan"
    ip -n "${relay_ns}" link set dev "eth-lan" up

    ip -n "${relay_ns}" link set dev "veth-r-wan" name "eth-wan"
    ip -n "${relay_ns}" addr flush dev "eth-wan" 2>/dev/null || true
    ip -n "${relay_ns}" addr add "${DUT_WAN_IP}/${SERVER_PREFIX}" dev "eth-wan"
    ip -n "${relay_ns}" link set dev "eth-wan" up

    ip netns exec "${relay_ns}" sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    # Generate DHCP Server config
    generate_dnsmasq_config

    # Start software relay agent inside ns-relay
    generate_and_start_relay_agent "${relay_ns}"

    # Save state
    cat >"${STATE_DIR}/topology_state.env" <<EOF
TOPOLOGY_MODE='virtual'
NS_CLIENT='${NS_CLIENT}'
NS_SERVER='${NS_SERVER}'
NS_RELAY='${relay_ns}'
EOF

    validate_namespace_ready "${NS_CLIENT}" "${NS_CLIENT_IF}"
    validate_namespace_ready "${NS_SERVER}" "${NS_SERVER_IF}"
    validate_namespace_ready "${relay_ns}" "eth-lan"
    validate_namespace_ready "${relay_ns}" "eth-wan"

    log_info "Virtual topology setup completed successfully."

    printf '\n==============================================================================\n'
    printf '                 DHCP RELAY VIRTUAL TOPOLOGY READY (NO-DUT MODE)              \n'
    printf '==============================================================================\n'
    printf '  LAN Client (ns-lan1):\n'
    printf '    Namespace:        %s\n' "${NS_CLIENT}"
    printf '    Interface:        %s (veth peer connected to %s/eth-lan)\n' "${NS_CLIENT_IF}" "${relay_ns}"
    printf '    Subnet:           %s/%s (Pool: %s - %s)\n' "${CLIENT_SUBNET}" "${CLIENT_PREFIX}" "${CLIENT_POOL_START}" "${CLIENT_POOL_END}"
    printf '\n  Software DHCP Relay (ns-relay - Simulating DUT):\n'
    printf '    Namespace:        %s\n' "${relay_ns}"
    printf '    LAN Interface:    eth-lan (%s/%s)\n' "${DUT_LAN_IP}" "${CLIENT_PREFIX}"
    printf '    WAN Interface:    eth-wan (%s/%s)\n' "${DUT_WAN_IP}" "${SERVER_PREFIX}"
    printf '    Relay Status:     ACTIVE (Relaying %s -> %s)\n' "${DUT_LAN_IP}" "${SERVER_IP}"
    printf '\n  DHCP Server (ns-srv):\n'
    printf '    Namespace:        %s\n' "${NS_SERVER}"
    printf '    Interface:        %s (%s/%s)\n' "${NS_SERVER_IF}" "${SERVER_IP}" "${SERVER_PREFIX}"
    printf '\n  Recommended next commands:\n'
    printf '    sudo ./scripts/server.sh start\n'
    printf '    sudo ./scripts/capture.sh start\n'
    printf '    sudo ./scripts/client_request.sh\n'
    printf '    sudo ./scripts/verify_capture.sh\n'
    printf '    # Or run full automated scenario:\n'
    printf '    sudo ./scripts/scenario.sh\n'
    printf '==============================================================================\n'
}

setup_physical() {
    log_info "=============================================================================="
    log_info " Mode: PHYSICAL DUT (Using Dedicated Hardware NICs)"
    log_info "=============================================================================="

    validate_distinct_interfaces

    # Assert interface availability in root namespace
    iface_exists_root "${LAN_TEST_IF}" ||
        die "LAN test interface not found in root namespace: ${LAN_TEST_IF}"
    iface_exists_root "${SRV_TEST_IF}" ||
        die "Server test interface not found in root namespace: ${SRV_TEST_IF}"

    # Safety assertions
    assert_safe_test_if "${LAN_TEST_IF}"
    assert_safe_test_if "${SRV_TEST_IF}"

    log_info "LAN Client NIC:   ${LAN_TEST_IF} -> ${NS_CLIENT}/${NS_CLIENT_IF}"
    log_info "Server side NIC:  ${SRV_TEST_IF} -> ${NS_SERVER}/${NS_SERVER_IF} (${SERVER_IP}/${SERVER_PREFIX})"

    # Create network namespaces
    log_info "Creating network namespaces: ${NS_CLIENT}, ${NS_SERVER}"
    ns_create "${NS_CLIENT}"
    ns_create "${NS_SERVER}"

    # Move interfaces into namespaces
    log_info "Moving interfaces into namespaces."
    move_if_to_ns "${LAN_TEST_IF}" "${NS_CLIENT}" "${NS_CLIENT_IF}"
    move_if_to_ns "${SRV_TEST_IF}" "${NS_SERVER}" "${NS_SERVER_IF}"

    # Configure Client namespace
    log_info "Configuring ${NS_CLIENT}/${NS_CLIENT_IF}."
    ip -n "${NS_CLIENT}" addr flush dev "${NS_CLIENT_IF}" 2>/dev/null || true
    ip -n "${NS_CLIENT}" link set dev "${NS_CLIENT_IF}" up

    # Configure Server namespace
    log_info "Configuring ${NS_SERVER}/${NS_SERVER_IF} with IP ${SERVER_IP}/${SERVER_PREFIX}."
    ip -n "${NS_SERVER}" addr flush dev "${NS_SERVER_IF}" 2>/dev/null || true
    ip -n "${NS_SERVER}" addr add "${SERVER_IP}/${SERVER_PREFIX}" dev "${NS_SERVER_IF}"
    ip -n "${NS_SERVER}" link set dev "${NS_SERVER_IF}" up
    # Add return routes for client subnets via server interface
    ip -n "${NS_SERVER}" route add "${CLIENT_SUBNET}/${CLIENT_PREFIX}" dev "${NS_SERVER_IF}" 2>/dev/null || true
    ip -n "${NS_SERVER}" route add "${CLIENT2_SUBNET:-192.168.2.0}/${CLIENT2_PREFIX:-24}" dev "${NS_SERVER_IF}" 2>/dev/null || true

    # Generate DHCP server configuration
    generate_dnsmasq_config

    # Save state
    cat >"${STATE_DIR}/topology_state.env" <<EOF
TOPOLOGY_MODE='physical'
NS_CLIENT='${NS_CLIENT}'
NS_SERVER='${NS_SERVER}'
EOF

    # Validate topology readiness
    validate_namespace_ready "${NS_CLIENT}" "${NS_CLIENT_IF}"
    validate_namespace_ready "${NS_SERVER}" "${NS_SERVER_IF}"

    log_info "Physical topology setup completed successfully."

    printf '\n==============================================================================\n'
    printf '                      DHCP RELAY LAB TOPOLOGY READY (PHYSICAL)                 \n'
    printf '==============================================================================\n'
    printf '  LAN Client:\n'
    printf '    Namespace:        %s\n' "${NS_CLIENT}"
    printf '    Interface:        %s (%s -> %s)\n' "${NS_CLIENT_IF}" "${LAN_TEST_IF}" "${NS_CLIENT_IF}"
    printf '    Subnet 1:         %s/%s (Pool: %s - %s, GW: %s)\n' "${CLIENT_SUBNET}" "${CLIENT_PREFIX}" "${CLIENT_POOL_START}" "${CLIENT_POOL_END}" "${DUT_LAN_IP}"
    printf '    Subnet 2:         %s/%s (Pool: %s - %s, GW: %s)\n' "${CLIENT2_SUBNET:-192.168.2.0}" "${CLIENT2_PREFIX:-24}" "${CLIENT2_POOL_START:-192.168.2.100}" "${CLIENT2_POOL_END:-192.168.2.150}" "${DUT_LAN2_IP:-192.168.2.1}"
    printf '\n  DHCP Server:\n'
    printf '    Namespace:        %s\n' "${NS_SERVER}"
    printf '    Interface:        %s (%s -> %s)\n' "${NS_SERVER_IF}" "${SRV_TEST_IF}" "${NS_SERVER_IF}"
    printf '    Server IP:        %s/%s\n' "${SERVER_IP}" "${SERVER_PREFIX}"
    printf '    DUT WAN IP/Pool:  %s (Pool: %s - %s)\n' "${DUT_WAN_IP}" "${WAN_POOL_START:-172.20.0.20}" "${WAN_POOL_END:-172.20.0.50}"
    printf '\n  DUT Configuration Checklist:\n'
    printf '    1. Set DUT LAN IP to:          %s/%s (and/or %s/%s)\n' "${DUT_LAN_IP}" "${CLIENT_PREFIX}" "${DUT_LAN2_IP:-192.168.2.1}" "${CLIENT2_PREFIX:-24}"
    printf '    2. Set DUT WAN IP to:          DHCP (or Static %s/%s)\n' "${DUT_WAN_IP}" "${SERVER_PREFIX}"
    printf '    3. Enable DHCP Relay on DUT LAN pointing to upstream server: %s\n' "${SERVER_IP}"
    printf '\n  Recommended commands:\n'
    printf '    sudo ./scripts/server.sh start\n'
    printf '    sudo ./scripts/capture.sh start\n'
    printf '    sudo ./scripts/client_request.sh\n'
    printf '    sudo ./scripts/show_state.sh\n'
    printf '    sudo ./scripts/verify_capture.sh\n'
    printf '    # Or run full automated scenario:\n'
    printf '    sudo ./scripts/scenario.sh\n'
    printf '==============================================================================\n'
}

main() {
    local target_mode=""

    while (( $# > 0 )); do
        case "$1" in
            --no-dut|--virtual|-v)
                target_mode="virtual"
                shift
                ;;
            --physical|-p)
                target_mode="physical"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    require_root
    load_config

    # Required tools assertion
    require_command ip
    require_command "${DNSMASQ_BIN:-dnsmasq}"
    require_command awk
    require_command install
    require_command date
    require_command timeout

    if [[ -z "${target_mode}" ]]; then
        target_mode="${TOPOLOGY_MODE:-physical}"
    fi

    # Idempotent cleanup of stale resources if present
    local relay_ns="${NS_RELAY:-ns-relay}"
    if ns_exists "${NS_CLIENT}" || ns_exists "${NS_SERVER}" || ns_exists "${relay_ns}"; then
        log_info "Existing test namespaces detected; cleaning up stale resources first."
        "${SCRIPT_DIR}/cleanup.sh" >/dev/null 2>&1 || true
    fi

    # Activate rollback trap
    SETUP_ACTIVE=1
    trap 'rollback_setup $? ${LINENO}' ERR

    if [[ "${target_mode}" == "virtual" ]]; then
        setup_virtual
    else
        setup_physical
    fi

    # Disable rollback trap on success
    SETUP_ACTIVE=0
    trap - ERR
}

main "$@"
