# M3-3 Disk Fixture Contract Implementation Plan

> **For Hermes:** Implement task-by-task with TDD in the approved isolated worktree.

**Goal:** Build a version-bound, fixture-only Disk projection decoder that returns only immutable anonymous aggregate counts and cannot activate `disk.query`.

**Architecture:** Add `disk_fixture_contract.dart` as an isolated synchronous decoder beside the VDEV fixture contract. Accept only a bounded JSON string, reject duplicate object keys, validate the family marker, apply exact-shape positive-schema decoding to the first 128 attempted records, and return complete/partial/rejected typed outcomes containing scalar counts only. Dedicated behavioral tests and repository-level diff commands prove runtime files remain unchanged.

**Tech Stack:** Dart 3.13, `dart:convert`, Flutter test, FVM, bounded JSON and hostile non-String collection probes.

---

## Immutable work boundary

- Worktree: `/Users/jungwon/workspace/.worktrees/truedash-m3-disk-contract`
- Branch: `feat/m3-disk-fixture-contract`
- Base: `84405d5fea7222d88621aebb401cfa75d028d3a9`
- Allowed production file: `apps/truedash/lib/features/dashboard/disk_fixture_contract.dart`
- Allowed tests/fixtures: dedicated `disk_fixture_*` files and `test/fixtures/dashboard/disk/`
- Allowed documentation: this design/plan and implementation evidence.
- Do not modify dashboard repository/controller/page/capabilities, `truenas_api`, persistence, platform, CI, or generated schema.
- Do not call TrueNAS or add `disk.query` to a runtime literal.

## A/E/X matrix

| Case | Expected |
|---|---|
| A: matching family marker, exact root/record shape, 1–128 safe records | complete immutable aggregate |
| E: valid envelope with safe record plus malformed/unknown/over-bound record | partial aggregate retaining only safe records |
| X: unknown family, mismatched marker, malformed/duplicate-key JSON, no safe records, or encoded/value limit | fixed rejected result, no snapshot |
| X: advertised `disk.query` or fixture contract import from production runtime | disks remain disabled and no request is possible |

## Task 1 — Define typed aggregate API

**Files:** create contract and focused test.

1. Write compile-failing tests for `DiskFixtureContract`, status/rejection enums, media/membership enums, scalar-only snapshot fields, constants `128/512/32/32768/16-depth`, and `isRuntimeEnabled == false`.
2. Run `fvm flutter test test/features/dashboard/disk_fixture_contract_test.dart`; expect missing-type RED.
3. Implement immutable result and scalar snapshot types. Result must expose snapshot XOR rejection.
4. Run focused test and analyzer.
5. Commit `feat(storage): define Disk fixture types`.

## Task 2 — Implement version-bound exact-shape decoding

**Files:** contract, focused test, three JSON fixtures.

1. Add family fixtures with exact markers and one `{media, membership}` record.
2. Test all three selectors, cross-family mismatch before an untouchable disk list, enum mappings, and deterministic aggregate counts.
3. Implement family-owned marker and lookup tables. Root must contain exactly `contract` and `disks`; record exactly `media` and `membership`.
4. `ROTATIONAL` maps rotational; `UNCLASSIFIED` maps unclassified. Membership maps `ASSIGNED`, `UNASSIGNED`, or `UNKNOWN`; arbitrary values invalidate the record.
5. Run focused suite and commit `feat(storage): decode versioned Disk fixtures`.

## Task 3 — Implement complete/partial/rejected semantics

1. RED tests: valid+malformed, valid+unknown enum, all malformed, empty list, malformed root/list, unknown root key, unknown record key.
2. Implement local record invalidation and fixed rejection reasons. Never include key/value/index/error text.
3. Verify complete only with no discarded attempted record; partial only with at least one retained record; rejected when none remain.
4. Run focused suite and commit `test(storage): enforce Disk fixture outcomes`.

## Task 4 — Enforce local and global traversal bounds

1. RED tests at 128/129 records and encoded input units 32768/32769.
2. Reject arbitrary custom `Map`/`List` inputs without member access.
3. Reject duplicate JSON root/record keys and malformed JSON before typed decoding.
4. Enforce values/entries 512/513 after decoding. JSON removes alias/cycle and custom collection execution from the parser boundary.
5. Run focused suite/analyzer and commit `fix(storage): bound Disk fixture traversal`.

## Task 5 — Enforce positive-schema and Unicode safety

1. Matrix every admitted field and representative unknown key/value with credentials, JWT/AWS, endpoint/host/account/request ID, UUID/GUID incl. nil/v7, IPv4/IPv6, serial/LUN/WWN, device/model/vendor/enclosure/slot/pool, `passwords`, `pools`, `extra`, SED/SMART.
2. Test 32 units accepted and 33 invalidates only its record when a safe record remains.
3. Test malformed surrogate, controls, bidi, visually blank, and all 4,174 Unicode 17 default-ignorable code points.
4. Use exact keys and fixed token lookup as primary boundary. Validate raw strings before normalization. Unknown keys invalidate the record.
5. Run focused suite and commit `test(storage): reject unsafe Disk fixture data`.

## Task 6 — Prove immutability and runtime exclusion

1. Test source mutation cannot affect scalar snapshot and input order cannot affect aggregates.
2. Add behavioral `disk_fixture_runtime_boundary_test.dart` proving disks remain disabled and allowed methods remain the six-method intersection. Prove import/path/UI/session/admission exclusions through repository-level diff and search commands rather than reading source text from a unit test.
3. Run focused tests and commit `test(storage): keep Disk contract fixture-only`.

## Task 7 — Evidence and full verification

1. Write `M3_DISK_FIXTURE_CONTRACT_IMPLEMENTATION_EVIDENCE.md` with actual RED/GREEN results, bounds, source facts, and no-live/no-runtime boundary.
2. Run:

```sh
fvm dart format --output=none --set-exit-if-changed packages/truenas_api packages/truedash_design_system examples/design_system_consumer apps/truedash
(cd apps/truedash && fvm flutter analyze && fvm flutter test && fvm flutter build web --release)
(cd packages/truenas_api && fvm dart analyze && fvm dart test)
(cd packages/truedash_design_system && fvm flutter analyze && fvm flutter test)
(cd examples/design_system_consumer && fvm flutter analyze && fvm flutter test)
(cd apps/truedash && ./tool/verify_drift_generated.sh && ./tool/verify_drift_generated.sh)
(cd apps/truedash && fvm dart run tool/verify_drift_web_assets.dart)
(cd apps/truedash && fvm dart run tool/verify_persistence_security_boundaries.dart)
git diff --check
```

3. Verify prohibited paths have no diff from base and production contract has no runtime RPC call/literal.
4. Commit evidence.
5. Obtain exact-SHA specification and security reviews. Findings require RED remediation, full rerun, new commit, and both reviews again.
6. After both approve: push exact branch, verify branch pipeline, create Draft MR targeting `feat/m3-vdev-fixture-contract`, verify MR pipeline. Do not merge, deploy, or mutate NAS.
