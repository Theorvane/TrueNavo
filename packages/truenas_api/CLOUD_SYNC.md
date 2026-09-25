# Native cloud sync (partial WebUI parity)

This adapter targets stable TrueNAS 25.10 using the pinned public **TS-25.10.1** middleware source. It is not full WebUI parity, a backup-integrity verifier, or an official TrueNAS application. Implementation and tests do not contact a NAS or use supplied credentials.

## Supported scope

- Read bounded local task configuration, existing credential **references**, dataset identities, server timezone and active-job safety state.
- Create, edit, explicitly enable/disable, run and delete bounded unencrypted **S3 and Dropbox** tasks. New task forms default to disabled; Run now can execute a disabled task.
- Choose an existing, unlocked, writable, normally mounted **leaf filesystem dataset**. Pool roots, system datasets, nested datasets, subdirectory paths and zvols are unsupported.
- PUSH/PULL, COPY/SYNC/MOVE, numeric cron expressions, distinct exclusion patterns, S3 bucket/region/storage class/server-side AES256 and Dropbox chunk size are explicitly represented.
- Existing task local path, credential ID, direction, bucket and folder are immutable in this form; create a separately reviewed task to change those endpoints.
- A direction doughnut has matching color legends, accessible counts and a separate scheduled count. It shows configuration, never transferred bytes, backup success or recoverability.

Scripts, arbitrary rclone flags, client-side encryption/passwords, snapshots, includes, bandwidth schedules, transfer-count overrides, empty-directory creation, symlink following, unsupported provider attributes, and currently active/locked tasks are display-only. Credential creation/editing/OAuth, additional providers, remote browsing, restore, abort, onetime sync and bucket creation are not implemented in this native workspace. No automatic credential verification, remote listing or dry run occurs.

## Pinned wire contract and effects

| Operation | Public method and exact argument shape | Important effect |
| --- | --- | --- |
| Inventory | `cloudsync.query [[], {limit:257, select:[...]}]` | Local task extension and task-state reads; latest job may be historical. |
| Credential references | `cloudsync.credentials.query [[], {limit:129, select:["id","name","provider.type"]}]` | No provider tokens, keys, endpoint attributes or passwords selected. |
| Create | `cloudsync.create [settings]` | Validates with the cloud provider when required, inserts configuration, restarts cron. |
| Edit/enable | `cloudsync.update [id, changedFields]` | Merges existing configuration, may contact the cloud, updates configuration, restarts cron. |
| Run | `cloudsync.sync [id, {dry_run:false}]` | Job; performs the configured data transfer. No client retries. |
| Delete | `cloudsync.delete [id]` | Calls task abort, removes task alert/configuration and restarts cron. Does not delete stored files directly. |
| Owned progress | `core.get_jobs [[["id","=",jobId]], {limit:2,select:[...]}]` | Manual read only, matching exact ID, method and `[taskId,{dry_run:false}]` arguments. |

Relevant primary source:

- [Cloud sync models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/cloud_sync.py), [common cloud task models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/cloud.py).
- [Cloud sync service, CRUD, rclone, jobs and credential extension](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/cloud_sync.py).
- [S3 provider validation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/rclone/remote/s3.py), [Dropbox provider validation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/rclone/remote/dropbox.py).
- [Nested select projection](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filter_list.py), [dataset API and extensible ZFS properties](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool_dataset.py).

`cloudsync.query` explicitly excludes client-side encryption passwords/salts and selects only nested credential ID/name/provider type. Existing scripts/custom arguments are examined only to reject advanced tasks and never enter public display models or outbound payloads. CRUD responses can contain secret fields according to the server contract; the adapter parses only the bounded display configuration and does not retain or expose other fields. This is data minimization, not a memory-zeroization guarantee.

## Safety and residual limits

Capabilities require stable-version admission and explicit public metadata with safe transport/job flags. A current-session inventory issues each review, which expires after five minutes and is consumed once. Review and execute re-read task configuration, credential references, timezone, dataset GUIDs and jobs. Every local path component is checked with `filesystem.stat`; `filesystem.statfs` binds the exact writable ZFS source/destination/filesystem identity. Symlink aliases and identity drift fail closed.

The final review shows the authenticated endpoint, both transfer endpoints, credential reference, direction/mode, timezone, schedule enablement and effects. Exact case-sensitive target typing plus separate impact acknowledgment are required. Session/inventory changes permanently expire and hide editor/review contents. A route change cannot replay a mutation. Pending/unknown outcomes retain the shared operation lock; polling is an explicit button, not a timer. Only exact owned terminal job evidence releases that job. Failed/aborted syncs can have partial transfers or deletions.

COPY can overwrite existing files; SYNC additionally deletes destination-only files; MOVE deletes source files after transfer. PULL writes NAS data. Exclusions are rclone patterns and are **not** an independently proven deletion boundary. Verify a separate backup and quiesce clients before enabling or running destructive transfers.

No public credential-secret fingerprint proves that a reference was not rotated, and the app does not inspect its remote endpoint. Remote files, ACLs, quotas, bucket versioning, object locks and transfer integrity are not attested. A leaf dataset and root `statfs` identity do **not** establish the absence of bind mounts or other nested mounts inside ordinary subdirectories. Users must independently ensure the local subtree has no nested mounts and keep its files quiescent; rclone can traverse that subtree. File contents and subsequent mount changes are not proven. Server-side S3 validation can resolve or normalize region information. TrueNAS has no atomic compare-and-swap for these operations; an external administrator or cron can act after preflight. Configuration receipts do not establish future run success. Non-permission RPC errors, malformed receipts, disconnection and timeout after dispatch remain unknown with no automatic replay. Exact integer EPERM/EACCES is reported as permission rejection; remote error text is withheld.

## Verification

`test/session/session_cloud_sync_test.dart` uses synthetic transports only. App `test/features/cloud_sync/cloud_sync_test.dart` uses connector-free providers and checks manual review, global locks, session drift, unknown/owned-job recovery, no automatic requests, chart semantics and small-screen 200% text layouts. `CloudSyncPreviewAdapter` contains static sample data and rejects all writes and polls.
