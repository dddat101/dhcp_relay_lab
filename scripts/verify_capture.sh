#!/usr/bin/env bash
# Verify relay-specific DHCP fields from latest captures.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

detect_field() {
    local candidate
    for candidate in "$@"; do
        if grep -Fxq "${candidate}" <<< "${AVAILABLE_FIELDS}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

main() {
    load_config
    require_command tshark
    require_command awk
    require_command grep

    [[ -f "${STATE_DIR}/last_capture.env" ]] ||
        die "No capture metadata found. Run capture.sh first."

    # shellcheck disable=SC1090
    source "${STATE_DIR}/last_capture.env"

    [[ -f "${LAST_LAN_PCAP:-}" ]] || die "LAN capture not found: ${LAST_LAN_PCAP:-<empty>}"
    [[ -f "${LAST_SERVER_PCAP:-}" ]] || die "Server capture not found: ${LAST_SERVER_PCAP:-<empty>}"

    # Cache available fields once to prevent SIGPIPE under set -o pipefail
    local AVAILABLE_FIELDS
    AVAILABLE_FIELDS="$(tshark -G fields 2>/dev/null | awk -F '\t' '{print $3}' || true)"

    local hops_field
    local giaddr_field
    local xid_field
    local msg_field

    hops_field="$(detect_field "dhcp.hops" "bootp.hops")" ||
        die "Unable to find DHCP hops field in this tshark version."
    giaddr_field="$(detect_field "dhcp.ip.relay" "dhcp.giaddr" "bootp.ip.relay" "bootp.giaddr")" ||
        die "Unable to find DHCP giaddr / relay IP field in this tshark version."
    xid_field="$(detect_field "dhcp.id" "bootp.id")" ||
        die "Unable to find DHCP transaction ID field."
    msg_field="$(detect_field "dhcp.type" "dhcp.option.dhcp" "bootp.option.dhcp")" ||
        die "Unable to find DHCP message-type field."

    printf '== Server-facing DHCP packets ==\n'
    tshark -r "${LAST_SERVER_PCAP}" \
        -Y 'udp.port == 67 || udp.port == 68' \
        -T fields \
        -E header=y \
        -E separator=, \
        -e frame.number \
        -e ip.src \
        -e ip.dst \
        -e udp.srcport \
        -e udp.dstport \
        -e "${xid_field}" \
        -e "${msg_field}" \
        -e "${hops_field}" \
        -e "${giaddr_field}"

    local match
    local matched_giaddr=""

    match="$(
        tshark -r "${LAST_SERVER_PCAP}" \
            -Y "(${giaddr_field} == ${DUT_LAN_IP} || ${giaddr_field} == ${DUT_LAN2_IP:-192.168.2.1}) && ${hops_field} == ${EXPECTED_RELAY_HOPS}" \
            -T fields \
            -e frame.number |
            head -n 1
    )"

    if [[ -z "${match}" ]]; then
        printf '[FAIL] No server-facing DHCP packet matched giaddr=%s (or %s) hops=%s\n' \
            "${DUT_LAN_IP}" "${DUT_LAN2_IP:-192.168.2.1}" "${EXPECTED_RELAY_HOPS}"
        exit 1
    fi

    matched_giaddr="$(
        tshark -r "${LAST_SERVER_PCAP}" \
            -Y "frame.number == ${match}" \
            -T fields \
            -e "${giaddr_field}" |
            head -n 1
    )"

    printf '[PASS] Relay packet found: frame=%s giaddr=%s hops=%s\n' \
        "${match}" "${matched_giaddr}" "${EXPECTED_RELAY_HOPS}"

    printf '\n== LAN-side DHCP packets ==\n'
    tshark -r "${LAST_LAN_PCAP}" \
        -Y 'udp.port == 67 || udp.port == 68' \
        -T fields \
        -E header=y \
        -E separator=, \
        -e frame.number \
        -e eth.src \
        -e ip.src \
        -e ip.dst \
        -e "${xid_field}" \
        -e "${msg_field}"

    printf '\n== Option 82 observation ==\n'
    if grep -Eq '^(bootp|dhcp).*option.*82' <<< "${AVAILABLE_FIELDS}"; then
        printf 'This tshark version exposes Option 82-specific fields.\n'
    else
        printf 'No stable Option 82 field name detected; inspect packet details manually if needed.\n'
    fi
}

main "$@"
