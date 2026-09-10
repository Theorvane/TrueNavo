# M3-3 Disk fixture contract design

> Status: approved direction for a fixture-only, runtime-disabled M3 foundation.
> Base: M3-2 exact reviewed SHA `84405d5fea7222d88621aebb401cfa75d028d3a9`.
> This design does not authorize `disk.query`, a live TrueNAS request, runtime
> capability, Disk UI, credential use, or NAS mutation.

## Goal

Define a version-bound contract for **redacted static disk fixtures** that can
produce only anonymous, immutable, bounded aggregate observations. The contract
prepares evidence for a future admission review while keeping `disk.query`
absent from every runtime allowlist.

The official Disk schemas expose identifiers and sensitive or fingerprinting
fields such as identifier, name, serial, LUN ID, model, ZFS GUID, device path,
enclosure/slot, pool name, and password-related data.[1][2][3] M3-3 therefore
does not model a raw `DiskEntry`. It models a deliberately smaller redacted
fixture whose fields are derived before fixture intake.

## Source-backed boundary

The three versioned sources document `disk.query`/DiskEntry-family responses.
The 25.10 and 26.0 query options explicitly include `passwords` and `pools`
expansions, while 25.04 uses the older event documentation and a
`READONLY_ADMIN` role boundary.[1][2][3]

`rotationrate` is integer-or-null, where null covers SSD **and unknown** devices.
The contract must not mislabel null as SSD. It may classify only a strictly
positive RPM as `rotational`; all other accepted values become `unclassified`.
The raw `type` string is not admitted because the reviewed pages do not provide
a closed enum that can safely become a cross-version contract.[1][2][3]

These source facts are discovery inputs only. They do not provide request,
RBAC, live evidence, or runtime approval.

## Scope

### Included

1. A standalone `disk_fixture_contract.dart` module beside the existing VDEV
   fixture contract.
2. Explicit family markers:
   - `v25_04_disk_projection_v1`
   - `v25_10_disk_projection_v1`
   - `v26_plus_disk_projection_v1`
3. A positive redacted fixture shape:

   ```text
   {
     "contract": "v25_10_disk_projection_v1",
     "disks": [
       {
         "media": "ROTATIONAL" | "UNCLASSIFIED",
         "membership": "ASSIGNED" | "UNASSIGNED" | "UNKNOWN"
       }
     ]
   }
   ```

4. Fixed typed enums and derived aggregate counts.
5. Deterministic complete, partial, and rejected outcomes.
6. Strict local and global input bounds.
7. Hostile collection, secret/identifier, Unicode, aliasing, and mutation
   regression tests.
8. Runtime-exclusion tests proving all current production boundaries remain
   unchanged.

### Excluded

- Runtime `disk.query`, query filters/options, `passwords`, `pools`, or `extra`.
- Any live fixture capture or appliance response retention.
- Disk rows, labels, details, search, routes, actions, or UI activation.
- Disk identifier, name, number, serial, LUN ID, model, vendor, bus, device
  path/name, ZFS GUID, WWN, enclosure, slot, pool name, description, transfer
  mode, password, SED state, SMART options/results, expiration timestamp, or
  exact size/RPM.
- Treating `rotationrate: null` as proof of SSD.
- Disk wipe, SED controls, replace, offline/online, detach, or any mutation.
- Evidence eligibility, admission approval, or a claim of live compatibility.

## Architecture

```text
static redacted fixture Object?
  -> family marker validation before collection traversal
  -> bounded exact-shape decoder
  -> DiskFixtureResult
       |-- complete(DiskInventorySnapshot)
       |-- partial(DiskInventorySnapshot)
       `-- rejected(fixed local reason)
