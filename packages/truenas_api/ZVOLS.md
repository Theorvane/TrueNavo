# Native Zvol workspace

This is a bounded native block-storage workflow for authenticated, stable TrueNAS
25.10 sessions, researched against the public **TS-25.10.1** implementation. It is
not full dataset/WebUI parity or release-wide certification. No NAS connection,
credential access, or real-server mutation is used for this implementation's
verification; acceptance evidence is synthetic fake-wire, controller, widget, and
preview behavior.

## Inventory and presentation

`pool.dataset.query` requests both `FILESYSTEM` and `VOLUME` types, a flat result,
no nested children, selected identity/configuration/space properties, and a limit
of 1025. More than 1024 rows, duplicate IDs, missing ancestry, malformed numeric
properties, or ambiguous configuration sources fail closed. Numeric byte values
use `rawvalue`, not rounded display text, and must be exact nonnegative integers
no larger than 9007199254740991.

The nonempty type filter is intentional: the pinned query implementation recurses
to descendants when filters are present, even with `retrieve_children:false`.
Requested ZFS properties are validated per filesystem/volume type. Mountpoint is
a top-level string for filesystems and explicitly `null` for volumes. The managed
user property is renamed inside `user_properties`; selection projects
`["user_properties.managedby", "managedby"]`. Its reported source is synthetic and
is not used as proof of property inheritance. Configuration-property sources are
checked separately. [Query normalization and traversal source](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_query_utils.py).

The provisioning chart shows **counts of returned volumes**, not bytes, pool
utilization, available capacity, or guest usage. Categories are disjoint: Thin
means zero `refreservation`; Reserved means `refreservation >= volsize`; otherwise
the volume has a custom reservation. These labels describe observed properties,
not a guarantee against pool exhaustion or a verification of the server's full
topology-dependent reservation calculation.

Logical device size, ZFS used/referenced bytes, `reservation`, and
`refreservation` are distinct figures. Used space can include metadata, snapshots,
and reservations. Summing logical sizes or ZFS accounting fields does not establish
physical free space, guest-filesystem utilization, or bytes recoverable by delete.
Exact raw byte values remain available alongside rounded display labels.
[Public dataset property model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/pool_dataset.py).

## Public methods and admitted changes

| Workflow | Public request | Admitted behavior |
| --- | --- | --- |
| Recommendation | `pool.dataset.recommended_zvol_blocksize [poolName]` | Read the parent pool's recommendation; no topology mutation |
| Create | `pool.dataset.create [options]` | New, unencrypted child Zvol under a verified filesystem parent |
| Grow/settings | `pool.dataset.update [id, changedFields]` | Thin-volume growth; selected setting changes |
| Delete | `pool.dataset.delete [id, {"recursive":false,"force":false}]` | Exact existing unattached, snapshot-free volume |

Creation requires a session-issued parent, a non-existing simple child name,
positive exact size divisible by block size, and fresh capacity checks. Every
ancestor must be visible, unencrypted/unlocked, unmanaged, writable, and mounted
at its standard `/mnt/<dataset>` path. System datasets and cloned volumes are not
managed here. New volumes explicitly use `type:VOLUME`, selected block size,
`sparse` provisioning, compression, sync policy, `readonly:OFF`, `snapdev:HIDDEN`,
`share_type:GENERIC`, `force_size:false`, `create_ancestors:false`,
`encryption:false`, and `inherit_encryption:true`; no keys or passphrases are sent.
Encrypted ancestry is refused rather than silently inheriting encryption.

The recommendation takes the **pool name**, not the full dataset path, and the
pinned source returns 16K through 128K according to pool topology. The requested
block size must be supported and at least the fresh recommendation. Create
capability requires this read method; no guessed recommendation enables mutation.
[Recommendation implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_info.py).

Create size is capped at 80% of the parent's currently reported available bytes,
including for sparse volumes. Thin growth uses the source's corresponding 80%
check against current parent available bytes plus the target's current ZFS used
bytes. Capacity is re-read before dispatch; force-size is never used. This is an
admission check, not a future free-space guarantee. Sparse provisioning does not
reserve the logical size, and later pool exhaustion can fail guest writes.
[Create/update validation and mutation source](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset.py).

