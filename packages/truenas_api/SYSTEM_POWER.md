# Native system power: bounded TrueNAS 25.10 contract

This workspace implements explicitly reviewed immediate reboot and shutdown for a ready standalone server returning the same current and next-boot environment. It is not full WebUI power or maintenance parity. HA coordination, alternate-environment/update reboot, force, scheduling/delay, cancellation, power-on, automatic reconnect, automatic retry, job polling, service recovery checks and durable recovery records are absent.

Implementation is pinned to the public `TS-25.10.1` middleware source. Stable 25.10 plus exact authenticated public method metadata are required. All implementation tests use synthetic JSON-RPC transports: no real NAS connection, credential, probe, SSH command, reboot or shutdown was used.

## Public wire contract

| Step | Exact public method / arguments | Interpretation |
| --- | --- | --- |
| Running version | `system.version_short []` | Must equal the authenticated session's short version. |
| Persistent host identity | `system.host_id []` | Exact lowercase 64-hex SHA-256 identifier derived from nonempty `/etc/hostid` bytes. Missing/null/invalid identity blocks the workflow. It is not a cryptographic server-attestation or globally unique hardware guarantee. |
| Current boot identity | `system.reboot.info []` | Requires a canonical lowercase UUID boot ID. At most 64 unique bounded uppercase reason codes are retained; raw reason text is discarded. |
| Lifecycle readiness | `system.state []` | Only `READY` is actionable. `system.ready` is not used: its implementation also returns true while shutting down. |
| Standalone status | `failover.licensed []` | Must be literal false before action review or submission. |
| Boot-pool state | `boot.get_state []` | Healthy, ONLINE and idle known scan state. Full topology, errors and other returned details are not retained in the DTO. |
| Current/next-boot identity | `boot.environment.query [[], {"limit":129,"select":["id","dataset","created","used_bytes","active","activated","keep","can_activate"]}]` | Maximum 128 unique validated environments, all belonging to the exact observed boot pool. |
| Visible job conflicts | `core.get_jobs [[["state","in",["WAITING","RUNNING"]]], {"limit":129,"select":["id","method","state"]}]` | Maximum 128 unique validated active job headers. Any visible waiting or running job blocks power. No arguments, results, logs, progress, raw errors or credentials are requested. |
| Explicit reboot | `system.reboot [reason, {"delay":null}]` | Immediate OS reboot request. The action requires the server's FULL_ADMIN authorization. |
| Explicit shutdown | `system.shutdown [reason, {"delay":null}]` | Immediate OS shutdown request with the same authorization boundary. No app-based power-on is provided. |

Both actions are public authenticated `@job()` methods. Their eventual result schema is `None`, but the JSON-RPC server's default `legacy_jobs=True` returns the positive integer job ID directly. TrueRAID does not change that session option. Only such an ID, bounded by the exact JSON integer range, is accepted as a scheduling acknowledgement. A null, boolean, string, map, zero, negative, fractional or oversized receipt is **unknown**, not success. Even an eventual successful job cannot attest that the machine powered down or booted again.

Sources: [lifecycle method implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/system/lifecycle.py), [lifecycle argument/result models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/system_lifecycle.py), [default job mode](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/server/app.py), [job ID versus awaited result](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/server/method.py).

The audit reason is mandatory, trimmed, at most 256 characters, and excludes control/bidirectional formatting characters. It is user-visible in the review and sent unchanged to the server, where lifecycle methods record it in audit/event data. It must never contain passwords or keys. Native code never accepts shell commands, arbitrary options, a custom delay or a force flag. The server itself runs its normal OS shutdown commands; the client does not run a shell.

## Identity, readiness and one-use review

Each inventory is issued by this exact authenticated session and endpoint. The permanent host ID and boot ID are read at the start and repeated at the end of every assembled snapshot, with `system.state` also repeated. This rejects a mixed-host, mixed-boot or changed-state snapshot. Boot ID normally comes from the kernel boot UUID; a middleware fallback can generate a new UUID if that file is unavailable, which safely invalidates a prior review rather than proving a reboot occurred.

One active and one next-boot environment must exist, name the same validated current environment and report it as bootable. Different next-boot selections are blocked even for shutdown: returning from shutdown would otherwise silently boot into that alternate environment. No environment is activated or modified. Boot identity is the public name/dataset/creation tuple, not an invented GUID. The review compares all environment identities and active/next/Keep/bootability flags; changing space usage alone is not identity drift.

The scan field must be present and either literal null or a dictionary with known `NONE`, `FINISHED`, `CANCELED` or `SCANNING` state. SCANNING blocks action. A scan dictionary with null/unknown state is deliberately unavailable, even though the public loose dictionary model permits such data: it is not silently treated as idle. This conservative compatibility limit may require use of TrueNAS WebUI on some otherwise healthy appliances.

Review rereads all local safety inputs and compares exact identity and readiness. A successful review owns a five-minute lease. Execution consumes it on every attempt, including incorrect confirmation, busy state or a lost session. It requires the exact action plus full persistent host ID, and rechecks age and clock reversal both before and after all awaited preflight reads. Refresh, replacement review, forged/foreign inventory or review, changed identity, failed reads and session loss cannot submit a power call. The optional SDK clock callback is only a deterministic test seam; production defaults to `DateTime.now` with the same fixed lease duration.

Sources: [persistent host ID](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/system/info.py), [boot ID source and fallback](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/system/__init__.py), [authenticated reboot information](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/system/reboot.py), [reboot information models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/system_reboot.py), [boot environment query](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/boot_/environments.py), [boot models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/boot.py).

## Effects and recovery limitations

The checks do not prove workload quiescence, application consistency, backup freshness, encrypted-storage unlock readiness, healthy data pools or independent console access. Non-job workloads, restricted job visibility and another administrator can race after preflight. Shares, clients, applications, VMs and transfers can be interrupted. Operators must independently arrange maintenance and recovery access before confirmation. No atomic transaction or server compare-and-swap is claimed.

After any dispatched ambiguous result (including permission/error frames, timeout or disconnect), outcome is unknown. A valid job ID means accepted scheduling only. **Both accepted and unknown permanently retain the shared mutation fence in the original session**, and reject further power loads, reviews and executes without additional RPC. Pending submissions also fence other native management helpers. No completion state, polling, automatic reconnect, cancellation or replay endpoint exists.

Inspection must occur independently on the original server before the operator deliberately establishes a new connection. A new session does not prove that the old action completed; transient disconnect and elapsed time are never treated as evidence. Recovery state is in memory only and does not survive app restart. This limitation and the absence of app-based power-on are explicit review warnings.

Tests cover strict metadata and response types, bounded projected reads, boot/readiness/HA/job blockers, host and boot drift, expiry during awaited preflight, backwards clocks, session races, one-use/forged/reused reviews, exact wire arguments, malformed receipts, timeout/disconnect ambiguity, no post-submit polling/replay, shared peer mutation fences and sanitized remote errors. These tests are contract verification, not real-appliance acceptance or power/recovery certification.
