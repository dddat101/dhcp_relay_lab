#!/usr/bin/env bash
# Read-only host diagnostics. Does not require root and changes no state.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

show_iface() {
    local iface="$1"

    printf '\n== Interface: %s ==\n' "${iface}"

    if ! iface_exists_root "${iface}"; then
        printf '<not present in root namespace>\n'
        return
    fi

    ip -br link show dev "${iface}" || true
    ip -br addr show dev "${iface}" || true

    if command -v ethtool >/dev/null 2>&1; then
        ethtool "${iface}" 2>/dev/null |
            grep -E 'Speed:|Duplex:|Link detected:' || true
    fi
}

main() {
    load_config
    require_command ip

    printf '========================================\n'
    printf ' DHCP Relay Lab Diagnostics\n'
    printf '========================================\n'

    printf '\n== Host Default Route ==\n'
    ip route show default || printf '<no default route>\n'

    show_iface "${LAN_TEST_IF}"
    show_iface "${SRV_TEST_IF}"

    printf '\n== Network Namespaces ==\n'
    ip netns list || true

    printf '\n== Required / Optional Tools ==\n'
    for cmd in ip "${DNSMASQ_BIN:-dnsmasq}" \
        "${TSHARK_BIN:-tshark}" "${TCPDUMP_BIN:-tcpdump}" \
        "${DHCLIENT_BIN:-dhclient}" "${UDHCPC_BIN:-udhcpc}"; do
        if command -v "${cmd}" >/dev/null 2>&1; then
            printf '%-12s FOUND: %s\n' "${cmd}" "$(command -v "${cmd}")"
        else
            printf '%-12s MISSING\n' "${cmd}"
        fi
    done

    printf '\n== Safety Check ==\n'
    for iface in "${LAN_TEST_IF}" "${SRV_TEST_IF}"; do
        if iface_exists_root "${iface}"; then
            if ip route show default |
                grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
                printf '%s: UNSAFE - carries default route\n' "${iface}"
            elif ip -4 addr show dev "${iface}" | grep -q 'inet '; then
                printf '%s: REVIEW - has host IPv4 configuration\n' "${iface}"
            else
                printf '%s: OK for dedicated test use\n' "${iface}"
            fi
        fi
    done
}

main "$@"
