#!/usr/bin/env bash
# Automated basic DHCP relay smoke scenario (supports physical DUT and virtual mode).

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CAPTURE_STARTED=0
SERVER_STARTED=0

finish() {
    local rc=$?

    if (( CAPTURE_STARTED == 1 )); then
        "${SCRIPT_DIR}/capture.sh" stop >/dev/null 2>&1 || true
    fi

    if (( SERVER_STARTED == 1 )); then
        "${SCRIPT_DIR}/server.sh" stop >/dev/null 2>&1 || true
    fi

    if (( rc != 0 )); then
        log_error "Scenario failed with status ${rc}."
    fi
}

main() {
    require_root
    load_config

    validate_namespace_ready "${NS_CLIENT}" "${NS_CLIENT_IF}"
    validate_namespace_ready "${NS_SERVER}" "${NS_SERVER_IF}"

    local topo_mode="physical"
    if [[ -f "${STATE_DIR}/topology_state.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/topology_state.env"
        topo_mode="${TOPOLOGY_MODE:-physical}"
    fi

    trap finish EXIT INT TERM

    printf '============================================================\n'
    printf ' DHCP RELAY FUNCTIONAL SCENARIO (%s MODE)\n' "${topo_mode^^}"
    printf '============================================================\n'

    log_info "Phase 0: relay configuration check"
    if [[ "${topo_mode}" == "virtual" ]]; then
        log_info "Virtual mode active: using software DHCP Relay in ${NS_RELAY:-ns-relay}."
        local relay_pidfile="${STATE_DIR}/relay_agent.pid"
        if ! is_pidfile_running "${relay_pidfile}"; then
            log_info "Starting software DHCP Relay agent..."
            local relay_conf="${STATE_DIR}/dnsmasq-relay-agent.conf"
            ip netns exec "${NS_RELAY:-ns-relay}" \
                "${DNSMASQ_BIN:-dnsmasq}" \
                --no-daemon \
                --conf-file="${relay_conf}" \
                >"${STATE_DIR}/dnsmasq-relay-agent.stdout.log" 2>&1 &
            printf '%s\n' "$!" > "${relay_pidfile}"
            sleep 0.3
        fi
    elif [[ "${RUN_DUT_CONFIG:-0}" == "1" ]]; then
        [[ -n "${DUT_RELAY_ENABLE_CMD:-}" ]] ||
            die "RUN_DUT_CONFIG=1 but DUT_RELAY_ENABLE_CMD is empty."
        run_dut_cmd "${DUT_RELAY_ENABLE_CMD}"
    else
        log_info "Physical DUT mode: DUT configuration is manual."
    fi

    log_info "Phase 1: start upstream DHCP server"
    "${SCRIPT_DIR}/server.sh" start
    SERVER_STARTED=1

    if [[ "${START_CAPTURE_AUTOMATICALLY:-1}" == "1" ]]; then
        log_info "Phase 2: start packet captures"
        "${SCRIPT_DIR}/capture.sh" start
        CAPTURE_STARTED=1
        sleep 1
    fi

    log_info "Phase 3: request DHCP lease"
    "${SCRIPT_DIR}/client_request.sh"

    local lease
    lease="$(get_client_ipv4 || true)"
    [[ -n "${lease}" ]] || die "Client has no IPv4 lease."
    ipv4_in_range "${lease}" "${CLIENT_POOL_START}" "${CLIENT_POOL_END}" ||
        die "Lease ${lease} is outside configured pool."

    log_info "Phase 4: stop capture before analysis"
    if (( CAPTURE_STARTED == 1 )); then
        sleep 1
        "${SCRIPT_DIR}/capture.sh" stop
        CAPTURE_STARTED=0
    fi

    log_info "Phase 5: verify packet evidence"
    if [[ "${START_CAPTURE_AUTOMATICALLY:-1}" == "1" ]]; then
        "${SCRIPT_DIR}/verify_capture.sh"
    else
        log_warn "Automatic capture disabled; packet verification skipped."
    fi

    cat >"${STATE_DIR}/scenario_result.txt" <<EOF
DHCP Relay Functional Scenario: PASS
Topology Mode: ${topo_mode}
Client lease: ${lease}
Expected relay giaddr: ${DUT_LAN_IP}
Expected relay hops: ${EXPECTED_RELAY_HOPS}
Option 82: informational only
EOF

    printf '\n============================================================\n'
    printf ' SCENARIO RESULT: PASS\n'
    printf ' Mode:                  %s\n' "${topo_mode^^}"
    printf ' Client lease:          %s\n' "${lease}"
    printf ' Expected relay giaddr: %s\n' "${DUT_LAN_IP}"
    printf ' Expected relay hops:   %s\n' "${EXPECTED_RELAY_HOPS}"
    printf '============================================================\n'
}

main "$@"
