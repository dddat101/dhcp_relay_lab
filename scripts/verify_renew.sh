#!/usr/bin/env bash
# Verify DHCP lease renewal packets (DHCPREQUEST & DHCPACK) from latest captures.

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

    local AVAILABLE_FIELDS
    AVAILABLE_FIELDS="$(tshark -G fields 2>/dev/null | awk -F '\t' '{print $3}' || true)"

    local hops_field giaddr_field xid_field msg_field ciaddr_field yiaddr_field

    hops_field="$(detect_field "dhcp.hops" "bootp.hops")" || die "Missing hops field"
    giaddr_field="$(detect_field "dhcp.ip.relay" "dhcp.giaddr" "bootp.ip.relay" "bootp.giaddr")" || die "Missing giaddr field"
    xid_field="$(detect_field "dhcp.id" "bootp.id")" || die "Missing xid field"
    msg_field="$(detect_field "dhcp.type" "dhcp.option.dhcp" "bootp.option.dhcp")" || die "Missing msg type field"
    ciaddr_field="$(detect_field "dhcp.ip.client" "bootp.ip.client" "dhcp.ciaddr" "bootp.ciaddr")" || die "Missing ciaddr field"
    yiaddr_field="$(detect_field "dhcp.ip.your" "bootp.ip.your" "dhcp.yiaddr" "bootp.yiaddr")" || die "Missing yiaddr field"

    printf '============================================================\n'
    printf '              DHCP RENEW PACKET VERIFICATION\n'
    printf '============================================================\n'

    printf '\n== LAN-side DHCP Packets (ns-lan1) ==\n'
    tshark -r "${LAST_LAN_PCAP}" \
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
        -e "${ciaddr_field}" \
        -e "${yiaddr_field}"

    printf '\n== Server-side DHCP Packets (ns-srv) ==\n'
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
        -e "${ciaddr_field}" \
        -e "${yiaddr_field}"

    # Check for Renew request (type 3) and ACK (type 5)
    local req_match ack_match
    req_match="$(
        tshark -r "${LAST_SERVER_PCAP}" \
            -Y "${msg_field} == 3" \
            -T fields \
            -e frame.number |
            tail -n 1
    )"

    ack_match="$(
        tshark -r "${LAST_SERVER_PCAP}" \
            -Y "${msg_field} == 5" \
            -T fields \
            -e frame.number |
            tail -n 1
    )"

    if [[ -n "${req_match}" && -n "${ack_match}" ]]; then
        printf '\n[PASS] DHCP Renew exchange verified: Request Frame %s -> ACK Frame %s\n' \
            "${req_match}" "${ack_match}"
    else
        printf '\n[WARN] Renew exchange (Request type 3 -> ACK type 5) not found in latest capture.\n'
        printf '       To validate Renew, run:\n'
        printf '         sudo ./scripts/capture.sh start\n'
        printf '         sudo ./scripts/client_renew.sh\n'
        printf '         sleep 1\n'
        printf '         sudo ./scripts/capture.sh stop\n'
        printf '         sudo ./scripts/verify_renew.sh\n'
    fi
}

main "$@"
