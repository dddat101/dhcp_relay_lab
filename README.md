# DHCP Relay Functional Test Lab

## Summary

This project validates a DUT acting as an IPv4 DHCP Relay between a LAN-side DHCP
client and an upstream DHCP server.

The test is intentionally limited to **basic DHCP relay behavior**:

- DHCPDISCOVER / DHCPREQUEST received on the DUT client-facing interface.
- Relay forwards the request to the configured upstream DHCP server.
- Relay increments `hops`.
- Relay sets `giaddr` to the DUT client-facing IPv4 address.
- DHCPOFFER / DHCPACK are returned through the relay to the client.
- The client receives an address from the remote-subnet pool.

DHCP Option 82 is **not required by this project**. If Option 82 is present, it is
reported by packet inspection but it is not a PASS criterion.

## Safety Principles

- Two dedicated Ethernet adapters are used.
- Host default route is never modified.
- Host firewall is never flushed or replaced.
- Physical test NICs are rejected if they carry the host default route.
- Test NICs are moved into network namespaces for isolation.
- `setup.sh` performs automatic rollback on failure.
- `cleanup.sh` is idempotent and returns physical NICs to the root namespace.

## Physical Cabling

```text
                  Ubuntu PC
       +----------------------------------+
       |                                  |
       | ns-lan1               ns-srv     |
       | DHCP Client          DHCP Server |
       |    |                     |       |
       +----|---------------------|-------+
            |                     |
       LAN_TEST_IF           SRV_TEST_IF
            |                     |
            v                     v
        DUT LAN                DUT WAN
        Relay client side      Relay server side
```

Use two dedicated Ethernet adapters.

Do not use the host management NIC for either test link.

## Logical Topology

```text
DHCP Client                                         DHCP Server
ns-lan1                                             ns-srv
DHCP address                                        172.20.0.10/24
    |                                                    ^
    | DHCPDISCOVER                                       |
    v                                                    |
DUT LAN / relay client side                        DUT WAN / relay server side
10.10.0.1/24 -------------------------------------- 172.20.0.1/24
                     DHCP Relay
```

Expected relay request:

```text
Client request:
    hops   = 0
    giaddr = 0.0.0.0

Relay -> server:
    hops   = 1
    giaddr = 10.10.0.1
```

Expected client lease:

```text
10.10.0.100 - 10.10.0.150 /24
router: 10.10.0.1
```

## Interface / IP / Namespace Table

| Role | Namespace | Interface | Address |
|---|---|---|---|
| LAN DHCP client | `ns-lan1` | `eth0` | DHCP |
| DUT relay client side | DUT | DUT LAN | `10.10.0.1/24` |
| DUT relay server side | DUT | DUT WAN | `172.20.0.1/24` |
| Upstream DHCP server | `ns-srv` | `eth0` | `172.20.0.10/24` |

## Prerequisites

Recommended Ubuntu packages:

```bash
sudo apt install iproute2 tshark tcpdump dnsmasq-base isc-dhcp-client
```

`udhcpc` may be used instead of `dhclient`.

Before setup:

```bash
cp config.env.example config.env
$EDITOR config.env
sudo ./scripts/diagnose.sh
```

Verify the two configured physical interfaces are dedicated to the test.

## Setup

### Mode 1: Physical DUT Mode (Default)
Requires two dedicated physical Ethernet adapters connected to DUT LAN and WAN.

```bash
sudo ./scripts/setup.sh
```

### Mode 2: Virtual / No-DUT Mode (Learning & Verification)
Creates an entirely self-contained 3-namespace virtual network on your PC (`ns-lan1` <-> `ns-relay` <-> `ns-srv`) with a software DHCP Relay agent simulating the DUT. **No physical NICs or DUT required.**

```bash
sudo ./scripts/setup.sh --no-dut
# or
sudo ./scripts/setup.sh --virtual
```

This:

1. creates `ns-lan1`, `ns-relay` (in virtual mode), and `ns-srv`;
2. provisions interfaces (dedicated NICs in physical mode, veth pairs in virtual mode);
3. configures server and relay IP addresses and return routes;
4. generates the upstream dnsmasq DHCP server configuration;
5. in virtual mode, automatically launches the software DHCP Relay agent (`dnsmasq --dhcp-relay`).

