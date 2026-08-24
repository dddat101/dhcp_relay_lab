# DHCP Relay Test Plan

## Objective

Validate that a DUT can act as a basic IPv4 DHCP Relay between a LAN-side DHCP
client and a remote DHCP server.

## Assumptions

- Relay feature has already been enabled on the DUT.
- DUT client-facing address: `DUT_LAN_IP`.
- DUT server-facing address: `DUT_WAN_IP`.
- Upstream server address: `SERVER_IP`.
- DHCP Option 82 is not a mandatory requirement for the basic test.

## Test Cases

| ID | Test | Expected Result |
|---|---|---|
| TC01 | Basic DORA through relay | Client receives lease from remote pool |
| TC02 | Verify relay `giaddr` | Server-facing request has `giaddr = DUT_LAN_IP` |
| TC03 | Verify relay `hops` | Server-facing request has expected incremented hops |
| TC04 | Verify transaction continuity | Request/reply transaction IDs correspond |
| TC05 | Detect competing local DHCP server | No unexpected second OFFER from DUT local server |
| TC06 | Multiple sequential clients | Independent transactions complete successfully |
| TC07 | Upstream server unavailable | Relay/DUT remains stable; client times out cleanly |
| TC08 | WAN link down/up | Relay recovers after server-side connectivity returns |
| TC09 | Relay restart | New DHCP transactions work after relay restart |
| TC10 | Hop-limit boundary | Excessive hop count is rejected safely |
| TC11 | Malformed DHCP request | No crash/resource leak |
| TC12 | Option 82 observation | Report presence/absence; informational only |

## TC01 Basic DORA

### Procedure

1. Start upstream DHCP server.
2. Start LAN and server-side captures.
3. Start DHCP client.
4. Wait up to `DHCP_TIMEOUT_SEC`.
5. Verify leased IPv4 address.
6. Inspect both captures.

### PASS

- Client address is inside configured remote DHCP pool.
- DISCOVER/REQUEST is visible on LAN side.
- Relayed request is visible on server side.
- OFFER/ACK is returned.

## TC02 giaddr

### PASS

Server-facing DHCP request contains:

```text
giaddr = DUT_LAN_IP
```

## TC03 hops

### PASS

For a directly attached client whose incoming request starts at zero:

```text
relay request hops = EXPECTED_RELAY_HOPS
```

Default expected value is `1`.

## TC05 Competing DHCP Server

A relay and local DHCP server active on the same client-facing broadcast domain can
produce multiple OFFERs.

### PASS

Only the intended remote server path supplies the accepted lease, and no unexpected
local DHCP OFFER is observed.

## Evidence to Record

- date/time
- DUT firmware
- DUT relay configuration
- physical interface names
- link speed/duplex
- DUT LAN/WAN addresses
- server address
- client lease
- capture file names
- DHCP XID
- `giaddr`
- `hops`
- Option 82 presence/absence
- DUT logs/counters if available
