# Native alert center (partial WebUI parity)

The SDK and Flutter workspace target stable TrueNAS 25.10 and the pinned public **TS-25.10.1** middleware source. This is not full WebUI parity or an official TrueNAS application. All implementation verification uses synthetic transports or connector-free widgets/previews. No NAS connection, supplied credential, cloud authentication or live mutation was used.

## Native scope

- Inspect up to 512 visible alert records with validated UUID, class/source identity, coded title/category/summary, severity, controller label, UTC timestamps and dismissed state.
- Show visibility doughnut, severity bars, source bars and accessible counts. Search safe titles, source labels, categories and UUIDs; filter severity, active/dismissed state and source locally.
- Inspect details without requesting a mutation review. No HTML rendering, links, scripts or raw notification content are provided.
- Explicitly review and dismiss/restore a single source-audited plain alert on an unlicensed standalone Controller A system. Exact UUID confirmation and separate impact acknowledgment are required.
- Re-read the exact target before submission and observe its requested dismissed state afterward. A `null` RPC receipt alone is insufficient.

The 15 admitted class identities are VolumeStatus, BootPoolStatus, ZpoolCapacityNotice, ZpoolCapacityWarning, ZpoolCapacityCritical, DiskTemperatureTooHot, NTPHealthCheck, CertificateIsExpiring, CertificateIsExpiringSoon, CertificateExpired, CertificateParsingFailed, SMARTUncorrectedErrors, SMARTFailedSelfTest, SMARTSpareBlockCount and SMARTEraseCycleCount. Their exact source identifiers are also checked. Each directly inherits ordinary `AlertClass` in the pinned implementation, without a custom dismiss handler or one-shot mixin.

Unknown class/source combinations, one-shot alerts and HA records are display-only. Bulk dismissal, custom dismissal handlers, one-shot removal/recovery, alert-class policies, notification service configuration/testing and live event subscriptions are not implemented here. Changes do not repair faults, stop tasks, reclaim space or prove data integrity.

## Contract and effects

| Operation | Public RPC | Interpretation |
| --- | --- | --- |
| HA admission | `failover.licensed []` | Must be the boolean `false` for mutation; licensed systems remain visible but cannot be changed. |
| Inventory and rechecks | `alert.list []` | No filter, select or pagination arguments exist. Client rejects lists larger than 512; no silent truncation. |
| Dismiss | `alert.dismiss [uuid]` | For the admitted plain classes, sets `dismissed = true` in memory and emits a changed event. |
| Restore | `alert.restore [uuid]` | Sets `dismissed = false` on an existing record and emits a changed event. |
| Verification | HA admission plus `alert.list []` | Same UUID/class/source/node/first-seen/last-occurrence/severity/one-shot state/safe observations must remain; requested dismissed state must be observed. |

Both mutation methods return `null` even when their UUID is absent. Dismissal can also invoke a `DismissableAlertClass` handler over **all related alerts of the same class and node**, or permanently remove a persistent one-shot alert. Public `one_shot == false` is therefore not sufficient proof of a safe plain alert: the exact pinned class/source allowlist is essential. No generic bulk operation is inferred from a set of UUIDs.

Dismissal normally affects filtering in alert notification services, but does not guarantee silence: other notification paths, including alert mail, have separate behavior. Restore does not guarantee immediate notification or recover an already-deleted alert. These methods initially change an in-memory flag. Alert persistence is periodic; successful readback is not proof that an immediate crash cannot lose the change.

The server's visible list excludes classes filtered by product and classes with `NEVER` notification policy. Counts mean **current visible inventory**, not all underlying problems, historical events or system health. A dismissed alert is not a resolved alert.

Primary sources:

- [Alert API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/alert.py), [alert list, serializer, dismiss/restore, persistence and notification behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/alert.py), [class identity, one-shot/custom handler bases and alert identity reuse](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/base.py).
- Admitted plain-class definitions: [pool/boot health](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/source/volume_status.py), [pool capacity](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/source/zpool_capacity.py), [disk temperature](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/source/disk_temp.py), [NTP](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/source/ntp.py), [certificates](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/source/certificates.py), [SMART diagnostics](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/alert/source/smart.py).

## Data minimization and safety

`alert.list` necessarily returns raw `args`, `text`, `formatted`, `key` and `mail` values because it has no server-side projection. The adapter immediately discards them, except narrowly allowlisted finite numeric observations for known classes (capacity percentage, disk temperature/threshold, certificate expiry days and select SMART counts). Strings from arguments never become descriptions or resource identifiers. Public snapshots and reviews contain only the validated safe projection. Unknown class/source labels use coded fallback titles; raw HTML and arbitrary messages are never rendered or returned by this workspace. Serialized transport bytes may exist transiently in memory; this is not a zeroization guarantee.

Capabilities require a current session, stable version, and explicit non-private, non-job, non-file, authenticated public metadata. Inventories and reviews are session-issued objects. Reviews expire after five minutes and are consumed once. A forged/reused review, wrong target, unsupported class, HA state, identity drift or changed last occurrence rejects before mutation. An unrelated alert arriving does not invalidate the selected UUID by itself.

The app permanently expires and hides open details/reviews after session or inventory changes, or any non-resumed application lifecycle state. Returning to the old session or resuming does not revive confirmation. An already-inactive app cannot open an alert workflow. Refresh is manual; there are no automatic event subscriptions, polls, notification tests or mutation retries.

All post-dispatch uncertainty retains the native/shared mutation fence: missing target, wrong state, identity drift, malformed/non-null receipt, timeout, disconnect, readback failure, or any RPC error including permission errno. Even event serialization can fail after the flag was changed. In-flight/unknown alert operations fence API-key, cloud-credential, SSH-credential, replication, cloud-sync, update and legacy management writes. Reloading alone does not clear uncertainty; inspect the original server and reconnect before acknowledging it. No automatic replay occurs.

TrueNAS offers no atomic compare-and-swap for these operations. Another administrator, periodic alert refresh or HA transition can race after preflight. The target proof uses safe metadata and numeric observations, not hidden argument strings. Code-generated summaries intentionally do not identify the affected resource or diagnose its exact condition; inspect the relevant subsystem in TrueNAS before acknowledging. Last occurrence changes normally as alert sources run, so a stale review can legitimately require a fresh inspection.

## Verification

- **98 SDK tests** pass with synthetic transports: exact empty-argument reads and UUID payloads, all 15 admitted class/source pairs, raw content withholding and pure safe title mapping, numeric-only projection, malformed/bounded inventory, naive-UTC/extended timestamps, unsupported/one-shot/HA admission, stale/forged/one-use reviews, mandatory post-read state, missing-target no-op detection, unknown fences and zero-frame cross-family rejection.
- **32 Flutter tests** pass with connector-free providers: manual refresh, filtering/search, chart semantics, plain/one-shot/HA controls, read-only details, exact target/impact acknowledgment, cancellation, shared locks, session/inventory/background expiry, and 320/430 logical-pixel reviews at 200% text with a 300-pixel keyboard inset.
- `AlertsPreviewAdapter` contains static safe sample metadata and rejects every mutation. No observed live-server write, notification delivery or crash-durability result is claimed.

Commands: `fvm dart test test/session/session_alerts_test.dart` from `packages/truenas_api`; `fvm flutter test test/features/alerts/alerts_test.dart` from `apps/truenavo`. Scoped SDK and Flutter analysis are clean.
