# M3-2 VDEV fixture contract implementation evidence

> Branch: `feat/m3-vdev-fixture-contract`
> Base: M3-1 reviewed SHA `1d152e339d0374d87e492e565c6b2c1a1a713834`
> Scope: static fixture decoding only. No runtime capability, live request, UI,
> persistence, or NAS mutation is claimed or enabled.

## Delivered contract

- Explicit selectors exist for `25.04`, `25.10`, and `26+`.
- Unknown versions reject before fixture traversal.
- Typed output contains only:
  - fixed group enums (`data`, `spare`, `cache`, `log`, `special`, `dedup`);
  - fixed operational status enums;
  - immutable child topology;
  - derived device counts and total node count; and
  - a local partial flag.
- Complete, partial, and rejected outcomes are mutually exclusive.
- Rejections contain only a fixed local enum and never fixture data.
- Raw maps and lists are consumed during synchronous parsing and never retained.

## Bounds

The implementation enforces and tests:

| Boundary | Limit | Evidence |
|---|---:|---|
| Group kinds | 6 | unknown and case-normalized duplicate groups reject |
| Root positions per group | 32 | 32 complete; 33 partial with 32 retained |
| Child positions per node | 32 | 32 complete; 33 partial |
| Depth | 8 | depth 8 complete; depth 9 discarded as partial when safe data remains |
| Retained nodes | 512 | 512 complete; 513th discarded and result partial |
| Maps visited | 1024 | 1024 complete; 1025 rejected |
| Lists visited | 256 | 256 complete; 257 rejected |
| Values/entries visited | 2048 | traversal rejects before enqueueing entry 2049 |
| String length | 64 UTF-16 units | 65 rejected |

Preflight traversal is iterative. Shared or cyclic map/list identity rejects with
`sharedContainer`. A map reporting more than 1024 entries rejects before its
entries are read.

## Data-safety matrix

Focused tests reject:

- malformed envelopes and top-level topology;
- unknown node type or status;
- no safe observation;
- API key, authorization, password, cookie, token, JWT-like, and AWS-key-like
  values;
- endpoint, device path, serial, GUID, WWN, enclosure/slot, host, account, and
  request identifiers;
- identifier/credential-shaped unknown keys;
- overlong strings, malformed surrogates, C0/C1 controls, bidi controls, and
  visually blank/default-ignorable strings;
- all 4,174 Unicode 17.0 `Default_Ignorable_Code_Point` values represented by
  the complete derived-property ranges used by the contract.

A safe paired emoji in ignored fixture metadata is accepted but is not retained
in the typed output.

## Immutability

The decoder copies all retained topology. Mutating the source fixture after
parse does not alter the snapshot. Group, root, and child lists are
unmodifiable.

## Runtime exclusion

Dedicated boundary tests prove:

- `VdevFixtureContract.isRuntimeEnabled` is always false;
- `DashboardCapabilities` never enables VDEVs or disks;
- the session query allowlist remains exactly:
  - `system.info`
  - `pool.query`
  - `pool.dataset.query`
  - `service.query`
  - `alert.list`
  - `core.get_jobs`
- production dashboard repository/controller/page/capability files do not
  import the fixture contract;
- Storage retains the static `VDEVs and disks unavailable` panel; and
- deferred admission remains unable to activate an API capability.

No production repository, controller, provider, page, capability, transport,
persistence, generated-schema, platform, or CI file changed.

## TDD evidence

Initial focused RED:

```sh
cd apps/truedash
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
```

Result: compilation failed because
`lib/features/dashboard/vdev_fixture_contract.dart` and every declared VDEV
fixture type were absent. This confirmed the test exercised missing production
behavior rather than a pre-existing failure.

Initial candidate review:

Exact-SHA specification and security review of
`59e4e9204564987dd015692787c895381fd95fce` rejected the candidate. The five
blocking themes were: unbounded preflight enumeration, preflight defeating
local partial semantics, missing 64/65 boundary scope, literal remote
`UNKNOWN`, effectively shared version schemas, and incomplete raw identifier
recognition. Public-path RED tests reproduced deceptive Map entries, a
billion-length custom List, embedded AWS-style values, plain host/IP/UUID/WWN
values, non-finite numbers, whitespace-normalized unsafe keys, data beyond the
32-position local boundary, 64/65-unit node strings, literal `UNKNOWN`, and
cross-family fixture reuse.

Remediation validates only attempted topology positions, bounds every
container plus 2,048 total visited values, and never bulk-copies an untrusted
collection. Unsafe content invalidates its containing node so a safe companion
can produce partial output. Each version selector requires its own local
contract marker and owns independent node/status tables. `unknown` now means
only an absent optional status.

