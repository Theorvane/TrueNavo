# Native jobs and audit workspace

The stable TrueNAS 25.10 adapter exposes typed, bounded activity queries and an independently guarded cancellation workflow. This increment was implemented and validated exclusively with fake transports and widget tests; no NAS was contacted and no real write was tested.

## Jobs

- `core.get_jobs` requests 26 rows for a 25-row page, at most 40 pages, ordered by descending ID. Filters select exact method and state. Counts describe only the current page and only jobs visible to the authenticated account.
- The projection contains ID, method, state, abortability, progress percentage and start/finish timestamps. Arguments, credentials, results, error details, progress descriptions and log excerpts are excluded even if a server returns extra fields. `raw_result` is explicitly false.
- Only an issued, active, abortable job with a known start timestamp can be cancelled. The user types `job <id>`, sees the exact method and authenticated server, and is warned that cancellation does not undo completed work.
- Preflight re-reads ID/method/start time and current state. `core.job_abort` is sent once with the exact ID; `null` means the request was accepted, not necessarily that the job stopped. Independent reads then distinguish ABORTED, other terminal states and still-running work. Follow-up checks never resend cancellation.
- Missing jobs, changed identities, failed readback, timeouts and malformed receipts after dispatch produce an unknown outcome and retain the adapter lock. Pending cancellation also owns the shared app/repository mutation lock. Reconnect and inspection are required to resolve uncertainty. There is no automatic retry.
- Job IDs and creation times are checked, but the public API offers no atomic compare-and-cancel token. Concurrent other-client changes remain possible. Server-side authorization remains authoritative.
- Generic `core.job_abort` forms are disabled in favor of the typed workspace. Raw log download/streaming remains unimplemented.

## Audit

`audit.query` uses one selected database (MIDDLEWARE, SMB, SUDO or SYSTEM), local controller only, a fixed UTC interval of at most 31 days, exact optional username/result filters, and bounded pagination. A fixed upper timestamp excludes newly arriving records from later pages; retention can still remove records. No global-total or complete-history claim is made.

Only event ID, timestamp, actor, address, service, event type and success are exposed. Numeric/null audit IDs are supported without inventing stable identity. For MIDDLEWARE only, the single `event_data.method` leaf is projected as `method` and admitted only as a valid RPC identifier on METHOD_CALL events. Whole event/service data and request payloads are never requested or exposed. SQL-compatible filters and projection use `force_sql_filters:true`. Native audit export, raw event payload inspection and HA remote-controller queries remain separate work.

## Primary contracts

- [25.10 job query](https://api.truenas.com/v25.10.0/api_methods_core.get_jobs.html) and [abort](https://api.truenas.com/v25.10.0/api_methods_core.job_abort.html).
- [Pinned TS-25.10.1 core service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/core_service.py) and [job lifecycle](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/job.py). The job creation timestamp is set before WAITING, and abort schedules cancellation; it does not await terminal state.
- [25.10 audit query](https://api.truenas.com/v25.10.0/api_methods_audit.query.html) and [pinned audit implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/audit/audit.py). The latter enforces one service and a bounded query.
- [Pinned SELECT AS parsing](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/jsonpath.py) requires an alias for a nested leaf, verified by [official audit projection tests](https://github.com/truenas/middleware/blob/TS-25.10.1/tests/api2/test_audit_select_as.py).

Run `fvm dart test test/session/session_activity_test.dart` in this package and `fvm flutter test --no-pub test/features/activity` in `apps/trueraid`. The separate development preview uses `PREVIEW_ACTIVITY=true` or `PREVIEW_AUDIT=true`, displays an always-visible sample banner, and rejects every mutation without a connector.