## DUT Configuration

Configure the DUT so that:

- DUT LAN/client-facing IP is `10.10.0.1/24`.
- DUT WAN/server-facing IP is `172.20.0.1/24`.
- DHCP server on the same client-facing interface does not compete with the relay.
- DHCP Relay is enabled.
- Relay client interface is the DUT LAN interface.
- Upstream DHCP server address is `172.20.0.10`.

The exact commands are platform-specific and intentionally not hard-coded.

If verified DUT commands are available, store them in local `config.env`:

```bash
DUT_RELAY_ENABLE_CMD='...'
DUT_RELAY_DISABLE_CMD='...'
RUN_DUT_CONFIG="1"
```

## Packet Flow

```text
1. ns-lan1 -> DUT
   DHCPDISCOVER UDP 68 -> 67, broadcast

2. DUT -> ns-srv
   Relay request UDP 67 -> 67
   giaddr = 10.10.0.1
   hops = 1

3. ns-srv -> DUT
   DHCPOFFER / DHCPACK UDP 67 -> 67

4. DUT -> ns-lan1
   DHCPOFFER / DHCPACK UDP 67 -> 68

5. ns-lan1
   installs the leased 10.10.0.x/24 address
```

## Manual Test Commands

Start DHCP server:

```bash
sudo ./scripts/server.sh start
```

Start captures:

```bash
sudo ./scripts/capture.sh start
```

Request initial lease:

```bash
sudo ./scripts/client_request.sh
```

Validate DHCP Renew (Lease Renewal):

```bash
sudo ./scripts/client_renew.sh
```

Inspect state:

```bash
sudo ./scripts/show_state.sh
```

Stop capture:

```bash
sudo ./scripts/capture.sh stop
```

Verify the latest captures (Initial Relay & Renewal):

```bash
sudo ./scripts/verify_capture.sh
sudo ./scripts/verify_renew.sh
```

## Automated Scenario

```bash
sudo ./scripts/scenario.sh
```

The scenario executes:

1. topology validation;
2. optional DUT relay enable;
3. DHCP server start;
4. packet capture start;
5. DHCP client request;
6. lease validation;
7. DHCP packet / `giaddr` / `hops` validation;
8. result summary;
9. graceful capture stop.

## PASS Criteria

Basic relay capability passes when all mandatory conditions are met:

- DHCP client obtains an address from `CLIENT_POOL_START..CLIENT_POOL_END`.
- A DHCP request is observed on the server-facing capture.
- Relay request `giaddr` equals `DUT_LAN_IP`.
- Relay request `hops` equals `EXPECTED_RELAY_HOPS`.
- DHCPOFFER or DHCPACK returns from the upstream server.
- DUT local DHCP server does not cause an unexpected competing OFFER.

Option 82 is informational only unless the test specification explicitly requires it.

## Capture / Diagnostics

Capture status:

```bash
sudo ./scripts/capture.sh status
```

Read-only diagnostics:

```bash
./scripts/diagnose.sh
```

Runtime topology:

```bash
sudo ./scripts/show_state.sh
```

Useful manual display filter:

```bash
tshark -r captures/<file>.pcapng \
  -Y 'bootp || dhcp' \
  -T fields \
  -e frame.number \
  -e ip.src \
  -e ip.dst \
  -e udp.srcport \
  -e udp.dstport \
  -e bootp.id \
  -e bootp.hops \
  -e bootp.giaddr
```

Field names differ between Wireshark versions (`bootp.*` versus `dhcp.*`).
`verify_capture.sh` detects available field names before extracting results.

## Cleanup

```bash
sudo ./scripts/cleanup.sh
```

Cleanup:

- stops DHCP client/server/capture processes;
- removes generated state;
- returns physical NICs to the root namespace;
- deletes test namespaces.

It does not change the host default route or flush the host firewall.

## Limitations

- This project validates functional relay behavior, not high-PPS performance.
- DUT configuration commands are platform-specific and are not guessed.
- Option 82 is not a mandatory criterion.
- Multiple forwarding instances, WAN failover, malformed packet handling, and
  relay hop-limit boundary testing are outside the default smoke scenario and are
  listed in `docs/TEST_PLAN.md`.
