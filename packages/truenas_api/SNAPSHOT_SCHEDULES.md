# Native periodic snapshot schedules (TD-041)

This typed adapter implements native TrueNAS 25.10 inventory, create, edit, enable/disable, one explicit queued run, and policy deletion. Development uses public pinned source and synthetic JSON-RPC transports only. No NAS was contacted and no real snapshot or schedule was changed.

## Supported model and boundaries

`AuthenticatedSnapshotSchedulesSession` exposes inventory, review and execute methods. Public models contain selected non-secret settings, numeric task IDs, dataset GUID/type/protection metadata, a safe task-state label and the server timezone. Remote task errors, VMware/replication credentials and unrelated general settings are not retained or exposed. No next-run or exact expiry timestamp is invented.

Supported settings are dataset, recursion, exact existing descendant exclusions, all seven cron/time-window fields, positive retention, naming, enabled and allow-empty. Update sends only changed top-level fields. A changed schedule is a complete reviewed schedule object, so the server's shallow merge preserves every unselected setting. Existing unusual naming/cron metadata remains visible but is not silently rewritten.

Bounds: 128 policies, 512 dataset/choice rows, 128 datasets in an effective scope, 64 exclusions and 256 existing snapshots across old/new scopes. Over-limit or ambiguous responses block review; affected lists are never silently truncated. Pool roots, internal/system paths, unavailable choices, locked/read-only/externally managed datasets and descendants of missing/protected ancestors are protected. Recursive warnings cover current **and future** descendants; exclusions exclude entire subtrees. Patterns are not supported.

Replication-bound tasks are protected even when replication is disabled. VMware checks include recursive descendants even when excluded, matching middleware's VMware-sync calculation. Running/waiting/unknown task states need a fresh later review. Unrelated VMware tasks do not prevent unrelated policy edits.

## Calendar and retention meaning

Values are sent unchanged. Cron supports bounded numeric values, lists, ranges, and one `*/step` or `start-end/step`. Sunday is `0` or `7`; Monday–Saturday are `1`–`6`. Restricted day-of-month and weekday fields use cron OR semantics. Validation admits leap days, rejects impossible date-only combinations and requires an hour/minute match within the selected time window.

The bounded same-day window requires `begin < end`. Equal times are rejected because the pinned scheduler interprets equality as **all day**, not a one-minute window. Overnight windows are not implemented. Use `00:00`–`23:59` for full day. Scheduling uses the displayed server timezone; DST may skip or repeat local times. Client validation does not guarantee a future execution timestamp.

Naming supports safe literal characters and exactly one each of `%Y`, `%m`, `%d`, `%H`, `%M`. Retention permits 1–3650 HOUR/DAY/WEEK/MONTH/YEAR units. The source uses fixed duration: MONTH = 30 days and YEAR = 365 days, not calendar arithmetic. The adapter does not estimate retained snapshot counts or future pool capacity. TrueNAS `max_count`/`max_total_count` describe recommended snapshot counts, not maximum policy counts or a sustainability guarantee.

## Existing snapshots are not necessarily unaffected

Create can adopt existing snapshots whose dataset, naming and schedule match. Changing dataset, recursion, exclusions, naming, schedule, enabled state or lifetime can change existing retention. Overlapping policies and explicit removal-date properties also matter.

Every review lists the complete bounded snapshot-name manifest in old/new effective scopes. These are **potentially affected existing snapshots**, not a claim that every listed point will expire. Update/delete additionally call the public retention analyses. Every returned name must already be displayed in the manifest; otherwise the read is stale. The update analysis identifies snapshots leaving policy ownership, not all lifetime-shortening effects. Shortening therefore uses the full scoped manifest and an explicit danger warning: already-old matching snapshots may be destroyed on the next automatic retention pass, and restoring the old policy cannot recover them.

Delete sends `pool.snapshottask.delete(id, {fixate_removal_date:false})`. It deletes the policy record and reloads the scheduler; it does not invoke snapshot deletion. This is not a promise that existing snapshots stay unchanged forever: removing policy ownership changes later retention eligibility, potentially leaving points indefinitely or letting other policies determine expiry.

Update also explicitly sends `fixate_removal_date:false`. True fixation starts a private asynchronous snapshot-property job without returning an owned job handle or waiting for it; individual property writes can fail. This unverified workflow is not offered. The adapter does not claim preservation of old removal dates and never directly calls the private fixation method or `pool.snapshot.delete`.

## Reviews and outcomes

Inventory/review handles belong to one authenticated session. Caller settings and exclusion lists are copied before asynchronous reads. Reviews bind the bounded task configuration set, dataset identity/protection manifest, timezone, replication/VMware binding identities, scoped snapshots and server retention analyses. These are refreshed before one dispatch; task/dataset/timezone metadata is read again immediately before the request. Reviews are single-use, including incorrect confirmation or failed preflight. Fabricated/cross-session/stale handles cannot replay a write.

Create/update/delete are ordinary non-job methods. Create/update receipts must match exact proposed settings and task identity; delete must return true. Independent inventory readback verifies the expected task set and preserves unselected task settings, dataset identity and VMware flags. Volatile task-state details are not treated as immutable configuration. Verified means the policy was read back, not that a snapshot executed or future retention succeeded.

`pool.snapshottask.run(id)` queues work and returns null. Its result is **accepted**, never verified snapshot completion. A job ID or other unexpected receipt is unknown; no ownership is inferred from unrelated jobs. Inspect task/snapshot inventory to follow progress. Do not rerun the task to check it.

Mutation exclusion is shared with other native workflows. Timeout, unexpected receipt, lost session or failed post-read after dispatch leaves the outcome unknown and retains the adapter lock. No automatic retry/rollback occurs. Reconnection creates a new local session but does not prove the old remote outcome. Public multi-RPC checks cannot be atomic against scheduling, retention or external administrators.

## Remaining scope

Replication/VMware coordination, removal-date fixation, unbounded inventories, symbolic cron, overnight/equal-time windows, exact next-run/expiry simulation, policy import/export, automatic replay and snapshot restoration are not implemented here. Existing snapshot management remains separate. Operators must monitor pool capacity and retained snapshot counts.

## Primary sources

- [25.10 API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool_snapshottask.py), [CRUD, validation, VMware bindings and run](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/snapshot.py).
- [Retention analyses](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/snapshot_/task_retention.py), [private fixation job](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/snapshot_/removal_date.py), [ownership and fixed-date semantics](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/zettarepl_/snapshot_removal_date.py).
- [Duration, schedule translation and run queue](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/zettarepl.py), [cron API](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/common.py), [cron wrapper](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/cron.py).
- [Dataset choices](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/info.py), [dataset query normalization](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_query_utils.py).
- [Release dependency pin](https://github.com/truenas/scale-build/blob/TS-25.10.1/conf/build.manifest), [pinned scheduler execution](https://github.com/truenas/zettarepl/blob/bbf25266bf6ab5009b072444ebd18effeb49151a/zettarepl/scheduler/cron.py).
