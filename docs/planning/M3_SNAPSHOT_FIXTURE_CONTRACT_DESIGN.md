# M3-4 Snapshot fixture contract design

> Status: approved direction for a fixture-only, runtime-disabled M3 foundation.
> Base: M3-3 exact reviewed SHA `8d63baa4b37bd92268ad0e243302c573021bd5bf`.
> This design does not authorize `pool.snapshot.query`, a live TrueNAS request,
> Snapshot UI, credentials, persistence, or NAS mutation.

## Goal

Define a version-bound decoder for **redacted static Snapshot fixtures** that
returns only immutable anonymous aggregate counts. It prepares a future
admission package without placing `pool.snapshot.query` in a runtime allowlist.

The official Snapshot schemas expose identifying fields including full snapshot
ID/name, snapshot name, pool, dataset, and creation transaction group. Optional
query expansions can expose properties, holds, retention, and transaction-group
filters.[1][2][3] M3-4 therefore does not model a raw Snapshot entry or accept
those expanded response objects.

## Source-backed boundary

All three versioned pages document snapshot identity, dataset/pool context, and
creation transaction-group data. Holds and retention are expansion-dependent;
25.10 and 26.0 also explicitly document `properties`, `min_txg`, and `max_txg`
query options. The documented role is `SNAPSHOT_READ`.[1][2][3]

These are discovery facts only. They do not prove a safe request fingerprint,
RBAC behavior on an appliance, a redacted live response, or runtime admission.

## Included scope

1. `snapshot_fixture_contract.dart` as a standalone synchronous decoder.
2. Explicit version markers:
   - `v25_04_snapshot_projection_v1`
   - `v25_10_snapshot_projection_v1`
   - `v26_plus_snapshot_projection_v1`
3. A bounded JSON-string fixture boundary.
4. Exact redacted root and record schemas.
5. Anonymous aggregate counts for:
   - recursive classification;
   - hold-presence classification; and
   - retention classification.
6. Complete, partial, and rejected typed outcomes.
7. Duplicate-key, malformed JSON, depth/size/value/record, Unicode, sensitive
   data, and version-isolation tests.
8. Runtime-exclusion checks.

## Excluded scope

- Runtime `pool.snapshot.query`, filters, query options, or `extra`.
- Full ID/name, snapshot name, pool, dataset path/name, GUID, TXG, creation time,
  user properties, mount points, clones, origin, comments, or remote identifiers.
- Raw properties, holds/tags, retention object, schedules, task identity, or
  transaction-group details.
- Snapshot list/detail/search/route/UI activation.
- Snapshot create, clone, rollback, hold/release, rename, delete, replication,
  retention change, or any mutation.
- Live fixture capture, evidence eligibility, admission, or compatibility claim.

## Fixture shape

The public decoder accepts only a JSON `String`:

```text
{
  "contract": "v25_10_snapshot_projection_v1",
  "snapshots": [
    {
      "recursive": "RECURSIVE" | "NON_RECURSIVE" | "UNKNOWN",
      "hold": "PRESENT" | "ABSENT" | "UNKNOWN",
      "retention": "MANAGED" | "UNMANAGED" | "UNKNOWN"
    }
  ]
}
```

These values are fixture-owned redacted projection tokens, not copied server
values. The redaction producer must derive them before fixture intake. M3-4 does
not define or authorize that producer.

## Architecture

```text
bounded redacted fixture JSON string
  -> reject non-String or input over 65,536 UTF-16 units
  -> reject duplicate decoded JSON object keys
  -> reject JSON nesting beyond 16
  -> validate family marker
  -> exact-shape positive-schema decoder
  -> SnapshotFixtureResult
       |-- complete(SnapshotInventorySnapshot)
       |-- partial(SnapshotInventorySnapshot)
       `-- rejected(fixed local reason)
