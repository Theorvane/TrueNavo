# M3-4 Snapshot fixture contract implementation evidence

> Branch: `feat/m3-snapshot-fixture-contract`
> Base: M3-3 reviewed SHA `8d63baa4b37bd92268ad0e243302c573021bd5bf`
> Scope: bounded static redacted JSON fixtures only. Runtime Snapshot access, UI,
> credentials, persistence, and NAS mutation remain disabled.

## Delivered contract

- Explicit family markers for 25.04, 25.10, and 26+.
- JSON String input capped at 65,536 UTF-16 units.
- Duplicate decoded JSON keys and nesting beyond 16 reject before `jsonDecode`.
- Exact root `{contract, snapshots}` and record
  `{recursive, hold, retention}` schemas.
- Fixed family-owned token tables only.
- Output contains version, anonymous scalar aggregate counts, and partial state;
  no per-snapshot values or identities.
- Complete/partial/rejected states contain no fixture values or remote errors.

## Tested boundaries

- records: 256 complete; 257 partial with 256 retained;
- object entries: 1,024 accepted through shape evaluation; 1,025 rejects;
- token: 32/33 local record invalidation;
- encoded fixture: 65,536/65,537;
- JSON depth: 16/17 with fixed depth rejection;
- literal and escaped-equivalent duplicate keys;
- non-String poison Map/List rejected without member access;
- malformed JSON, cross-family markers, no-safe observations;
- credentials, network/account/request data, nil/UUIDv7, snapshot/dataset/pool,
  TXG/time, property/hold/retention, clone/task/replication data in keys/values;
- malformed Unicode and all 4,174 Unicode 17 default-ignorable code points;
- order-independent aggregates and pre-encoding mutation isolation.

## Runtime exclusion

Behavioral tests prove snapshots remain disabled even when
`pool.snapshot.query` is advertised and allowed methods remain the fixed six.
Repository-level diff/search gates prove runtime repository/controller/page,
capabilities, session allowlist, admission/evidence, persistence, platform, CI,
and bootstrap files are unchanged and do not import this contract.

## TDD

Initial focused implementation was derived only after the approved design and
plan. The missing Snapshot types/contract formed the RED boundary; after the
isolated implementation, focused GREEN is:

```sh
fvm flutter test \
  test/features/dashboard/snapshot_fixture_contract_test.dart \
  test/features/dashboard/snapshot_fixture_runtime_boundary_test.dart
```

Result: 14 contract tests plus 1 runtime-boundary test passed.

## Full verification

- formatting: 151 files, 0 changes;
- app analyzer: no issues;
- full app suite: 573 passed, 1 existing skip;
- Web release build succeeded with `sqlite3.wasm` and `drift_worker.js`;
- `truenas_api`: 64 passed; two pre-existing informational analyzer notices in
  unchanged files;
- design system: 27 passed;
- external consumer: 1 passed;
- Drift generation twice, Web assets, persistence-security, and
  `git diff --check`: passed.

## Tooling and safety

Codex CLI was attempted first with `--sandbox workspace-write`, but WebSocket
and HTTPS fallback returned `401 Unauthorized` before file changes. It was not
used as evidence. No TrueNAS host was contacted, no credential was used, no
runtime RPC/UI was enabled, and no NAS state changed.
