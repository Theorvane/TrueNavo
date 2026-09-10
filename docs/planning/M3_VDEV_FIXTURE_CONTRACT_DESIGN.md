# M3-2 VDEV fixture contract design

> Status: approved design for a fixture-only, runtime-disabled M3 foundation.
> Base: M3-1 exact reviewed SHA `1d152e339d0374d87e492e565c6b2c1a1a713834`.
> This document does not authorize a live TrueNAS request, runtime capability,
> UI activation, or NAS mutation.

## Goal

Define and test a bounded typed contract for the physical VDEV topology carried
inside the already-known `pool.query` response. The contract prepares a future
per-version admission package without changing the current product runtime.

M3-2 succeeds when fixture input can be converted into a deterministic,
credential-free typed snapshot or rejected fail-closed, while every runtime and
UI capability remains disabled.

## Scope

### Included

1. Immutable typed values for safe VDEV topology observations.
2. Fixture-only decoding for version families `25.04`, `25.10`, and `26+`.
3. A positive schema containing only:
   - fixed topology group kind;
   - fixed normalized operational status;
   - derived child/device counts; and
   - bounded child topology.
4. Explicit complete, partial, and rejected decoding outcomes.
5. Bounds for nesting depth, total nodes, children per node, and input
   collection size.
6. Adversarial fixtures for malformed structures, unknown enums, oversized
   collections, secret-shaped values, identifiers, and input mutation.
7. Regression checks proving runtime allowlists, capabilities, dashboard
   decoding, and Storage UI remain unchanged.

### Excluded

- Any new or parameterized RPC.
- Any live `pool.query` observation or retained appliance response.
- Runtime parsing of nested pool topology.
- VDEV UI, routes, controls, search, persistence, or telemetry.
- `disk.query`, disk serial/path/GUID/device identifiers, snapshot, ACL, Apps,
  filesystem, sharing, Shell, or other deferred domains.
- Pool/VDEV create, extend, attach, detach, offline, online, replace, remove,
  scrub, wipe, or any other mutation.
- A claim that any version/domain tuple is admitted.

## Contract boundary

The decoder accepts a fixture-owned `Object?` and a validated version family. It
must never receive or retain a live transport object. Raw maps exist only during
synchronous decoding and do not cross the return boundary.

```text
static fixture Object?
  -> version-family contract selector
  -> bounded positive-schema decoder
  -> VdevFixtureResult
       |-- complete(VdevTopologySnapshot)
       |-- partial(VdevTopologySnapshot)
       `-- rejected(fixed non-sensitive reason)
