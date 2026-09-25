# Native local replication (partial TD042)

This is a bounded native TrueNAS **25.10 stable** workflow, not complete WebUI replication parity. Implementation and tests use public pinned source, synthetic RPC transports and connector-free Flutter fixtures. No test authenticates to a real NAS, uses the supplied credentials or submits a real server mutation.

## Supported native workflow

Inventory shows local and advanced replication tasks, their server-reported state and enabled status. The native writer supports single-source, non-recursive **LOCAL / PUSH / manual** tasks with one validated snapshot naming schema:

- Create and edit task name, source, destination, naming schema, enabled state and destination retention (`NONE`, `SOURCE`, or bounded `CUSTOM` lifetime).
- Enable or disable an existing supported manual task.
- Run after a separate source/destination/retention review and exact typed confirmation.
- Delete the task after review. This deletes the configuration, not its datasets or snapshots.
- Check only the exact job issued by that session, on demand. No polling timer, automatic retry, resume, replay or synthetic completion.

The wire settings explicitly fix `auto: false`, `schedule: null`, `periodic_snapshot_tasks: []`, `recursive: false`, `replicate: false`, `properties: false`, `encryption: false`, `allow_from_scratch: false`, `readonly: SET`, `hold_pending_snapshots: false`, and `retries: 1`. The server's retry setting is distinct from the app, which never replays a mutation. Saving/enabling a task does not send `replication.run`.

Remote SSH/PULL/SSH+NETCAT, encrypted replication, source properties, recursive/full-filesystem sends, scheduled tasks, snapshot-task bindings, arbitrary regex/property overrides, resume/restore, credential creation and from-scratch overwrites remain advanced, read-only inventory entries. Existing advanced settings are never flattened into the local editor or rewritten with native defaults. The generic schema administrator cannot bypass the dedicated create/update/run/delete reviews.

## Destination and retention review

Source and destination must be distinct, unrelated, non-system unencrypted filesystems. Pool roots cannot be selected. Locked, managed, unavailable or protected datasets and descendants of protected ancestors are refused. Public filesystem choices are intersected with bounded dataset identity reads.

An existing destination must already be read-only and have no child dataset tree. Running into it additionally requires a source/destination snapshot with the **same name and GUID**; an empty or unrelated existing dataset is not treated as safely disposable. Receiving can still roll back destination changes, which is explicitly disclosed. `allow_from_scratch` is never enabled.

A missing destination can be the direct child of an existing available, non-root parent. Review discloses that running may create this exact dataset. The adapter does not create intermediate parents or separately invoke `replication.create_dataset`.

Destination `SOURCE` retention can remove snapshots absent at the source; `CUSTOM` can expire matching snapshots according to server policy. Reviews display source and destination snapshot totals and explain the possible deletion. These totals are **not** eligibility counts, an exact deletion forecast, transfer-size estimates, free-space guarantees or backup-integrity evidence. `NONE` disables this task's destination snapshot-retention deletion policy. Dataset properties and encryption keys are not transferred by this native form.

## Safety and failure behavior

Capabilities require the stable version gate and exact public method metadata. Missing, private, file-transfer or incorrectly typed job metadata is not silently accepted. Page/provider reads are bounded `replication.query`, `pool.dataset.query`, `pool.filesystem_choices` and active `core.get_jobs`; reviews additionally query snapshots in the exact two-dataset scope. No remote dataset enumeration, effectful probe, key export or shell command is used.

Current completeness bounds are 128 replication tasks, 512 datasets, 128 active jobs and 256 snapshots across the selected source/destination. An overflow is rejected rather than treated as a complete inventory or safe review. Larger/paginated inventories remain outside this bounded adapter.

Task queries project safe configuration fields, `state.state`, SSH credential **ID only**, and historical job ID/state. They do not request SSH credential objects, encryption keys/key locations, raw task errors or job logs. Remote exceptions become fixed safe messages.

Inventories, reviews and jobs are identity-bound to one authenticated session. A new inventory invalidates older reviews. An issued review expires after five minutes and is consumed even by a wrong confirmation. Dataset GUIDs and safety attributes, task settings, active conflicts and source/destination snapshot name/GUID/transaction identities are re-read before dispatch. Changes reject without mutation. The public API has no compare-and-swap, so an external change after preflight remains possible and is disclosed.

Every writer participates in the repository's shared operation fence. A mutation timeout, malformed receipt, ambiguous non-permission exception or unverifiable readback retains an unknown-outcome fence across inventory reloads. An exact integer permission denial (`errno` 1 or 13) is handled as rejected; raw details are withheld. A run job holds the fence until its exact terminal state is verified. Only the issued job object can be polled; ID, method and default-expanded arguments must match. A failed/aborted job can have partial destination or retention effects and never triggers an automatic retry.

Create/update/delete success is based on the exact response plus configuration readback. Run success means the exact owned job reported `SUCCESS`; it is **not** independent backup/recovery verification. Operators still need a recovery test and an independent verified backup.

## Pinned public contracts

Sources inspected at `TS-25.10.1`:

- [Replication API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/replication.py): create `[settings]`, update `[id, patch]`, delete `[id]`; manual run `[id]` has hidden default `really_run: true` and a null terminal result.
- [Replication service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/replication.py): create/update/delete persist task configuration and refresh zettarepl tasks; `run` is a job, rejects disabled/running/held tasks and delegates to zettarepl. Local transport disallows remote credentials, stream compression and speed limit.
- [Zettarepl execution adapter](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/zettarepl.py): task scheduling, explicit run delegation and job progress propagation.
- [Zettarepl state](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/zettarepl_/state.py) and [TaskStateMixin](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/service/task_state.py): task `job` can be the latest **historical** job, not only an active job. Exact terminal historical states remain usable; unknown/pending job state is protected. A held task is itself unavailable, but an unrelated `HOLD` is not misrepresented as an active global transfer.
- [Public filesystem choices](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/info.py): local dataset choices exclude system/application internals and do not require modifying the dataset.
- [Dataset API](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool_dataset.py): dataset identity, encryption and read-only safety attributes.

Owned `core.get_jobs` records must match `method: replication.run`, `arguments: [taskId, true]`, the exact positive integer job ID, and terminal `result: null` for success. A record with only `[taskId]`, another task, another method, or a truthy non-null result is not accepted as proof.

## Evidence

`test/session/session_replication_test.dart`: **119 synthetic SDK tests passed** for public payloads, capability/version/file-transfer gates, safe projections, advanced-task protection, common snapshot identities, protected parents, readback, drift, forged/stale/consumed reviews, generic-schema bypass, historical/held jobs, manual owned polling with exact integer arguments, permission/malformed/timeout outcomes, retained fences and legacy-management exclusion. SDK and test static analysis are clean. Flutter/native emulator verification is tracked separately in the application parity ledger; this source-level evidence does not establish live-server compatibility or full parity.
