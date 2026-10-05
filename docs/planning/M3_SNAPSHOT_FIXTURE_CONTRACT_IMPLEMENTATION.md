# M3-4 Snapshot Fixture Contract Implementation Plan

> **For Hermes:** Implement task-by-task with TDD in the approved isolated worktree.

**Goal:** Build a version-bound, fixture-only Snapshot projection decoder that returns immutable anonymous aggregate counts while `pool.snapshot.query` remains runtime-disabled.

**Architecture:** Add `snapshot_fixture_contract.dart` as an isolated synchronous decoder. Accept only a bounded JSON string and globally scan the complete document for duplicate decoded keys and excessive nesting before `jsonDecode`; then bind the family marker and typed-decode the first 256 exact-shape records. Structurally valid tails are partial, while malformed/duplicate/deep tails reject globally. Use behavioral unit tests plus repository diff/search gates for runtime exclusion.

**Tech Stack:** Dart 3.13, `dart:convert`, Flutter test, FVM.

---

## Work boundary

- Worktree: `/Users/jungwon/workspace/.worktrees/truenavo-m3-snapshot-contract`
- Branch: `feat/m3-snapshot-fixture-contract`
- Base: `8d63baa4b37bd92268ad0e243302c573021bd5bf`
- Allowed production file: `apps/truenavo/lib/features/dashboard/snapshot_fixture_contract.dart`
- Allowed tests/fixtures: dedicated `snapshot_fixture_*` files and `test/fixtures/dashboard/snapshot/`
- Allowed docs: approved design, this plan, and implementation evidence.
- Never edit runtime repository/controller/page/capabilities, `truenas_api`, persistence, platform, CI, generated schema, or existing deferred contracts.
- Never contact TrueNAS, use credentials, enable UI, add an RPC, push before review, merge, or deploy.

## A/E/X

| Case | Expected |
|---|---|
| A: supported marker, bounded JSON, exact root/record, 1–256 fixed-token records | complete scalar snapshot |
| E: valid envelope with safe records plus malformed/unknown/record 257 | partial scalar snapshot |
| X: unknown/mismatched family, duplicate/malformed/deep/oversized JSON, no safe records, entry limit | fixed rejected result |
| X: advertised `pool.snapshot.query` | snapshots remain disabled; no call path exists |

## Task 1 — Typed scalar API

1. Write compile-failing tests for result/rejection enums, recursion/hold/retention enums, scalar snapshot fields, bounds `256/1024/32/65536/depth16`, and `isRuntimeEnabled == false`.
2. Run focused test and capture missing-type RED.
3. Implement result and immutable scalar snapshot types with snapshot XOR rejection.
4. Run focused test/analyzer.
5. Commit `feat(storage): define Snapshot fixture types`.

## Task 2 — Version-bound decoding

1. Add three JSON fixtures with family markers and exact `{recursive, hold, retention}` records.
2. Test all family selectors, fixed tokens, aggregate sums, and cross-family rejection.
3. Implement family-owned marker and token tables. Root exactly `{contract, snapshots}`; record exactly three approved fields.
4. Run focused suite.
5. Commit `feat(storage): decode versioned Snapshot fixtures`.

## Task 3 — Outcomes and local record boundary

1. RED: valid+malformed, valid+unknown token/key, empty/all-invalid, malformed root/list, and structurally valid record 256/257.
2. Implement local invalidation and fixed global rejection. Do not retain values, keys, indexes, or errors.
3. Stop typed decoding after position 255 and mark a structurally valid tail
   partial; global JSON scanning still rejects duplicate/deep/malformed tails.
4. Run focused suite/analyzer.
5. Commit `test(storage): enforce Snapshot fixture outcomes`.

## Task 4 — Bounded JSON and duplicate keys

1. RED: non-String poison collection untouched; encoded 65536/65537; depth16/17; entries1024/1025; literal, escaped-equivalent, and nested duplicate keys; malformed escapes/scalars/trailing data.
2. Implement or reuse an isolated bounded duplicate-key scanner suitable for this contract; cap before decoding and distinguish fixed rejection reasons where assertions require both boundary sides.
3. Verify no caller-defined collection member/equality/hash access.
4. Run focused suite/analyzer.
5. Commit `fix(storage): bound Snapshot fixture JSON`.

## Task 5 — Sensitive/identifier/Unicode matrix

1. Put credential, network, account/request, UUID/GUID, snapshot/dataset/pool/TXG/time, property/hold/retention, clone/task/replication, and mutation-related values in key and value positions beside a safe record.
2. Test token 32/33; malformed surrogate; C0/C1; bidi; blank; all 4,174 Unicode 17 default-ignorable code points.
3. Exact schema and fixed token maps remain the primary admission boundary.
4. Run focused suite.
5. Commit `test(storage): reject unsafe Snapshot fixture data`.

## Task 6 — Determinism and runtime exclusion

1. Verify order-independent scalar aggregates and pre-encoding mutation isolation.
2. Add only behavioral runtime tests: snapshots disabled and six-method capability intersection unchanged despite advertised snapshot method.
3. Verify imports, UI, session allowlist, admission/evidence, persistence, and prohibited paths with repository diff/search commands—not source-reading unit tests.
4. Run focused tests.
5. Commit `test(storage): keep Snapshot contract fixture-only`.

## Task 7 — Evidence, full gate, review, delivery

1. Write `M3_SNAPSHOT_FIXTURE_CONTRACT_IMPLEMENTATION_EVIDENCE.md` with actual RED/GREEN results, limits, source hashes, and no-live/runtime boundary.
2. Run full format, app analyzer/tests/Web build, API/design-system/consumer suites, Drift generation twice, Web asset and persistence-security checks, prohibited path/search checks, and `git diff --check`.
3. Commit evidence.
4. Request exact-SHA specification and security reviews. Every finding requires focused RED, remediation, full gate, new commit, and both reviews repeated.
5. After both approve, push exact branch, verify branch CI, create a Draft MR targeting `feat/m3-disk-fixture-contract`, and verify MR pipeline.
6. Do not merge, deploy, delete source branches, or contact/mutate TrueNAS.