```

The implementation belongs beside the existing deferred observation contracts
under `apps/truedash/lib/features/dashboard/`. It must not be referenced by
`DashboardRepository`, `DashboardController`, production providers, or
`DashboardPage`.

## Typed model

### Version family

Use the existing `TrueNasVersionFamily` classification. `unknown` rejects before
fixture traversal.

### Topology snapshot

`VdevTopologySnapshot` contains:

- `versionFamily`;
- a bounded immutable ordered list of `VdevTopologyGroup`;
- `nodeCount`, derived from retained typed nodes only; and
- `partial`, indicating that at least one bounded fixture entry was discarded.

It contains no raw source value, arbitrary metadata, source method name,
appliance identity, endpoint, account, request ID, error text, or digest.

### Group and node fields

Allowed group kinds are fixed enums:

- `data`
- `spare`
- `cache`
- `log`
- `special`
- `dedup`

Allowed operational states are fixed normalized enums:

- `online`
- `degraded`
- `faulted`
- `offline`
- `unavailable`
- `unknown`

A node contains only its normalized status and immutable children. It has no
server-provided display name. Device leaves are represented by a derived count,
not by names, paths, serials, GUIDs, WWNs, enclosure slots, or other identifiers.

Groups are returned in the enum order above. Sibling nodes preserve validated
fixture order; no server-controlled field is used as a sort key or visible
label.

## Positive schema

Each supported-version decoder admits only the reviewed fixture keys needed to
obtain:

- topology group membership;
- normalized node type needed to distinguish branch from leaf;
- normalized operational status; and
- children.

Unknown keys are ignored only after every admitted field has passed validation.
No unknown key is copied, stringified, logged, or placed in an error.

Values in any display-bearing or enum-bearing field are mapped through fixed
lookup tables. Unknown enum text makes that node invalid; it is never preserved
as `unknown`. The `unknown` status is reserved for an absent optional status,
not arbitrary text.

## Bounds

The first implementation uses these fixed limits:

| Boundary | Limit | Failure behavior |
|---|---:|---|
| Topology groups in fixture | 6 | reject duplicate or excess groups |
| Root nodes per group | 32 | mark partial and retain the first 32 valid positions |
| Children per node | 32 | mark partial and retain the first 32 valid positions |
| Maximum node depth | 8 | mark partial at the first deeper child |
| Total retained nodes | 512 | mark partial and stop traversal |
| Input maps visited | 1024 | reject to cap malformed traversal cost |
| Input lists visited | 256 | reject to cap malformed traversal cost |
| String input | 64 UTF-16 units | reject the containing node before lookup |

Bounds apply to attempted positions, not just valid retained elements, so a
malformed prefix cannot force unbounded scanning. Traversal is iterative or
strictly depth-bounded. Shared map/list identities are rejected as cycle-like
input instead of traversed twice.

## Outcome rules

### Complete

Return `complete` only when:

- the version family is known;
- the fixture envelope and every traversed admitted field are structurally
  valid;
- at least one safe typed node is retained; and
- no row or child was discarded or truncated.

### Partial

Return `partial` only when:

- the envelope and version-specific schema are valid;
- at least one safe typed node is retained; and
- one or more individual nodes are malformed, unknown, beyond a local
  depth/width/total-node bound, or contain prohibited data.

The snapshot states only `partial: true`; it does not retain a remote value,
field path, index, count of rejected records, or error text.

### Rejected

Return one fixed rejected outcome when:

- version family is unknown;
- top-level envelope is malformed;
- no safe observation remains;
- duplicate/unknown topology groups exist;
- global traversal/map/list bounds are exceeded;
- cycle-like/shared container identity is observed; or
- any credential-shaped or identifier-shaped value appears in an admitted
  field.

The rejection reason is a fixed local enum and never embeds fixture values.

## Sensitive-data boundary

Fixture tests must place hostile values in every admitted string-bearing field
and in representative unknown fields. The contract fails closed for:

- API keys, bearer/basic authorization material, passwords, cookies, and tokens;
- endpoint/host/account/request identifiers;
- disk serials, GUIDs, WWNs, paths, device names, and enclosure slots;
- control, bidi, default-ignorable, malformed-surrogate, oversized, and
  visually blank strings.

The implementation uses a positive field schema and fixed enum maps. A finite
secret-key denylist is insufficient and must not be the primary boundary.

## Immutability

Returned lists must be unmodifiable. The decoder copies all retained structure;
mutating a fixture list or map after decoding must not change the snapshot.
Equality used in tests must compare typed values, not source identity.

## Version matrix

Each version family receives independent fixtures and an explicit selector.
Fixtures may share a helper only for fields proven identical in all three
captured schemas. A passing `25.10` fixture never admits a `25.04` or `26+`
shape automatically.

The source discovery ledger remains the source index. M3-2 does not create a
request fingerprint, response-schema approval, live evidence, admission record,
or approval. Those are later gates.

## Runtime invariants

The implementation and tests must prove:

1. `DashboardCapabilities` has no VDEV runtime capability.
2. `TrueNasSessionRepository` retains the exact six-method read-only allowlist.
3. `DashboardRepository.loadStorage` still calls only `pool.query` and
   `pool.dataset.query` and does not parse nested topology.
4. `DashboardPage` still shows the static VDEV/disk unavailable panel.
5. `DeferredAdmissionRecord.apiCapabilityEnabled` remains false for every local
   record.
6. No new provider, route, persistence table, generated schema, or live test is
   introduced.

## Test design

### Supported fixtures

For each version family, test:

- one data branch with safe leaf count;
- all six group kinds in deterministic order;
- every allowed status mapping;
- absent optional status maps to fixed `unknown`;
- immutable output and source-mutation isolation.

### Adversarial fixtures

Test independently:

- non-map envelope and topology;
- unknown/duplicate group;
- non-list children;
- unknown node type/status;
- malformed row before and after valid rows;
- width 32/33, depth 8/9, total nodes 512/513;
- 1024/1025 maps and 256/257 lists visited;
- repeated/shared list or map identity;
- overlong and malformed Unicode;
- control, bidi, and all Unicode default-ignorable ranges used by M3-1;
- secret-shaped and device-identifier-shaped text in each admitted and
  representative unknown field;
- no safe observation remaining.

### Regression gates

Run focused fixture tests first, then:

```sh
fvm dart format --output=none --set-exit-if-changed \
  packages/truenas_api packages/truedash_design_system \
  examples/design_system_consumer apps/truedash
(cd apps/truedash && fvm flutter analyze)
(cd apps/truedash && fvm flutter test)
(cd packages/truenas_api && fvm dart analyze && fvm dart test)
(cd packages/truedash_design_system && fvm flutter analyze && fvm flutter test)
(cd examples/design_system_consumer && fvm flutter analyze && fvm flutter test)
(cd apps/truedash && fvm flutter build web --release)
(cd apps/truedash && ./tool/verify_drift_generated.sh)
(cd apps/truedash && fvm dart run tool/verify_drift_web_assets.dart)
(cd apps/truedash && fvm dart run tool/verify_persistence_security_boundaries.dart)
git diff --check
```

Diff checks must show no change to runtime capability/allowlist, production
repository/controller/page, persistence, transport, or platform files.

## Acceptance criteria

- [ ] All three known version families have explicit fixture contracts.
- [ ] Typed output contains only fixed enums, derived counts, and immutable
      bounded child structure.
- [ ] Raw maps, arbitrary strings, identifiers, credentials, and remote error
      text cannot cross the decoder boundary.
- [ ] Complete, partial, and rejected outcomes are deterministic and
      non-sensitive.
- [ ] Depth, width, global traversal, and retained-node bounds are tested at
      both sides.
- [ ] Cycle-like/shared containers and fixture mutation cannot corrupt output.
- [ ] Runtime API allowlists, dashboard capabilities, Storage decoding, and UI
      remain unchanged and VDEV stays disabled.
- [ ] Focused and full verification passes at the final candidate SHA.
- [ ] No live TrueNAS request, NAS mutation, push, or MR occurs in this design
      stage.
