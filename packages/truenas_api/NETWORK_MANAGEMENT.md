# Native interface transactions

This first network workflow targets stable TrueNAS 25.10: an existing standalone,
non-HA physical interface's description, IPv4 DHCP or one to eight static aliases,
and automatic/1280–9000 MTU. It does not implement bridge/bond/VLAN creation,
membership, configured IPv6, HA, DNS/gateway changes, service-listener migration,
application host-IP migration, or management endpoint reconnection.

## Contract and safety

`AuthenticatedNetworkSession` exposes inventory, begin test, inspect status, keep,
and revert. It exposes neither arbitrary RPC nor `interface.cancel_rollback`.
The connection must advertise every required safety method. Inventory identities
and transaction handles are tied to the exact live authenticated SDK session.

The HA proof normally uses `failover.licensed`. If that method is not advertised,
an advertised `system.product_type` may substitute only when it returns exactly
`COMMUNITY_EDITION`. The tagged 25.10.1 implementation classifies all HA-capable
hardware as `ENTERPRISE` before considering a license, so Community Edition
provides a conservative standalone proof. The adapter rereads this proof on
every observation, including before staging, commit, keep, and revert. Enterprise,
unknown or malformed results, timeouts, and denied reads fail closed. An advertised
`failover.licensed` always takes precedence: its errors or positive HA result
never trigger the fallback. The private `system.is_enterprise` and
`system.is_ha_capable` methods are not called.

Before staging, reread all interface configuration (excluding runtime state),
global network configuration, HA status, pending flag and rollback timer. Refuse
existing pending changes, including staged changes without a timer. Every other
interface's configuration is part of the before/after comparison. App-bound
removed addresses are refused. Inputs are immutable, bounded, and validated;
IPv6 aliases are never silently dropped. Pure reads do not initiate changes.
Alias order is normalized for comparison; runtime interface/global `state` is
excluded, while all persisted fields remain part of the comparison. Tagged
25.10.1 implementation returns `app.used_host_ips` as IP → application names,
despite the generated description saying the reverse; the guard covers both.

The only update payload is `[id, {description, ipv4_dhcp, aliases, mtu}]`.
After staging, recheck the exact expected configuration and refuse commit if the
server identifies gateway/DNS removal or service-listener reconfiguration.
Otherwise send `interface.commit([{rollback: true, checkin_timeout: 60}])` once.
The SDK lock spans preflight, staging, test, and uncertain outcomes and blocks the
older management and generic administration gateways. Requests are never retried.

Only an explicit user Keep sends `interface.checkin`; only explicit Revert sends
`interface.rollback`. Both require the exact SDK-issued handle and unchanged
global configuration. A committed test must still have a positive server timer
within the local monotonic 60-second window. Before commit, an explicitly requested
rollback can recover this client's verified staged changes without a timer.
No local timer expiration is taken as proof of rollback. Keep and revert are
reported complete only after rereading the expected/original configuration with
no pending changes and no timer. Lost responses, remote errors after staging, and
ownership mismatches remain unknown with the lock retained. Closing a session
does not send rollback or checkin.

TrueNAS has a server-global network snapshot and timer, **not an ownership token
or atomic compare-and-swap**. Do not edit networking concurrently from another
client. Configuration checks reduce but cannot eliminate inter-client races.
Keep requires the operator to verify intended connectivity; successful RPC alone
does not certify every service, interface, or client. Ensure console/recovery
access before testing. Staging failure may precede timer creation, so automatic
rollback must never be promised for an unknown result.

## Primary references

- [25.10 interface.update](https://api.truenas.com/v25.10/api_methods_interface.update.html)
- [25.10 interface.commit](https://api.truenas.com/v25.10/api_methods_interface.commit.html)
- [25.10 interface.checkin](https://api.truenas.com/v25.10/api_methods_interface.checkin.html)
- [25.10 interface.checkin_waiting](https://api.truenas.com/v25.10/api_methods_interface.checkin_waiting.html)
- [25.10 app.used_host_ips](https://api.truenas.com/v25.10/api_methods_app.used_host_ips.html)
- [25.10 system.product_type](https://api.truenas.com/v25.10/api_methods_system.product_type.html)
- [Tagged product classification and private helpers](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/system/product.py#L41-L76)
- [Tagged TS-25.10.1 network implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/network.py)
- [Tagged application IP map implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/apps/resources.py)

Contract tests use fake JSON-RPC transport only. No real NAS configuration has
been changed or certified by these tests.

Compatibility evidence: a read-only observation of TrueNAS 25.10.1 reported
`failover.licensed` absent from method metadata while the other required methods
were advertised. A subsequent guarded read-only probe observed exact Community
Edition proof and parsed the interface inventory, retaining interface edit
restrictions. The fallback's mutation safeguards are verified only by fake
transport tests; no live network transaction was attempted. See
[read-only scope and counts](../../docs/planning/READONLY_LIVE_VALIDATION.md).

Verification: 56 native network fake-wire tests pass. Focused network analysis
has no issues. Test coverage
includes foreign pending/stale config, topology/HA/IPv6 restrictions, DHCP/static
payloads, review bounds, app/listener impacts, unknown stage/keep failures,
positive/zero/expired timers, explicit keep/revert, forged handles, disconnect,
and shared operation locks in both directions.
