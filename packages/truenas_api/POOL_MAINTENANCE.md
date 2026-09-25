# Native pool maintenance — bounded TS-25.10.1 contract

TD-024 is partial: pool/scan inventory, manual scrub START/STOP, one scrub schedule per pool with create/update/delete/enable/disable. Pool creation, topology changes, attach/replace/offline, expansion, feature upgrades, export/destruction and encryption are not authorized by this workspace. No real NAS connection, supplied credential, remote SSH session or live mutation was used. Verification uses synthetic transports and connector-free Flutter fixtures only.

## Pinned public sources

- [Pool schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool.py) and [pool extension](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/pool.py): pool ID/name/GUID, ONLINE/health/warning, scan/expansion and capacity. Offline pools have null scan/capacity. The app does not request topology, paths, raw status descriptions or encryption data.
- [Scrub schema](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool_scrub.py) and [scrub implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/scrub.py): public `pool.scrub.scrub(name, action)` is a non-transient job with START/STOP/PAUSE. This workspace uses START/STOP only. Schedule CRUD is non-job and restarts cron after datastore persistence.
- [Pool wrapper](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/pool_operations.py): `pool.scrub(id, action)` is a **transient** wrapper around the named scrub job. The workspace deliberately owns the public non-transient child job directly, after verifying ID/GUID/name. It never guesses a child ID or infers authority from a job description.
- [ZFS scrub action](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/zfs_/pool_actions.py): START invokes `start_scrub`, STOP invokes `stop_scrub`; PAUSE invokes a separate shell path and is not exposed here. START can read and repair corruption using available ZFS redundancy and can create substantial disk load.
- [Pinned py-libzfs scan representation](https://github.com/truenas/py-libzfs/blob/TS-25.10.1/libzfs.pyx): ZPoolScrub uses NONE/SCRUB/RESILVER functions and NONE/SCANNING/FINISHED/CANCELED states. Start/end/pause are UTC datetimes; `pause` is **not a boolean**. It is null unless actively paused. The bytes_to_process/bytes_processed names in this version map to counter properties in an unintuitive order, so the native workspace does not use them to derive progress. Percentage is reported directly, not recomputed.
- [Cron model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/common.py): five string fields minute/hour/dom/month/dow; no snapshot-style begin/end window. The native validator accepts a bounded numeric subset, with calendar validation, not arbitrary raw cron text.

## Reads and bounded public models

| Read | Exact parameters |
| --- | --- |
| Pools | `pool.query [[], {limit:65,select:[id,name,guid,status,healthy,warning,scan,expand,size,allocated,free]}]` |
| Scrub schedules | `pool.scrub.query [[], {limit:65,select:[id,pool,pool_name,threshold,description,schedule,enabled]}]` |
| Timezone | `system.general.config []`; retain only a validated timezone token, discard all other fields. |
| HA gate | `failover.licensed []`; a non-boolean is not interpreted as false. |
| Active job headers | `core.get_jobs [[[state,in,[WAITING,RUNNING]]],{limit:129,select:[id,method,state]}]` |
| Scrub-only job details | For headers whose exact method is `pool.scrub` or `pool.scrub.scrub`, query both ID and method with `limit:2`, selecting id/method/state/arguments only. No arguments of arbitrary jobs are requested. |

The limit is 64 pools/schedules and 128 visible jobs. Missing required fields, malformed identifiers/types/UTC dates, invalid cron, duplicate pool IDs/names/GUIDs, duplicate schedule/pool bindings, duplicate job IDs and inconsistent pool references fail closed. Unknown/unhealthy/offline pools remain read-only. Boot pools are excluded. Server text is bounded and control/bidirectional-control characters are rejected; errors use fixed local messages. Raw responses, logs, job errors and traces never become UI models.

Naive scan timestamps are normalized to UTC because the pinned producer uses `datetime.utcfromtimestamp`; ISO timestamps with zones and extended-JSON `$date` milliseconds are also parsed strictly. Invalid calendar normalization is rejected. Scan percentage is nullable and must be finite within 0–100; it is not an integrity assessment. Capacity is nullable and not proof that every dataset is usable. Capacity, percent, errors and time estimates may change without changing scan identity.

All visible jobs block new work, except STOP can coexist with START jobs referring exactly to its target ID/name. Internal scheduled calls may omit the named scrub method's documented START default; this is recognized only for that exact method. Any active scrub/resilver/expansion on another pool blocks changes. HA/failover workflows are excluded, even on a currently active controller. Visible-job checks cannot prove absence of jobs hidden by authorization or non-job external work.

## Exact mutations

| Action | Wire arguments / receipt |
| --- | --- |
| START | `pool.scrub.scrub [poolName,"START"]`; positive non-reused job ID. |
| STOP | `pool.scrub.scrub [poolName,"STOP"]`; positive non-reused job ID. Current scan must be SCRUB/SCANNING with a known start timestamp, including paused scrubs. RESILVER is never stopped. |
| Create schedule | `pool.scrub.create [{pool:poolId,threshold,description,schedule:{minute,hour,dom,month,dow},enabled}]`; exact returned schedule entry. Existing schedule for the pool blocks creation. |
| Update schedule | `pool.scrub.update [scheduleId,{threshold,description,schedule:{minute,hour,dom,month,dow},enabled}]`; exact returned schedule entry. Pool reassignment is never sent. |
| Enable / disable | `pool.scrub.update [scheduleId,{enabled:true|false}]`; preserve every other schedule field. |
| Delete schedule | `pool.scrub.delete [scheduleId]`; **literal true**, not null or a guessed job ID. |

Threshold is bounded to 0–3650 days; description to 200 plain characters; cron field strings to 100 characters. Checks use the server timezone. Threshold applies to eligibility since prior scrub history: reaching a cron time does not guarantee a new scrub. Deleting/disabling a schedule does not cancel an existing scrub. CRUD writes restart cron and can persist the database before a restart failure. The success contract verifies stored configuration, not future scheduling or completion.

Every action requires the exact session-issued inventory/pool/schedule object, a session-issued single-use review no older than five minutes and exact target text. Targets include action, pool ID/name/GUID, schedule ID when applicable, and the scan's UTC start timestamp for STOP. Public constructors exist only for connector-free previews and cannot manufacture authority. Refresh, wrong confirmation, new review, disconnect or changed identity invalidates the previous review.

Immediately before submission the SDK rereads all safety inputs. Pool ID/GUID/name, health/expansion, scan lifecycle, all schedules, timezone, HA and visible job identities must still match. Progress, remaining time and capacity drift alone do not invalidate an identified scrub. The ZFS scan timestamp has second-resolution provenance and is not an atomic scan token: an external administrator can race or replace a scan after the last read. No atomic compare-and-swap or transaction is claimed.

CRUD receipts are parsed into allowlisted fields and verified against a new complete projected inventory. The exact desired schedule must be present/absent and all other schedules and pool identities unchanged. No defaults or hidden fields are flattened into raw forms; no retry, rollback, remote shell or alternate mutation endpoint is used.

## Owned jobs, explicit checks and uncertainty

The submitted non-transient job is queried by exact ID **and** `pool.scrub.scrub` method with select `[id,method,arguments,state,result]`. Its arguments must be exactly `[reviewedPoolName, START|STOP]`; terminal success requires null result. The pool's ID/GUID/name, schedule baseline, timezone and scan lifecycle are rechecked. Once a START job's new scan start timestamp is observed, subsequent checks must retain that exact timestamp; a later scan is never silently rebound to the old job. A missing/evicted job or mismatched observation is uncertain.

WAITING/RUNNING returns **accepted**, not succeeded. It holds the shared mutation fence while leaving dashboard and explicit inventory reads available. The user can explicitly check the same owned handle; there is no timer or background polling. An exact STOP of the same current scrub is the only new pool mutation allowed through that owned-job fence. Its start timestamp must equal the scan already observed for that owned START; if the job was merely WAITING, explicitly check it to establish that observation before STOP. A replacement scan cannot inherit the earlier owned job's STOP exception. If STOP replaces an owned START handle in the UI, the SDK retains the earlier START lock and verifies that it also ends before resolving the STOP workflow. It never uses generic job abort.

A terminal START job is not necessarily a completed scrub: pinned middleware also exits successfully when a scrub is paused or canceled. Result text distinguishes FINISHED, CANCELED and paused; none is independent proof of integrity or a backup. STOP requires its own successful job and the same scan reporting CANCELED. If the scrub finishes concurrently instead, the native outcome is conservatively unknown.

Every error **after the first effectful RPC**, including permission errors, invalid job ID, job FAILED/ABORTED, lost connection, timeout, cron restart errors and readback failure, sets a sticky unknown fence. Manual job checks can still gather bounded observations but do not convert unknown back to accepted/succeeded or clear that fence. Inspect the original endpoint, reconnect and explicitly acknowledge recovery in the app before further writes. Requests are never replayed. Success does not mean no external concurrent change occurred.

## Remaining scope

Unsupported: pause/resume, scheduled `pool.scrub.run` execution, arbitrary job abort, HA coordination, unhealthy/boot pool changes, pool create/import/export/destroy/expand/upgrade, topology/vdev changes, replace/offline, encryption, multi-version API guessing and live acceptance testing. The preview refuses every write and job check. This bounded native implementation is not full TrueNAS WebUI parity and does not claim official affiliation.
