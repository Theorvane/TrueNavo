# Native snapshot workspace contract

The native workspace is deliberately restricted to stable TrueNAS 25.10.
All verification uses fake transports and fake repositories; no NAS connection,
credentials, or mutation is required by its tests.

## Sources

- [TrueNAS 25.10 snapshot query API](https://api.truenas.com/v25.10.0/api_methods_pool.snapshot.query.html)
- [TrueNAS 25.10 snapshot create API](https://api.truenas.com/v25.10.0/api_methods_pool.snapshot.create.html)
- [TrueNAS 25.10 snapshot delete API](https://api.truenas.com/v25.10.0/api_methods_pool.snapshot.delete.html)
- [TS-25.10.1 public service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/snapshot.py)
- [TS-25.10.1 API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool_snapshot.py)
- [TS-25.10.1 ZFS implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/zfs_/snapshot.py)
- [Clone, rollback and hold implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/zfs_/snapshot_actions.py)
- [25.10 rollback API](https://api.truenas.com/v25.10.0/api_methods_pool.snapshot.rollback.html)
- [25.10 clone API](https://api.truenas.com/v25.10.0/api_methods_pool.snapshot.clone.html)
- [25.10 hold API](https://api.truenas.com/v25.10.0/api_methods_pool.snapshot.hold.html)
- [25.10 release API](https://api.truenas.com/v25.10.0/api_methods_pool.snapshot.release.html)
- [Public dataset query implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_query_utils.py)

The public namespace is `pool.snapshot`. The `zfs.snapshot` implementation is
private. Both create and delete are synchronous methods, not jobs. No job polling,
private namespace fallback, generic RPC dictionary, or mutation retry is used.

## Reads and scope

Filesystem discovery uses a FILESYSTEM filter, a 1025-row sentinel limit, flat
results without children, and GUID/creation properties. More than 1024 filesystems
is rejected. Locked, system, and externally managed filesystems cannot be used
for native creation.

Snapshot discovery first uses the source's name-only fast path: an exact dataset
filter, optional snapshot-name prefix, `select: [name]`, alphabetical ordering,
25-row pages plus one sentinel. At most 40 pages are exposed. The source can still
enumerate names within that dataset before filtering and pagination; the limit
bounds returned data, not all server-side work.

Each displayed row is then read by one exact `id = dataset@snapshot` query with
a limit of two, `extra.holds: true`, and only `guid`, `creation`, `createtxg`,
`used`, `referenced`, `userrefs`, `clones`, and `defer_destroy`. At most five detail
queries run concurrently, at most 25 per page. A disappearing, duplicate, foreign,
or malformed row rejects that page. Concurrent changes can shift page contents.

GUID and transaction group remain decimal strings to preserve uint64 precision
on Flutter Web. Sizes are exact non-negative bytes within JavaScript's integer
range; larger or malformed values fail closed. Creation is shown in UTC and
exact Unix seconds. Missing safety fields remain explicitly unknown and disable
deletion. `userrefs` must be zero in addition to the returned holds map being
empty: the 25.10 API model only declares a `truenas` hold tag and the map alone
does not prove that arbitrary third-party holds are absent.

## Creation

The request retains the exact session-issued filesystem object and an explicit
1–64 character name from the conservative ASCII subset supported by this UI.
The SDK rechecks filesystem GUID, creation, lock/management eligibility, absence
of the exact proposed name, then filesystem identity again. The only payload is:

```json
[{"dataset":"tank/data","name":"manual-new","recursive":false,"vmware_sync":false}]
```

The returned snapshot identity must match a separate exact snapshot read and
the filesystem identity must still match. A snapshot captures filesystem state;
it does not coordinate applications, VMware or other VMs and is not an independent
backup. Children, naming schemas, exclusions and custom properties are outside
this flow.

## Deletion and race limitation

The user reviews one session-issued snapshot and types its full identifier
exactly. Reload invalidates that object. A fresh exact query must match the
reviewed ID, GUID, creation time and creation transaction group. Holds must be
empty, userrefs zero, clones explicitly `-`, and deferred destruction explicitly
`off`. System/application snapshot deletion is disabled. The only payload is:

```json
["tank/data@manual-1",{"recursive":false,"defer":false}]
```

Success requires a true method result and a separate exact query confirming
absence. Deletion cannot be undone. No hold is released, clone destroyed, child
snapshot deleted, or deferred deletion armed by this single-delete flow.

TrueNAS 25.10's delete API accepts a name, not an expected GUID or atomic
compare-and-delete token. The fresh proof and deletion are separate calls. An
external client could replace a snapshot under the same name between them.
This adapter cannot eliminate that server-side race; the UI asks users to avoid
concurrent snapshot changes in other clients. It does not claim an atomic identity
guarantee. The same restriction applies to filesystem identity checks before
creation and the recovery operations below.

## Explicit recovery impact

`reviewSnapshotRecovery` performs reads only and issues an immutable session-bound
review. `applySnapshotRecovery` accepts that exact review, a typed exact target,
and loss acknowledgement for rollback, release and deletion. The page additionally
requires authorization of all listed targets. The SDK repeats the complete review
before dispatch, comparing GUIDs, TXGs, hold timestamps/userrefs, clones, deferred
state, filesystem identity and exact descendant membership. GUID/TXG comparisons
use strings and BigInt. Limits are 64 inventory snapshots, 32 descendant filesystems
and 25 selected deletions. Original filesystem identities are re-read afterwards.

Clone sends `[{snapshot,dataset_dst,dataset_properties:{readonly:"on"}}]` to
`pool.snapshot.clone`. The target must be a new child under an issued same-pool
parent; no destination is overwritten. Source and destination must be eligible,
unencrypted filesystems with a writable destination parent. Middleware mounts the
clone. Readback requires the expected origin/read-only property, unchanged source
identity/holds, and exact added clone dependency. A clone is not an independent backup.

Hold sends `[id,{recursive:false}]`, requires zero existing holds, and adds the
fixed `truenas` tag. Its `null` receipt is independently verified through holds and
userrefs. Release has the same shape, but middleware removes **all tags**. Therefore
it requires exactly one visible `truenas` tag and `userrefs=1`, no deferred destruction
or unknown tags. Releasing the hold permits later retention-driven deletion.

Rollback actually calls `pool.snapshot.rollback` with `recursive`, `recursive_clones`,
`force`, and `recursive_rollback` all false. It permanently discards current filesystem
changes since the selected snapshot; no backup, undo point or application quiescing
is created. The review lists newer snapshots with GUID/TXG/holds/clones; any newer
snapshot blocks rollback until separately reviewed and deleted. There is no public
bookmark inventory: bookmarks are explicitly uninspectable and never selected for
destruction. No hidden `-r`, `-R`, forced unmount or child rollback is sent.
Latest-snapshot rollback requires a `null` receipt, unchanged snapshot/filesystem
identity/dependencies, no newer snapshot, `written=0` since the latest snapshot,
and matching referenced bytes. These are bounded ZFS postconditions, not a file-by-file
or application-consistency audit; concurrent writes can cause an unknown result.

The descendant workflow creates an explicit snapshot **set**, not an atomic recursive
snapshot. Public dataset query hides internal datasets, so broad recursive writes
could include unseen descendants. Each listed accessible filesystem is instead
captured by an exact non-recursive create. Volumes, internal and unlisted datasets
are excluded. Bulk deletion similarly issues an exact non-recursive/non-deferred
delete for each checkbox-selected snapshot. Both workflows preflight the entire
review and each individual target, stop at the first failure, and hold the unknown
outcome lock even when earlier targets completed. There is no retry, automatic cleanup,
implicit child deletion, or all-or-nothing claim.

## Session and outcomes

The controller binds the exact authenticated-session object and endpoint and
acquires the shared server operation lock. The SDK also rechecks connection
currency before and after each RPC and immediately before writing, and shares
busy predicates with other mutation adapters. Reads never authorize a write.

Preflight failures are rejected without dispatch. After dispatch, a timeout,
disconnect, server error, malformed reply or failed readback is conservatively
unknown. Nothing is retried. The SDK retains its busy state until reconnect;
the UI retains the original server/target warning and requires explicit
acknowledgement after a different authenticated session before another snapshot
operation. Late completion cannot replace an unknown outcome with success after
a session switch.

## Fake validation

`test/session/session_snapshots_test.dart` covers bounded queries, read-only
accounts, exact payloads, preflight drift, forged/stale objects, hidden holds,
clones, deferred destruction, missing safety information, post-dispatch failures,
duplicate submission, precision boundaries, and authentication changes.
Application tests cover shared locks, explicit reviews, exact confirmation,
unknown outcomes, session replacement and 320px layouts at 200% text size.