Reserved creation delegates the reservation calculation, including metadata and
topology overhead, to the server. It does not assume `refreservation == volsize`.
**Growth is refused whenever existing `refreservation` is nonzero**, including
full and partial reservations. Adding only the logical-size delta would suppress
ZFS's automatic reservation adjustment without correctly recalculating overhead.
This slice does not reimplement that calculation or expose reservation changes.
[Pinned create calculation](https://github.com/truenas/py-libzfs/blob/TS-25.10.1/libzfs.pyx),
[pinned automatic reservation adjustment](https://github.com/truenas/zfs/blob/TS-25.10.1/lib/libzfs/libzfs_dataset.c).

Growth never shrinks or changes block size. Settings are limited to changed
compression (`OFF`, `LZ4`, `ZSTD`), sync (`STANDARD`, `ALWAYS`), and read-only state.
Unselected settings are omitted from the patch; readback checks the bounded
configuration and reservation fields. Compression changes do not rewrite all
existing blocks. Read-only changes explicitly disclose their write-access effect.
No guest partition or filesystem expansion, formatting, share creation, VM
attachment, backup, or recovery operation is included or guaranteed.

## Dependencies, reviews, and outcomes

Create, update, and delete require advertised dependency-read methods in addition
to their corresponding write method. Update/delete inspect
`pool.dataset.attachments`; all operations also read bounded configured VM,
iSCSI, and NVMe device inventories without enabled/running filters. VM type is
**`attributes.dtype`**, with its path in `attributes.path`; iSCSI DISK backing is
`disk`, and NVMe ZVOL backing is `device_path` such as `zvol/pool/volume`. Both
`/dev/zvol/` and `zvol/` spellings and the documented space-to-plus path spelling
are considered. Deletion additionally requires `pool.snapshot.query` and refuses
any target snapshot. [VM model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/vm_device.py),
[iSCSI model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/iscsi_extent.py),
[NVMe model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_1/nvmet_namespace.py).

The attachment helper checks enabled delegates, so it cannot replace the explicit
configured-device reads for disabled consumers. The public inventories are not a
proof that no arbitrary external consumer, process, path alias, or unreported
integration exists. Missing methods, denied reads, malformed data, or exceeded
bounds block admission; method advertisement alone does not guarantee permission
to complete every preflight. Server-side authorization remains authoritative.
[Attachment helper](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_attachments.py).

Inventory handles and reviews belong to the originating session. Forged or
refreshed handles cannot authorize mutation. Each review is single-use, requires
the exact target string as confirmation, and is consumed even on an incorrect
confirmation or rejected preflight. Target GUID, creation value, relevant
configuration/source fingerprints, and ancestor identity are rechecked after
dependency reads. Volatile space readings are refreshed for capacity, not treated
as immutable identity. Shared mutation locks exclude conflicting local workflows.

Create/update return ordinary dataset entries; their default properties do not
promise a GUID. The acknowledgement is checked for documented target ID/type,
then an independent explicit-property query supplies GUID and configuration
readback. Update requires the original identity; create requires a target absent
before dispatch and matching newly queried properties. Delete requires `true`
and independent target absence. A receipt alone is never proof of success.

There is **no atomic compare-and-swap** for GUID/configuration or attachment
ownership. Another administrator can race the final check. In particular, the
pinned dataset delete implementation can delete newly attached service
definitions before attempting ZFS deletion, even with force and recursive both
false. Its failure therefore does not imply that nothing changed. Keep other
clients idle; this workflow is not a server-wide maintenance lock.
[Deletion and update side effects](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset.py).

These mutation methods are synchronous, not owned-job APIs. Unexpected job-like
receipts are not polled or retried. Once submission begins, any timeout, remote
error, malformed receipt, session change, or failed readback yields **unknown**,
clears review leases, and retains the mutation lock. The UI retains the original
server/target when current-session data is cleared. A successful fresh read does
not clear uncertainty or authorize replay: inspect the original server and
reconnect. There is no automatic retry, cancellation, rollback, or compensating
cleanup. Before-send failures are rejected without a mutation.

Unsupported versions and missing permissions remain explicit limits; there is no
legacy/private API fallback or generic arbitrary-RPC editor. Preview fixtures are
static and reject mutation. Live mutation acceptance, arbitrary-consumer
discovery, and complete WebUI parity remain outside this slice.
