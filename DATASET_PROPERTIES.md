# Native filesystem property editing

This is a restricted native workflow, not full dataset or WebUI parity. It edits
quota, refquota, reservation, refreservation, compression, atime and readonly on
ordinary unencrypted filesystem datasets. It never changes ACLs, encryption,
keys, mountpoints, topology, ZVOL sizes or arbitrary dataset properties.

## Verified TrueNAS 25.10 contract

Primary evidence is pinned to the TS-25.10.1 middleware implementation:

- [Public request and property schemas](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/pool_dataset.py)
- [Dataset query and update implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset.py)
- [Query traversal, normalization and source metadata](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/pool_/dataset_query_utils.py)

Discovery sends `pool.dataset.query` with a nonempty FILESYSTEM/VOLUME type filter,
`limit:1025`, `extra.flat:true`, `retrieve_children:false`,
`retrieve_user_props:true` and a fixed set of identity, capacity and property
names. A nonempty filter is important: the tagged implementation only recurses
without child retrieval when filters are present. Results over 1024 rows fail
explicitly. No truncated public-query result is presented as complete; hidden
internal names still require the independent count guard described below.
Volume descendants participate in identity/configuration and leaf-impact guards,
but are not presented as filesystem property editors. In particular, a filesystem
containing only ZVOL children must not be mistaken for a leaf.

GUID and creation distinguish an object from a replacement at the same path.
Property values use `rawvalue`, not formatted human-readable byte strings.
Zero byte limits are unlimited; zero reservations reserve no additional space.
The query implementation can expose `parsed:null` and `value:null` for these
zero properties. The editor retains exact integer bytes. Quota and refquota are
0 or at least 1 GiB; maximum supported input is 2^53-1 bytes for exact JSON
interoperability. Reservations are nonnegative integers.

The native form offers B/KiB/MiB/GiB/TiB input units. Decimal input is converted
with integer arithmetic and must represent an exact whole number of bytes;
fractional bytes, exponent notation and overflow are rejected. Switching units
preserves the current amount with all needed decimal digits, and review shows
the exact integer byte proposal. Existing values start in bytes without rounding.

Only compression, atime and readonly offer `INHERIT`; the four size properties
do **not** accept inheritance in the update schema. The schema's compression
update enum excludes e.g. GZIP-2 through GZIP-8 despite their validity in ZFS;
such existing settings remain visible but block this editor. Inherited source
and effective parent value are shown separately. TrueNAS normalizes native
property sources through libzfs; source metadata on user properties is known to
be synthesized and is not used as proof of inheritance.

The redundant `ZSTD-FAST-1` input is intentionally not offered: select
`ZSTD-FAST`, its canonical serialized value. OpenZFS assigns both names the same
index and resolves the first matching name during read-back. This avoids a false
unknown outcome after a successful update without collapsing distinct policies
such as `ON` and `LZ4`. Evidence:
[compression table](https://github.com/openzfs/zfs/blob/zfs-2.3.4/module/zcommon/zfs_prop.c),
[fast-level default](https://github.com/openzfs/zfs/blob/zfs-2.3.4/include/sys/zio_compress.h),
[index serialization](https://github.com/openzfs/zfs/blob/zfs-2.3.4/module/zcommon/zprop_common.c).

`managedby` comes from TrueNAS user-property normalization, separately from the
requested ZFS properties. The explicit `retrieve_user_props:true` ensures that
guard is requested even with a restricted ZFS property list.

The wire mutation is `pool.dataset.update([exactDatasetId, changedFieldsOnly])`.
It is not treated as a background job. Advertised query, update and attachments
methods plus stable 25.10 version are required. Method advertisement is not a
guarantee of write RBAC; the server still authorizes each call.

## Safety and known limits

- Snapshots are immutable objects issued by one authenticated SDK session.
  Reload invalidates old review handles. No user-supplied map can inject
  encryption, ACL, mountpoint or other update keys.
- Before mutation the SDK re-reads target, parent and descendants. GUID,
  creation, guarded filesystem configuration, property values and source are
  compared. Capacity counters may evolve, and validation repeats against fresh
  usage and parent available space.
- Quotas cannot be below observed used/referenced bytes, reservations cannot
  exceed finite corresponding quotas, and combined reservation increases cannot
  exceed parent available space. This is conservative screening, not a pool-space
  reservation. TrueNAS/ZFS perform the authoritative validation.
- Pool roots, encrypted/locked datasets, nonstandard mountpoints, internal or
  managed datasets are blocked. Inherited behavior updates are currently limited
  to verified leaf filesystems: both zero visible descendants and
  `filesystem_count:0` must be reported. Public dataset query hides internal
  names, so visible results alone cannot prove this. The count is only available
  when filesystem-limit tracking is enabled in that tree; otherwise behavior
  controls are disabled, while byte limits remain available. No tracking settings
  are changed by the app. See the official
  [filesystem_count property definition](https://github.com/openzfs/zfs/blob/zfs-2.3.4/man/man7/zfsprops.7).
  Effective readonly changes additionally require an empty
  `pool.dataset.attachments` response and another configuration check.
- Review identifies the authenticated endpoint, exact path and GUID, current
  effective/source values and proposed effective/source values. Explicit impact
  acknowledgement is required. Property changes have no automatic rollback.
- SDK mutation gates are shared with generic administration, quick management
  and dedicated network testing. The app also shares its operation lock; changing
  routes cannot duplicate a submission. Session replacement invalidates reviews.
- A successful update RPC is not success evidence alone. The SDK independently
  re-reads properties, unchanged fields, source, identity and related records.
  Only the verified read-back outcome is shown as verified.
- Once a write has been sent, timeout, RPC errors, transport failure or mismatched
  read-back produce **unknown**, not an assurance of rejection. Some ZFS property
  updates can be partially applied. There is no automatic retry or rollback.
  The SDK holds its mutation gate until reconnect. The app retains an original-
  server warning and requires explicit inspection acknowledgement after the
  connection changes before new submissions.
- TrueNAS does not supply compare-and-swap/ownership tokens for these updates.
  External changes can race after checks, including attachment creation or space
  consumption. Exclusive maintenance and final server validation remain needed.

## Evidence

Fake JSON-RPC contract tests cover the typed payload, gates, invalid values,
source/inheritance, current capacity, configuration drift, uncertainty and shared
mutation locking. Flutter controller/widget tests cover exact-session guards,
review/cancellation, byte validation, narrow screens, large text and keyboard
layouts. A separate guarded read-only 25.10.1 probe parsed 15 property records,
retaining seven protected records and all unverified-leaf behavior restrictions.
No live dataset mutation or destructive acceptance test was performed. Write
authorization and device validation remain required; this is not evidence of
complete WebUI parity. See [bounded live evidence](docs/planning/READONLY_LIVE_VALIDATION.md).