The exact-SHA rereview of `5d7ad139b1004e1d52f342c8544e82ed65f4027b`
found three remaining boundary classes: preflight inspected node 513, hostile
list lengths overrode the local 32-position rule, and raw/modern identifiers
such as UUIDv7, nil UUID, IPv6, compact hostnames, prefixed WWNs, and embedded
AWS-style values remained admissible. The final regression matrix places a
billion-length payload at node 513 and beyond list position 32, covers those
identifier forms, and verifies that neither unattempted tail is traversed.
Preflight now records node-budget exclusions for the decoder, treats topology
list length as local partial state, and applies global bounds only to attempted
positions. UUID detection accepts every canonical version nibble rather than
only legacy UUID versions.

The next exact-SHA specification review of
`433d793ad10bab64811b81b58168ecdfcf10d37c` found two final ordering gaps:
depth-9 children could still be fetched by decoding, and a mismatched family
marker was checked only after topology preflight. Dedicated hostile collection
tests now prove a depth-9 child accessor is never invoked and a mismatched
marker rejects before any topology property is touched. Decoding stops before
iterating children at `maxDepth`, and `parse` checks its family marker before
creating the preflight context.

Focused GREEN:

```sh
cd apps/truedash
fvm flutter test \
  test/features/dashboard/vdev_fixture_contract_test.dart \
  test/features/dashboard/vdev_fixture_runtime_boundary_test.dart
```

Result: 26 tests passed (21 contract tests and 5 runtime-boundary tests).

The hostile-map guard was added after the first full pass. Its focused suite and
app analyzer passed before the remediation commit.

## Repository verification

Commands executed on the committed candidate include:

```sh
fvm dart format --output=none --set-exit-if-changed \
  packages/truenas_api packages/truedash_design_system \
  examples/design_system_consumer apps/truedash

(cd apps/truedash && fvm flutter analyze)
(cd apps/truedash && fvm flutter test)
(cd apps/truedash && fvm flutter build web --release)
(cd packages/truenas_api && fvm dart analyze && fvm dart test)
(cd packages/truedash_design_system && fvm flutter analyze && fvm flutter test)
(cd examples/design_system_consumer && fvm flutter analyze && fvm flutter test)
```

Observed results before the final evidence commit:

- formatting: 145 files checked, 0 changed;
- app analyzer: no issues;
- full app suite: 539 passed, 1 existing skip;
- Web release build: succeeded; `sqlite3.wasm` and `drift_worker.js` present;
- `truenas_api`: 64 passed, with two pre-existing informational analyzer
  notices in unchanged files;
- design system: 27 passed;
- external consumer: 1 passed;
- `git diff --check`: passed.

The complete gate is rerun after this evidence document is committed; any count
or result changed by that final run must be reconciled before review.

## Tooling note

Codex CLI was attempted first in the approved isolated worktree with
`--sandbox workspace-write`. WebSocket retries and HTTPS fallback both returned
`401 Unauthorized: Missing bearer or basic authentication in header` before any
file change. Codex output was not treated as implementation or verification
evidence. The bounded plan was then implemented directly with RED/GREEN tests.

## Versioned source recheck

The official version pages were re-fetched at `2026-09-10T06:07:34Z`. All three
document `PoolTopology` with the same required `data`, `log`, `cache`, `spare`,
`special`, and `dedup` arrays. That supports shared semantic group names, but
not transferable version admission; local contract markers enforce isolation.

| Version | URL | HTTP bytes | SHA-256 |
|---|---|---:|---|
| 25.04 | https://api.truenas.com/v25.04/api_events_pool.query.html | 234716 | `c1c985acc777566c3fe647d475acefe78c55c5c0c0b795a2ff129c3f0c64093f` |
| 25.10 | https://api.truenas.com/v25.10/api_methods_pool.query.html | 377778 | `d3305afa728b6ff4d060822a0c5efdc5c3c54efd60fd85dc33b024b980ff83c7` |
| 26.0 | https://api.truenas.com/v26.0/api_methods_pool.query.html | 425889 | `dec1b4837fbf1dc0f0a88a24c4298bc1f32573457b0f5783e93301fd1d9cca64` |

## Live and delivery boundary

- No TrueNAS host was contacted.
- No credential was read or used.
- No NAS state was changed.
- No runtime method or capability was admitted.
- No UI was activated.
- No branch was pushed and no MR was created for M3-2.
- M3-1 Draft MR `!30` remains separate and unchanged.
