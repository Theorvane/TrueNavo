# Read-only appliance validation — 2026-09-12

This is a bounded SDK/application-parser observation on one TrueNAS **25.10.1**
Community Edition server. It is **not full WebUI parity, write acceptance, or
production certification**. The user authorized reads only. No NAS configuration
or data mutation was sent, including network stage/commit/checkin/rollback,
dataset changes, service control, job cancellation, or catalog synchronization.

## Credential and transport boundary

- The user explicitly approved one observed SHA-256 certificate fingerprint for
  this test. Trust was process-local; no OS trust or application profile was changed.
- The probe verifies the exact HTTPS endpoint and certificate before any RPC
  authentication. It refuses redirects, proxies, plaintext, wrong pins, invalid
  WebSocket upgrades, and unsolicited protocol/compression extensions.
- The supplied key was entered through an echo-disabled terminal, held only in
  process memory, and never placed in source, fixtures, command arguments,
  environment files, the application vault, or the Android emulator.
- Every outgoing frame passes a tested method-and-parameter allowlist before
  reaching the socket. It cannot use the application's management gateways to
  bypass this guard. Only counts, bounded numeric diagnostics and fixed error
  categories are emitted; raw inventories, identities, device serials and
  authentication bodies are not recorded in this document or fixtures.
- A session has a 150-second outer limit, per-request deadlines, a 16 MiB message
  ceiling, a 32 MiB/100-frame cumulative inbound limit, and physical socket cleanup.
  Realtime observation takes three samples or 12 seconds and unsubscribes from
  only its own returned subscription identifier. Authentication/subscription may
  create ordinary transient session/subscription state and server audit entries.

## Final observed results

| Area | Read-only result |
|---|---|
| Authentication/discovery | Login succeeded; release 25.10.1; 768 advertised methods |
| Admin metadata | 294 compiled-policy methods present; 158 method schemas admitted by parser; no administration operation invoked |
| Dashboard | Home, storage, service and job parsers succeeded; alerts available |
| Pool capacity | All 4 returned pools supplied valid capacity chart values after the byte-total compatibility fix |
| Dataset inventory | 15 displayed records; dedicated property loader parsed 15; 7 protected records and all unverified-leaf behavior restrictions retained |
| Services/jobs | 8 service records displayed; job display bounded to 50, not asserted to be the total job count |
| Network | One interface observed; no pending changes or rollback timer; interface-specific edit restriction retained |
| History discovery | 40 graph definitions selectable; this is discovery, not verification of every instance |
| CPU history | One 15-minute query; 5 series and 900 retained real samples |
| Available-memory history | One 15-minute query; 1 series and 900 retained real samples |
| Interface history | One discovered instance; 2 series and 900 retained real samples |
| Disk history | One discovered instance; 2 series and 900 retained real samples |
| ARC-size history | One 15-minute query; 1 series and 900 retained real samples |
| Realtime | 3 samples; 5 CPU measurements, complementary memory quantities, one interface's receive/send rates and disk rates parsed |
| Completion | Zero failed stages or remote RPC errors; owned subscription closed; key not persisted |

The five history responses had no explicit null cells. This does **not** prove
uninterrupted collection: TrueNAS/Netdata may zero-fill upstream missing data.
The production DashboardRepository and dedicated SDK adapters processed these
responses. The CLI's pinned connector is test-only, so this does not establish
that every native platform bridge or graphical connected screen was exercised.

## Compatibility fixes driven by these reads

1. `pool.query` supplies integer `allocated`, `size` and `free` without percentage
   fields on this server. Use validated byte totals as a fallback, preserving
   absent/invalid values and explicit-field precedence. Labels stay compact;
   chart percentages retain their numeric precision.
2. Netdata returned 901 points for a 900-second history interval, starting one
   second before the requested boundary. Validate every row, then omit only the
   tightly bounded adjacent alignment samples outside the requested interval.
   Retained timestamps and values are unchanged. Do not reuse full-response
   aggregates after clipping. The chart explains this omission. Broad offsets,
   malformed/order errors and oversized responses remain failures.
3. `failover.licensed` was not advertised. The public `system.product_type`
   fallback admits only exact `COMMUNITY_EDITION` on every safety observation.
   Enterprise/unknown/denied results fail closed; an advertised direct HA method
   remains preferred and never falls back on errors. The existing interface
   restrictions and transaction safeguards remain intact.

See the [history contract](../../packages/truenas_api/REPORTING.md) and
[network contract and primary sources](../../packages/truenas_api/NETWORK_MANAGEMENT.md).
Network and dataset **mutation** regressions ran only against fake transports.

## Final session RPC counts

Authentication: `auth.login_ex` ×1, `auth.me` ×1, `core.get_methods` ×1.
Dashboard: `system.info` ×2, `pool.query` ×1, `alert.list` ×1,
`pool.dataset.query` ×2 (inventory and bounded property projection),
`service.query` ×1, `core.get_jobs` ×1.
Network: `system.product_type` ×1, `interface.has_pending_changes` ×2,
`interface.checkin_waiting` ×2, `interface.query` ×1,
`network.configuration.config` ×1, `interface.network_config_to_be_removed` ×1,
`interface.services_restarted_on_sync` ×1, `app.used_host_ips` ×1.
Reporting: `reporting.graphs` ×1, `reporting.get_data` ×5,
`core.subscribe` ×1, `core.unsubscribe` ×1.

Two earlier read-only sessions identified and reproduced the compatibility
failures. Their allowlists likewise emitted no configuration/data mutations.

## Reproduction and local verification

From `apps/truenavo`, in an interactive terminal:

```sh
fvm dart run tool/readonly_live_probe.dart https://NAS_ADDRESS ACCOUNT APPROVED_SHA256
```

The script asks for the key without echo. Inspect and explicitly approve the
server certificate before using this command. Do not pass the key as an argument
or save a key-bearing command, environment file, or raw RPC transcript.

- Application: **948 passed**, one pre-existing browser-only skip; analyzer clean.
- API package: **379 passed**; analyzer clean.
- Normal Android debug APK built and was installed on `emulator-5554` without
  clearing app data. `com.truenavo.truenavo/.MainActivity` was verified resumed.
  The supplied key was not entered on the emulator. Existing Gradle/AGP/Kotlin
  upcoming-support warnings remain; they did not prevent the build.
- Includes 43 outgoing-policy tests, 7 localhost TLS tests, 59 reporting SDK tests,
  56 network SDK tests, byte-capacity/label regressions, and clipping-notice UI coverage.
- Local TLS tests require `openssl`; they create one-day loopback-only certificates
  in isolated temporary directories and remove those fixtures on teardown.

No real-appliance write, HA test, credential rotation, destructive recovery,
long-running background/resume test, complete graph-instance sweep, or full
cross-platform release acceptance is claimed. Corresponding ledger rows stay
partial; `read_subset_observed_25.10.1` denotes only the read subset above.
