# Native Rsync — bounded TS-25.10.1 contract

TD-045 is partial. The native workspace supports projected task inventory, disabled task creation/editing, separate enable/disable/delete, and one explicitly authorized manual SSH PUSH with an owned job check. It is not full Rsync/WebUI parity. Development and tests used only public source and synthetic transports/widgets; no NAS, supplied credential, remote SSH, host scan, real transfer or real write was used.

## Pinned sources and important distinctions

- [Public Rsync models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/rsync_task.py): task fields, five-field cron, create/update validation flags, nested SSH credential entry, boolean delete result and null run result.
- [Rsync implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/rsync.py): updates revalidate the complete task; omitted `validate_rpath` defaults to true. `ssh_keyscan` can modify local known_hosts before validation finishes. CRUD persists configuration and restarts cron. A run is a job, ignores schedule enablement, and accepts some nonzero Rsync return codes as nonfatal.
- [Task/path service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/service/sharing_service.py): `locked` refers to a path in a locked dataset, **not** a currently running job. Higher-level task operations can update TaskLocked alerts after persistence. [Path validation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/validators.py) alone does not establish the native dedicated-directory boundary.
- [Persisted task state](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/service/task_state.py): prior task job metadata can survive restart and is not owned-job authority.
- [Command user context](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/user_context.py): transfer execution uses a shell under the chosen local account. Therefore raw extras and shell-active host/account syntax cannot enter the native workflow.
- [SSH host-key formatting](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/rsync_/utils.py), [keychain models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/keychain.py) and [nested query projection](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filter_list.py) establish the type-sensitive public identity projection used here.
- [Upstream Rsync manual](https://download.samba.org/pub/rsync/rsync.1#opt--one-file-system): the fixed one-filesystem option bounds cross-device recursion but does not exclude same-device bind mounts. Trailing slashes have distinct copy semantics and are not normalized silently.

## Admitted tasks

- SSH mode with an existing SSH_CREDENTIALS keychain connection and a referenced keypair's validated public identity. MODULE/unencrypted daemon transfers and home-directory key fallback remain read-only.
- PUSH only. The local path is exactly the normal mountpoint of a mounted, unlocked, writable **leaf ZFS dataset**. Pool roots, system/hidden datasets, nested datasets, remote/SMB filesystems, symlinked path components and non-directory sources are excluded.
- A uniquely identified local, non-builtin, unlocked user with UID above zero and a bounded plain username. Directory users, local root and the literal remote username `root` are excluded. The remote account's UID and privilege level are not probed; aliases cannot be proven non-root. The server still decides authorization and file access.
- A bounded bare host/IP, plain remote account, existing host-key fingerprints and a dedicated non-root absolute remote path with plain components. Reserved system roots, traversal, whitespace, shell tokens and trailing slashes are rejected rather than rewritten.
- Recursive directory copy with typed times/compress/delay-updates options. Archive, deletion, quiet mode, permissions, extended attributes, arbitrary exclusions and arbitrary extra/shell arguments are prohibited. The only native extra is the fixed `['--one-file-system']`.

Existing otherwise-safe tasks with `extra:[]` may be edited, disabled or deleted. They cannot be enabled/run until a reviewed update adds the fixed protection. An unchanged-settings update is permitted for this one transition. Its receipt and projected readback must actually contain the flag; a computed settings default cannot substitute for server evidence. Other existing configurations have only bounded identity/description/mode/direction/state summaries; unsupported path/argument details are withheld and never flattened into an editable form.

The source is copied without adding a trailing slash. When the remote destination already exists as a directory, it receives the source directory. When the destination is absent, the resulting layout may differ; for example, an empty source directory can take the destination name. The app does not verify remote destination existence or layout. See the [official rsync copying-to-a-different-name rules](https://download.samba.org/pub/rsync/rsync.1#COPYING-TO-A-DIFFERENT-NAME). `delete:false` does **not** prevent overwriting destination files. Recursive source content can change during a run; no snapshot or consistent-copy guarantee exists. Fixed `--one-file-system` is not proof that the source tree has no bind-mounted content.

## Reads and secret exclusion

| Read | Bounded request |
| --- | --- |
| Keypair public identity | `keychaincredential.query` filtered to type SSH_KEY_PAIR, limit 65, select id/type/attributes.public_key. |
| SSH connection | Separate type SSH_CREDENTIALS filter, limit 65, select id/name/type and host/port/username/private_key/remote_host_key/connect_timeout attributes. Here private_key is an **integer reference**, not key material. |
| Users | `user.query` filtered local=true, builtin=false, uid>0, locked=false, limit 513, select id/uid/username/local/builtin/locked. No password hashes or full profile. |
| Datasets | `pool.dataset.query` flat=true, retrieve_children=false, properties guid/mounted/readonly, limit 513; select id/type/guid/mountpoint/mounted/locked/readonly/key_loaded. |
| Tasks | `rsynctask.query`, limit 129, with an explicit policy-field select. Nested credentials project only id/type; prior job projects **job.state only**. |
| Local safety | `system.general.config` retains only timezone; `failover.licensed` requires an actual boolean. |
| Active jobs | `core.get_jobs` filters WAITING/RUNNING, limit 129, select id/method/state. No arbitrary job arguments, errors or logs. |

Limits are 64 keypairs/connections, 512 eligible users/datasets, 128 tasks and 128 visible active jobs. Over-limit, missing required data, malformed IDs, unsafe text, invalid cron, duplicate identities and invalid typed credentials fail closed. SSH host-key comments are normalized away before fingerprint DTOs. Existing private keys are never requested, displayed or stored by this SDK/UI. Public identity cannot prove private-key presence, private-only replacement, remote ownership or authentication usability.

The raw public `extra` array must be inspected briefly to distinguish the exact native option from unsupported arguments; raw values never enter the task DTO, review, error or application state. Create/update receipts may contain nested credential attributes; only allowlisted task fields are inspected and a separate projected readback establishes the result. No raw JSON/editor escape hatch exists.

`lastJobState` is only WAITING/RUNNING/SUCCESS/FAILED/ABORTED or null. It is labeled as last recorded state, may be stale, and cannot establish current activity or job ownership. Current admission uses the separate active-job query. Job visibility is server-authorization dependent; no claim of exhaustive non-job/hidden activity detection is made.

## Exact write contracts

- Create: `rsynctask.create [settings]`, with every native field explicit, enabled=false, SSH/PUSH, existing numeric ssh_credentials, forbidden flags false, fixed extra option, and **validate_rpath:false, ssh_keyscan:false**.
- Update: `rsynctask.update [id, settings]` on a disabled task, with the same two validation flags explicitly false. Source/user/connection changes require old and new local path proofs. Schedule enablement is a separate operation.
- Enable/disable: `rsynctask.update [id,{enabled:true|false,validate_rpath:false,ssh_keyscan:false}]`. No accidental defaults, remote validation or known_hosts discovery. Enabling explicitly authorizes future scheduled SSH connections and destination writes in the server timezone without another app confirmation.
- Delete: `rsynctask.delete [id]`, disabled task only, receipt must be literal true. It deletes configuration, not copied data, and does not cancel an active transfer.
- Run: `rsynctask.run [id]`, disabled schedule only, receipt must be a new positive job ID. This explicitly authorizes one actual remote SSH/data-transfer effect when used by the user; it was never executed against a real server during development.

Editing still allows server-local account/path/key validation; disabling remote validation does not make an edit a side-effect-free read. Cron restart, alert updates and datastore changes may fail in different orders. No SSH connection timeout is promised for the transfer: the keychain connect_timeout field is not forwarded by this Rsync execution path.

## Issued reviews, path proofs and jobs

An exact session-issued inventory/task and single-use review are required. Reviews expire after five minutes and are invalidated by refresh, wrong confirmation, a replacement review or disconnect. Exact target text includes action/task ID, source path, credential ID and remote path; the review also displays the server endpoint, user, SSH destination, public-key trust and before/after policy.

Immediately before submission, task settings, eligible accounts, public SSH identities, dataset GUID/mount state, timezone, HA and visible jobs are reread. Every source ancestor is checked by `filesystem.stat` for DIRECTORY, exact realpath, no control directory, stable device/inode/mount/owner/mode; the final source must be a mountpoint. `filesystem.statfs` must identify the exact ZFS dataset/path, fsid and writable flags. These proofs are repeated after writes/checks. External hot changes, permissions and remote path content can still race; there is no atomic compare-and-swap or remote overwrite preview.

CRUD requires an exact typed receipt plus the expected projected after-state; unrelated tasks/references must remain unchanged. Run owns only the submitted job ID. `core.get_jobs` then filters both that ID and method `rsynctask.run`, selecting id/method/arguments/state/result. Arguments must exactly equal `[taskId]`, result must be null, and all original task/reference/path proofs must remain valid. Persisted task-state IDs are never used. The session retains a bounded history of **64 issued run IDs**: reused IDs are unknown, and additional new runs after that capacity are refused before dispatch until a fresh session.

WAITING/RUNNING means accepted, not finished, and holds the shared mutation fence. Dashboard/manual inventory reads remain possible. Only explicit checks of that exact issued handle are allowed; no automatic polling, generic abort, replay or retry occurs. SUCCESS/null is reported as the server's outcome, not proof of complete transfer: vanished-file/deletion-limit statuses may count as success, and a locked-dataset early return can also be successful. Native fresh locked-state checks reduce but cannot eliminate that race.

All post-dispatch errors—including permission failures, timeout, missing/changed job, FAILED/ABORTED, malformed receipt or readback drift—become sticky unknown. Later valid reads/checks do not erase that status or unlock writes. Inspect the original server before reconnecting and acknowledging recovery. No transfer log, command output, exception payload or job excerpt is disclosed.

Remaining scope includes MODULE/PULL, destructive mirroring, archive/symlink/ACL semantics, arbitrary custom options, root/directory users, remote verification and setup, richer mount/dependency discovery, cancellation, HA coordination and live acceptance. Connector-free previews reject all writes/checks. This is neither full WebUI parity nor an official TrueNAS affiliation claim.
