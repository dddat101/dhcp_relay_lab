#!/usr/bin/env bash
# Common helpers for the DHCP relay functional lab.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
readonly CONFIG_FILE="${PROJECT_ROOT}/config.env"
readonly LOG_TAG="DHCP-RELAY-LAB"

log_info()  { printf '[INFO] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }

require_root() {
    if (( EUID != 0 )); then
        die "Run this command with sudo/root privileges."
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        die "Required command is not installed: ${cmd}"
    fi
}

load_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        die "Missing ${CONFIG_FILE}. Copy config.env.example to config.env first."
    fi

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    : "${LAN_TEST_IF:?LAN_TEST_IF is required}"
    : "${SRV_TEST_IF:?SRV_TEST_IF is required}"
    : "${NS_CLIENT:?NS_CLIENT is required}"
    : "${NS_SERVER:?NS_SERVER is required}"
    : "${NS_CLIENT_IF:?NS_CLIENT_IF is required}"
    : "${NS_SERVER_IF:?NS_SERVER_IF is required}"
    : "${SERVER_IP:?SERVER_IP is required}"
    : "${SERVER_PREFIX:?SERVER_PREFIX is required}"
    : "${DUT_LAN_IP:?DUT_LAN_IP is required}"
    : "${CLIENT_POOL_START:?CLIENT_POOL_START is required}"
    : "${CLIENT_POOL_END:?CLIENT_POOL_END is required}"
    : "${CLIENT_NETMASK:?CLIENT_NETMASK is required}"
    : "${CAPTURE_DIR:?CAPTURE_DIR is required}"
    : "${STATE_DIR:?STATE_DIR is required}"

    if [[ "${CAPTURE_DIR}" != /* ]]; then
        CAPTURE_DIR="${PROJECT_ROOT}/${CAPTURE_DIR}"
    fi
    if [[ "${STATE_DIR}" != /* ]]; then
        STATE_DIR="${PROJECT_ROOT}/${STATE_DIR}"
    fi

    ensure_runtime_dirs
}

ensure_runtime_dirs() {
    install -d -m 0755 "${CAPTURE_DIR}" "${STATE_DIR}"
}

iface_exists_root() {
    local iface="$1"
    ip link show dev "${iface}" >/dev/null 2>&1
}

iface_exists_ns() {
    local ns="$1"
    local iface="$2"
    ip netns exec "${ns}" ip link show dev "${iface}" >/dev/null 2>&1
}

ns_exists() {
    local ns="$1"
    ip netns list | awk '{print $1}' | grep -Fxq "${ns}"
}

assert_safe_test_if() {
    local iface="$1"

    [[ -n "${iface}" ]] || die "Empty interface name."
    [[ "${iface}" != "lo" ]] || die "Refusing to use loopback interface."

    if ip route show default 2>/dev/null |
        grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        die "Interface ${iface} carries the host default route."
    fi

    if ip -4 addr show dev "${iface}" 2>/dev/null | grep -q 'inet '; then
        die "Interface ${iface} already has an IPv4 address."
    fi
}

validate_distinct_interfaces() {
    if [[ "${LAN_TEST_IF}" == "${SRV_TEST_IF}" ]]; then
        die "LAN_TEST_IF and SRV_TEST_IF must be different physical interfaces."
    fi
}

ns_create() {
    local ns="$1"

    if ! ns_exists "${ns}"; then
        ip netns add "${ns}"
    fi

    ip -n "${ns}" link set lo up
}

move_if_to_ns() {
    local iface="$1"
    local ns="$2"
    local new_name="$3"

    if iface_exists_ns "${ns}" "${new_name}"; then
        return 0
    fi

    if ! iface_exists_root "${iface}"; then
        die "Interface not found in root namespace: ${iface}"
    fi

    ip link set dev "${iface}" down
    ip link set dev "${iface}" netns "${ns}"
    ip -n "${ns}" link set dev "${iface}" name "${new_name}"
}

restore_if_from_ns() {
    local ns="$1"
    local ns_if="$2"
    local root_name="$3"

    if ! iface_exists_ns "${ns}" "${ns_if}"; then
        return 0
    fi

    ip -n "${ns}" link set dev "${ns_if}" down || true
    ip -n "${ns}" link set dev "${ns_if}" name "${root_name}" || true
    ip netns exec "${ns}" ip link set dev "${root_name}" netns 1 || true
}

validate_namespace_ready() {
    local ns="$1"
    local iface="$2"

    ns_exists "${ns}" || die "Namespace does not exist: ${ns}"
    iface_exists_ns "${ns}" "${iface}" ||
        die "Interface ${iface} is missing in namespace ${ns}."
}

is_pidfile_running() {
    local pidfile="$1"
    local pid

    [[ -f "${pidfile}" ]] || return 1

    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1

    kill -0 "${pid}" 2>/dev/null
}

stop_pidfile() {
    local pidfile="$1"
    local pid
    local attempt

    [[ -f "${pidfile}" ]] || return 0

    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
        kill -INT "${pid}" 2>/dev/null || true

        for attempt in {1..20}; do
            if ! kill -0 "${pid}" 2>/dev/null; then
                break
            fi
            sleep 0.1
        done

        if kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
            sleep 0.2
        fi

        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    fi

    rm -f "${pidfile}"
}

run_dut_cmd() {
    local cmd="$1"

    if [[ -z "${DUT_SSH_HOST:-}" || -z "${cmd}" ]]; then
        return 0
    fi

    require_command ssh
    # shellcheck disable=SC2086
    ssh ${DUT_SSH_OPTS:-} \
        "${DUT_SSH_USER:-root}@${DUT_SSH_HOST}" \
        "${cmd}"
}

ipv4_to_int() {
    local ip="$1"
    local a b c d

    IFS=. read -r a b c d <<<"${ip}"
    printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

ipv4_in_range() {
    local ip="$1"
    local first="$2"
    local last="$3"
    local x lo hi

    x="$(ipv4_to_int "${ip}")"
    lo="$(ipv4_to_int "${first}")"
    hi="$(ipv4_to_int "${last}")"

    (( x >= lo && x <= hi ))
}

get_client_ipv4() {
    ip -n "${NS_CLIENT}" -4 -o addr show dev "${NS_CLIENT_IF}" scope global |
        awk '{split($4,a,"/"); print a[1]; exit}'
}
