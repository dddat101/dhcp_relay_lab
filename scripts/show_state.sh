#!/usr/bin/env bash
# Show current test state without modifying configuration.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

show_ns() {
    local ns="$1"

    printf '\n== Namespace: %s ==\n' "${ns}"
    if ! ns_exists "${ns}"; then
        printf '<not present>\n'
        return
    fi

    ip -n "${ns}" -br link
    ip -n "${ns}" -br addr
    printf -- '-- routes --\n'
    ip -n "${ns}" route || true
}

main() {
    load_config
    require_command ip

    local topo_mode="physical"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/topology_state.env"
        topo_mode="${TOPOLOGY_MODE:-physical}"
    fi

    printf '== Topology Mode ==\n'
    printf 'Mode: %s\n' "${topo_mode^^}"

    printf '\n== Host default route ==\n'
    ip route show default || true

    printf '\n== Namespaces ==\n'
    ip netns list || true

    show_ns "${NS_CLIENT}"
    if ns_exists "${NS_RELAY:-ns-relay}"; then
        show_ns "${NS_RELAY:-ns-relay}"
    fi
    show_ns "${NS_SERVER}"

    if is_pidfile_running "${STATE_DIR}/relay_agent.pid"; then
        printf '\n== Software DHCP Relay Agent (ns-relay) ==\n'
        printf 'RUNNING pid=%s\n' "$(cat "${STATE_DIR}/relay_agent.pid")"
    fi

    printf '\n== DHCP server ==\n'
    "${SCRIPT_DIR}/server.sh" status || true

    printf '\n== Capture ==\n'
    "${SCRIPT_DIR}/capture.sh" status || true

    if [[ -f "${STATE_DIR}/client_lease.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/client_lease.env"
        printf '\nClient lease: %s\n' "${CLIENT_LEASE_IP:-<none>}"
    fi

    if [[ -n "${DUT_SSH_HOST:-}" ]]; then
        printf '\n== DUT addresses ==\n'
        run_dut_cmd "${DUT_SHOW_ADDR_CMD:-ip -4 addr}" || true

        printf '\n== DUT routes ==\n'
        run_dut_cmd "${DUT_SHOW_ROUTE_CMD:-ip route}" || true

        if [[ -n "${DUT_SHOW_RELAY_CMD:-}" ]]; then
            printf '\n== DUT relay state ==\n'
            run_dut_cmd "${DUT_SHOW_RELAY_CMD}" || true
        fi
    fi
}

main "$@"