```

Arbitrary caller-owned `Map`/`List` implementations reject before member or
equality access. JSON decoding yields ordinary acyclic and unaliased data.

## Typed output

`SnapshotInventorySnapshot` contains only:

- `DashboardVersionFamily`;
- total retained anonymous snapshot count;
- recursive, non-recursive, and unknown-recursion counts;
- hold-present, hold-absent, and unknown-hold counts;
- managed, unmanaged, and unknown-retention counts; and
- `partial`.

There is no per-snapshot model, label, source index, timestamp, dataset context,
identity, or arbitrary string.

`SnapshotFixtureResult` contains either a snapshot for complete/partial or a
fixed rejection enum. It never contains both and never includes remote values,
keys, paths, indexes, rejected counts, or error text.

## Semantic cautions

- `recursive` is a redacted classification, not an inference from a dataset path.
- `hold: PRESENT` means only that the redaction producer observed at least one
  hold; no tag or count is retained.
- `retention: MANAGED` means only that the producer classified the snapshot as
  managed by a retention source. No schedule/task/property identity is retained.
- Missing or ambiguous source data maps to an explicit projection token
  `UNKNOWN`; arbitrary remote strings never map to unknown.

## Positive schema

- Root keys must be exactly `contract` and `snapshots`.
- Record keys must be exactly `recursive`, `hold`, and `retention`.
- The duplicate-key scanner compares decoded keys, so literal and escaped-
  equivalent duplicate spellings reject before `jsonDecode`.
- Unknown keys invalidate the containing record because they could carry an
  identifier, property, hold tag, credential, or expansion data.
- Values map only through family-owned fixed token tables.
- Marker admission occurs after global JSON size/duplicate/depth validation and
  before typed snapshot record decoding.

## Bounds

| Boundary | Limit | Outcome |
|---|---:|---|
| Typed-decoded/retained snapshot records | 256 | structurally valid record 257 and tail are not typed-decoded; result partial |
| Typed root/record object entries visited | 1,024 | typed entry 1,025 rejects globally |
| Projection token length | 32 UTF-16 units | containing record invalid |
| Encoded fixture length | 65,536 UTF-16 units | reject before scan/decode |
| JSON nesting depth | 16 | reject before `jsonDecode` |

The input length is larger than M3-3 because each record has three fixed fields,
but remains bounded. The encoded-size, duplicate-key, and depth scanner
validates the entire JSON document before marker and record admission.
Malformed, duplicate, or over-depth content in a cross-family document or after
record 256 therefore rejects globally. The 256-record limit applies to typed
record decoding: a structurally valid record 257 marks the result partial but
is not mapped into aggregates. The 1,024 counter covers typed root and attempted
record object entries; other malformed nested content is bounded by encoded
size and JSON depth. The decoder does not retain source order.

## Outcome rules

### Complete

Return complete only when the family marker matches, root/list schema is valid,
one to 256 records are retained, and no attempted record is discarded.

### Partial

Return partial when at least one safe record remains and an attempted record is
malformed, has an unknown key/token, violates a token/Unicode rule, or the list
contains more than 256 records.

### Rejected

Return a fixed rejection when the family is unsupported, marker mismatches,
JSON/root/list is malformed, duplicate keys exist, global bounds are exceeded,
or no safe record remains.

## Sensitive and identifier boundary

Exact-shape validation is the primary control. Regression fixtures must place
representative forbidden data in keys and values:

- bearer/basic authorization, API key, password, cookie, JWT, AWS key;
- endpoint, hostname, IPv4/IPv6, account, request ID;
- UUID/GUID including nil UUID and UUIDv7;
- snapshot ID/name, dataset/pool path/name, TXG, timestamp;
- properties, property values/sources, holds/tags, retention details;
- clone/origin, task/schedule/replication identifiers;
- control, bidi, malformed surrogate, visually blank, overlong, and all Unicode
  17 `Default_Ignorable_Code_Point` values.

No finite denylist is used to turn arbitrary text into typed output. Only exact
keys and fixed local tokens can be retained as scalar counts.

## Immutability and determinism

Output contains scalar counts only. Mutating the caller's pre-encoding objects
after parsing cannot affect it. Reordering safe records produces identical
aggregates.

## Runtime invariants

Tests and repository gates must prove:

1. snapshots remain disabled in `DashboardCapabilities`;
2. the session runtime allowlist remains exactly the existing six methods;
3. production code contains no `pool.snapshot.query` runtime literal or fixture
   contract import;
4. Storage retains its static Snapshot unavailable panel;
5. deferred admission/evidence capability remains false;
6. no route, UI, provider, persistence, schema, platform, CI, or bootstrap file
   changes.

Runtime tests must use public behavior. Source/import/path/UI invariants are
verified by repository-level diff/search commands, not source-reading unit tests.

## Test matrix

### Accepted

- each family marker and fixture;
- all fixed tokens;
- record boundary 256;
- order-independent aggregates;
- pre-encoding source mutation isolation.

### Partial

- valid record plus malformed/unknown-token/unknown-key record within the first
  256 positions;
- token 33 UTF-16 units beside a safe record;
- sensitive, identifier, or unsafe Unicode key/value beside a safe record;
- structurally valid record 257, globally scanned but not typed-decoded.

### Rejected

- non-String custom collections without member/equality access;
- cross-family marker;
- malformed JSON/root/list and empty/no-safe list;
- literal/escaped-equivalent duplicate keys;
- encoded units 65,537, depth 17, or typed root/record entry 1,025;
- a sensitive, identifier, or unsafe Unicode case when no safe observation
  remains.

## Verification and delivery

Run focused tests, analyzer, full app suite, Web release build, API/design-system
consumer suites, Drift generation twice, Web asset and persistence-security
gates, format, prohibited-diff/search checks, and `git diff --check`.

The final exact SHA requires independent specification and security reviews.
Every finding gets a RED regression, remediation, complete verification, and
fresh reviews. After approval, push the exact branch, verify branch CI, and
create a Draft MR targeting `feat/m3-disk-fixture-contract`; verify its MR
pipeline. Do not merge, deploy, or contact/mutate TrueNAS.

## Acceptance criteria

- [ ] Three version markers reject cross-family fixtures after global JSON
      validation and before typed record decoding.
- [ ] Output contains only version, fixed anonymous counts, and partial state.
- [ ] No identity, path, time, TXG, property, hold tag, or retention detail
      crosses the boundary.
- [ ] Exact schema and fixed tokens determine all accepted data.
- [ ] Complete/partial/rejected outcomes are deterministic and non-sensitive.
- [ ] Record 256/257, typed entry 1024/1025, token 32/33, encoded 65536/65537, and
      depth 16/17 are durably tested.
- [ ] Non-String custom collections reject untouched; duplicate keys reject.
- [ ] Runtime allowlists/capabilities/UI remain unchanged and snapshots disabled.
- [ ] No live request, credential use, NAS mutation, merge, or deployment occurs.

## Source retrieval record

Retrieved at `2026-09-10T15:42:37Z`:

| Source | Bytes | SHA-256 |
|---|---:|---|
| [1] | 147681 | `f7df11aa42cc881d9aea4f82fb7536c392607ad8946e2365cbfaacb17af5139e` |
| [2] | 248077 | `82fe881a1748a01f67f83881be3b9401495ea48740fbac181e424b69447a87f6` |
| [3] | 261758 | `83df00d95098d0e74bb0b10f963bdbbcacb39102ff9b5e2c00b8feaf17217a92` |

## Sources

[1] https://api.truenas.com/v25.04/api_events_pool.snapshot.query.html
[2] https://api.truenas.com/v25.10/api_methods_pool.snapshot.query.html
[3] https://api.truenas.com/v26.0/api_methods_pool.snapshot.query.html