```

The production module has no transport import and exposes
`isRuntimeEnabled == false`. It is referenced only by dedicated tests. It must
not be imported by dashboard repository/controller/page/providers,
`truenas_api`, persistence, platform adapters, or app bootstrap.

## Typed model

### Disk media class

```text
rotational
unclassified
```

`rotational` means only that the redacted producer safely derived a strictly
positive RPM. `unclassified` combines SSD and unknown because the source
contract does not distinguish them when rotation rate is null.

### Membership class

```text
assigned
unassigned
unknown
```

Membership is already redacted before intake. No pool name, ID, GUID, path, or
other relationship identifier is allowed in the fixture or output.

### Snapshot

`DiskInventorySnapshot` contains only:

- version family;
- total retained anonymous disk count;
- rotational count;
- unclassified count;
- assigned, unassigned, and unknown membership counts;
- `partial`.

It contains no per-disk object or source-order identity. This prevents two
anonymous records from being used as durable device identities.

### Result

`DiskFixtureResult` contains exactly one of:

- an immutable snapshot for `complete` or `partial`; or
- a fixed `DiskFixtureRejectionReason` for `rejected`.

The result never includes a remote value, key, index, field path, rejected
count, host, method name, or error string.

## Positive schema

The root contains exactly `contract` and `disks`. A disk projection contains
exactly `media` and `membership`. Unknown keys are not ignored: the containing
record is invalid because an unknown field could hold an identifier or secret.

Both admitted strings map through family-owned fixed lookup tables. Arbitrary
strings never map to an `unknown` enum. `UNKNOWN` is an explicitly reviewed
local projection token only for membership; it is not a fallback for malformed
input.

The three family selectors own independent marker and enum tables. Their current
redacted shapes may be equivalent, but a fixture for one family must be rejected
by the other two before its `disks` collection is touched.

## Bounds

| Boundary | Limit | Outcome |
|---|---:|---|
| Root map entries | 2 | excess/unknown key rejects |
| Disk records attempted | 128 | tail is not traversed; snapshot is partial |
| Disk record entries | 2 | malformed record is discarded locally |
| Retained anonymous disks | 128 | additional records are not traversed |
| Maps visited | 256 | global excess rejects |
| Lists visited | 16 | global excess rejects |
| Values/entries visited | 512 | global excess rejects |
| String length | 32 UTF-16 units | containing record is discarded locally |

Limits apply to attempted positions, not valid records. A billion-length custom
list may expose only positions 0–127; position 128 and its tail must never be
indexed. A deceptive custom map may not yield entries beyond the global counter.
Shared/cyclic map or list identity rejects the whole fixture.

## Outcome rules

### Complete

Return complete only when:

- the family is supported and marker matches before list access;
- root and every attempted record have exact shape;
- one or more anonymous disks are retained; and
- no attempted record was discarded or local limit reached.

### Partial

Return partial when at least one safe disk remains and:

- an attempted record is malformed;
- an enum token is unknown;
- a record contains a prohibited string or field; or
- the disk list exceeds 128 attempted positions.

Unsafe data in one disk record invalidates only that record. It is never copied
into output or an error.

### Rejected

Return a fixed rejection when:

- family is unsupported;
- marker is absent/mismatched;
- root or `disks` envelope is malformed;
- no safe record remains;
- root contains an unknown field;
- global map/list/value bounds are exceeded; or
- cycle/shared-container identity is detected.

## Sensitive and identifier boundary

Every encountered key and string in an attempted record must first pass the
same complete Unicode control/default-ignorable/malformed-surrogate guards
proven by M3-2. Exact-shape validation then allows only fixed keys and enum
values.

Regression fixtures must place representative forbidden values in keys and
values:

- bearer/basic authorization, API key, password, cookie, token, JWT, AWS key;
- IPv4/IPv6, hostname, endpoint, account, request ID;
- UUID/GUID including nil UUID and UUIDv7;
- serial, LUN ID, WWN, device path/name, model/vendor, enclosure/slot, pool;
- `passwords`, `pools`, `extra`, SED, SMART, and exact hardware metadata;
- C0/C1, bidi, Unicode 17 default-ignorable code points, unpaired surrogate,
  visually blank, and overlong strings.

Because the allowed fixture values are four fixed tokens, positive-schema
matching—not a denylist—is the primary safety boundary.

## Immutability and determinism

The snapshot stores scalar counts only. Mutating source maps/lists after parse
cannot change it. Equal anonymous projections always yield equal aggregates,
and fixture order cannot affect output.

## Runtime invariants

Tests must prove:

1. `DashboardCapabilities` keeps disks disabled.
2. `TrueNasSessionRepository.readOnlyMethods` remains the exact six methods.
3. `disk.query` is absent from runtime production source literals.
4. Dashboard repository/controller/page/providers do not import the disk
   fixture contract.
5. Storage retains the static VDEV/disk unavailable panel.
6. Deferred admission and evidence objects still expose
   `apiCapabilityEnabled == false`.
7. No route, UI, persistence table, generated schema, CI, or platform file is
   changed.

## Test matrix

### Accepted

- each family marker with one valid anonymous record;
- every media/membership token;
- 128-record boundary;
- deterministic order-independent aggregate;
- source mutation after parse.

### Expected partial

- one invalid record beside one valid record;
- unknown enum beside valid record;
- forbidden/overlong string in one record;
- record 129 and hostile tail not touched.

### Excluded

- unknown family or cross-family marker;
- non-map root, non-list disks, unknown root key;
- empty/no-safe records;
- shared/cyclic/deceptive containers;
- 257th map, 17th list, or 513th value;
- every sensitive/identifier/Unicode case above.

## Verification

Run focused tests, analyzer, full app suite, Web release build, API/design-system
consumer suites, Drift generation twice, Web asset and persistence-security
gates, formatting, prohibited-diff checks, and `git diff --check`.

The final exact SHA requires independent specification and security reviews.
Review findings require RED reproduction, remediation, full verification, and
fresh reviews at the new SHA.

## Acceptance criteria

- [ ] All three family markers are explicit and cross-family fixtures reject
      before disk-list access.
- [ ] Output contains only version, fixed aggregate counts, and partial state.
- [ ] Null/unknown rotation information is never called SSD.
- [ ] Exact-shape positive schema prevents arbitrary strings and identifiers
      from crossing the boundary.
- [ ] Complete, partial, and rejected states are deterministic and non-sensitive.
- [ ] Local 128-record and global 256/16/512 traversal bounds hold against
      hostile custom collections.
- [ ] Source mutation, aliasing, and cycles cannot affect output.
- [ ] Runtime allowlist/capabilities/UI remain unchanged and disks stay disabled.
- [ ] No live TrueNAS request, credential use, NAS mutation, merge, or deployment
      occurs in this work unit.

## Sources

[1] https://api.truenas.com/v25.04/api_events_disk.query.html
[2] https://api.truenas.com/v25.10/api_methods_disk.query.html
[3] https://api.truenas.com/v26.0/api_methods_disk.query.html
