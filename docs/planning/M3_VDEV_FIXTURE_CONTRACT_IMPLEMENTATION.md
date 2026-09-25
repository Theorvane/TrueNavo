# M3-2 VDEV Fixture Contract Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Build a version-explicit, fixture-only, runtime-disabled VDEV topology decoder that returns only immutable bounded enums and derived counts.

**Architecture:** Add an isolated `vdev_fixture_contract.dart` module beside the existing deferred dashboard contracts. It accepts only static fixture objects, selects an explicit parser for each supported version family, validates a positive schema with identity-based traversal guards, and returns complete/partial/rejected typed outcomes. No production repository, controller, provider, UI, transport, capability, persistence, or platform code may depend on this module.

**Tech Stack:** Dart 3.13, Flutter test, FVM, immutable Dart value objects, identity sets, fixture-driven TDD.

---

## Invariants for every task

- Worktree: `/Users/jungwon/workspace/.worktrees/trueraid-m3-vdev-contract`
- Branch: `feat/m3-vdev-fixture-contract`
- Base: `1d152e339d0374d87e492e565c6b2c1a1a713834`
- Use `fvm dart` and `fvm flutter`; never invoke bare `dart` or `flutter`.
- Do not add a runtime RPC, provider, route, persistence field, generated schema, UI, or live test.
- Do not modify:
  - `packages/truenas_api/lib/src/session/true_nas_session_repository.dart`
  - `apps/trueraid/lib/features/dashboard/dashboard_capabilities.dart`
  - `apps/trueraid/lib/features/dashboard/dashboard_repository.dart`
  - `apps/trueraid/lib/features/dashboard/dashboard_controller.dart`
  - `apps/trueraid/lib/features/dashboard/dashboard_page.dart`
- Fixture values must not appear in exceptions, rejection values, logs, or typed output unless represented by a fixed local enum.
- Commit each coherent task only after its focused tests and `git diff --check` pass.

## A/E/X contract

| Case | Input | Expected |
|---|---|---|
| A — admitted fixture shape | Known version family, reviewed envelope, safe bounded topology | Complete immutable typed snapshot |
| E — expected partial fixture | Valid envelope with at least one valid node and local malformed/over-bound entries | Partial immutable snapshot; no rejected values retained |
| X — excluded fixture | Unknown version, malformed envelope, duplicate/unknown group, global traversal breach, cycle/shared container, or no safe node | Fixed rejected result; no snapshot and no runtime capability |
| X — runtime | Any advertised method or live session | No invocation; existing capability and allowlist remain unchanged |

### Task 1: Define typed result and topology values

**Objective:** Introduce the public fixture-only types and constants without implementing decoding.

**Files:**
- Create: `apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart`
- Create: `apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart`

**Step 1: Write failing API-shape tests**

Add tests that instantiate or reference:

```dart
VdevFixtureContract.select(DashboardVersionFamily.v25_10)
VdevFixtureStatus.complete
VdevFixtureRejectionReason.unsupportedVersion
VdevTopologyGroupKind.data
VdevOperationalStatus.online
```

Assert:

- known families select a fixture-only contract;
- unknown family immediately returns a rejected parse result;
- `isRuntimeEnabled` is always false;
- bounds equal depth 8, children 32, nodes 512, maps 1024, lists 256,
  visited values 2048, and string units 64;
- result types expose either a snapshot or a fixed rejection, never both.

**Step 2: Run RED**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
```

Expected: compile failure because the new types do not exist.

**Step 3: Add minimal typed API**

Implement fixed enums and immutable classes:

```dart
enum VdevFixtureStatus { complete, partial, rejected }
enum VdevFixtureRejectionReason {
  unsupportedVersion,
  malformedEnvelope,
  duplicateOrUnknownGroup,
  traversalLimitExceeded,
  sharedContainer,
  noSafeObservation,
}
enum VdevTopologyGroupKind { data, spare, cache, log, special, dedup }
enum VdevOperationalStatus {
  online,
  degraded,
  faulted,
  offline,
  unavailable,
  unknown,
}
```

`VdevTopologyNode` contains only `status`, immutable `children`, and a derived `deviceCount`; `VdevTopologyGroup` contains only `kind` and immutable roots; `VdevTopologySnapshot` contains version family, immutable groups, derived node count, and partial flag. `VdevFixtureResult` enforces the snapshot/rejection exclusive state.

**Step 4: Run GREEN and analyzer**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
fvm flutter analyze
```

Expected: focused tests pass and analyzer reports no issues.

**Step 5: Commit**

```sh
git add apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart
git commit -m "feat(storage): define VDEV fixture types"
```

### Task 2: Decode one minimal safe topology per version family

**Objective:** Prove all supported version families have explicit selectors and positive-schema decoding.

**Files:**
- Modify: `apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart`
- Modify: `apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart`
- Create: `apps/trueraid/test/fixtures/dashboard/vdev/v25_04_minimal.json`
- Create: `apps/trueraid/test/fixtures/dashboard/vdev/v25_10_minimal.json`
- Create: `apps/trueraid/test/fixtures/dashboard/vdev/v26_plus_minimal.json`

**Step 1: Write failing per-version fixture tests**

Fixtures must use synthetic, identifier-free data and contain a single data group with one branch and two anonymous leaves. Tests assert:

- all three families decode through independent selector branches;
- result is complete;
- group kind is `data`;
- status is normalized from a version-specific documented token;
- `deviceCount == 2` and derived `nodeCount` is deterministic;
- no string from an unknown field enters the result.
- each fixture carries its family-specific local contract marker and is rejected
  by the other two family selectors.

**Step 2: Run RED**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart \
  --plain-name "decodes minimal topology for every supported family"
```

Expected: failure because decoding is not implemented.

**Step 3: Implement explicit version selectors**

Implement three private decoding entry points. They may share only validated primitive helpers. Each accepts exactly one root envelope with a topology object. Group keys map through the fixed group enum. Node type and status map through per-family fixed tables. Unknown keys are traversed only for safety validation and never retained.

**Step 4: Run GREEN**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
```

Expected: per-version fixtures pass.

**Step 5: Commit**

```sh
git add apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart \
  apps/trueraid/test/fixtures/dashboard/vdev
git commit -m "feat(storage): decode versioned VDEV fixtures"
```

### Task 3: Enforce deterministic group and status contracts

**Objective:** Cover all group/status enums and complete-versus-rejected schema behavior.

**Files:**
- Modify: `apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart`
- Modify: `apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart`

**Step 1: Write failing tests**

Test:

- all six group kinds return in enum order regardless of fixture key order;
- every allowed status token maps to a fixed enum;
- absent optional status maps to `unknown`;
- arbitrary status text rejects only that node and yields partial when another safe node remains;
- duplicate logical groups and unknown group keys reject the whole fixture;
- an empty safe result rejects with `noSafeObservation`.

**Step 2: Run RED**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart \
  --plain-name "normalizes deterministic VDEV groups and states"
```

Expected: assertions fail on missing ordering and outcome logic.

**Step 3: Implement minimal normalization**

Use fixed maps and enum-order reconstruction. Never use arbitrary source strings for sorting, output, or rejection details.

**Step 4: Run GREEN**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
```

**Step 5: Commit**

```sh
git add apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart
git commit -m "test(storage): enforce VDEV fixture enums"
```

### Task 4: Enforce local width, depth, and retained-node bounds

**Objective:** Make local malformed or over-bound nodes yield a bounded partial snapshot when safe data remains.

**Files:**
- Modify: `apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart`
- Modify: `apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart`

**Step 1: Write boundary RED tests**

Add generated in-memory fixtures for:

- 32 and 33 roots;
- 32 and 33 children;
- depth 8 and 9;
- retained nodes 512 and 513;
- malformed node before and after a valid node;
- first-positions accounting so invalid prefixes cannot force scanning beyond 32 attempted children.

Expected rules:

- exact limit is accepted;
- one beyond a local limit returns partial if at least one safe node remains;
- traversal stops at the first exhausted retained-node budget;
- rejected content and its indexes/counts are not returned.

**Step 2: Run RED**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart \
  --plain-name "enforces VDEV local traversal bounds"
```

**Step 3: Implement bounded traversal**

Use an explicit traversal context with retained node count and partial flag. Apply `.take(maxAttemptedPositions)` before validating elements. Keep recursion strictly capped at depth 8 or use a stack.

**Step 4: Run GREEN and analyzer**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
fvm flutter analyze
```

**Step 5: Commit**

```sh
git add apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart
git commit -m "feat(storage): bound VDEV fixture traversal"
```

### Task 5: Enforce global traversal and shared-container guards

**Objective:** Bound hostile fixture cost and reject cycle-like or aliased container graphs.

**Files:**
- Modify: `apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart`
- Modify: `apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart`

**Step 1: Write failing adversarial tests**

Cover:

- 1024 and 1025 visited maps;
- 256 and 257 visited lists;
- a map that references itself;
- a list that references itself;
- the same child map in two positions;
- the same children list used by two nodes;
- a lazy/hostile Map whose entries must not be read after its reported bound already exceeds the limit.

Expected: exact global limits are accepted when otherwise safe; one beyond rejects with `traversalLimitExceeded`; shared/cyclic identity rejects with `sharedContainer`.

**Step 2: Run RED**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart \
  --plain-name "rejects hostile and shared fixture containers"
```

**Step 3: Implement identity traversal context**

Track maps and lists in `HashSet.identity()`. Count every visited container before reading entries. Convert internal exceptions only to fixed public rejection enums.

**Step 4: Run GREEN**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
```

**Step 5: Commit**

```sh
git add apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart
git commit -m "fix(storage): contain VDEV fixture graphs"
```

### Task 6: Reject sensitive, identifier, and unsafe Unicode values

**Objective:** Prove no secret-shaped, device-identifying, control, invisible, malformed, or overlong string crosses the fixture boundary.

**Files:**
- Modify: `apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart`
- Modify: `apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart`

**Step 1: Write failing matrix tests**

Place hostile values in every admitted string-bearing field and representative unknown fields:

- bearer/basic authorization, API key, password, cookie, JWT-like, AWS-key-like;
- endpoint, host, account, request ID;
- serial, GUID, WWN, device path/name, enclosure slot;
- 65 UTF-16 units;
- malformed surrogate pair;
- C0/C1 controls and boundary controls before trimming;
- bidi formatting controls;
- every Unicode 17.0 `Default_Ignorable_Code_Point` range, including supplementary tags/variation selectors;
- whitespace/default-ignorable-only values.

Also test a valid paired emoji in an ignored unknown field does not enter output and does not invalidate an otherwise safe fixture unless the positive-schema safety traversal forbids arbitrary strings there. Choose one rule and assert it consistently; the implementation plan selects fail-closed validation of every encountered string.

**Step 2: Run RED**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart \
  --plain-name "rejects sensitive and unsafe fixture strings"
```

**Step 3: Implement a fixture string gate**

Use fixed enum lookups for admitted strings and a general fail-closed validator for every encountered string. Reuse or extract the complete Unicode default-ignorable ranges proven by M3-1 without introducing a runtime dependency. Never include the rejected value in an exception or result.

**Step 4: Run GREEN**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart
```

**Step 5: Commit**

```sh
git add apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart
git commit -m "test(storage): reject unsafe VDEV fixture data"
```

### Task 7: Prove immutable snapshots and runtime exclusion

**Objective:** Lock the fixture-only boundary against mutation and accidental production wiring.

**Files:**
- Modify: `apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart`
- Create: `apps/trueraid/test/features/dashboard/vdev_fixture_runtime_boundary_test.dart`

**Step 1: Write failing tests**

Test that:

- mutating every source map/list after parse cannot alter groups, nodes, statuses, node count, or device count;
- returned group/root/children lists throw on mutation;
- `DashboardCapabilities` never supports VDEVs;
- the session read-only method set remains the exact six methods;
- source scans show no import/reference to `vdev_fixture_contract.dart` from production repository/controller/page/provider files;
- Storage still shows the static VDEV/disk unavailable notice;
- `DeferredAdmissionRecord.apiCapabilityEnabled` remains false.

**Step 2: Run RED**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart \
  test/features/dashboard/vdev_fixture_runtime_boundary_test.dart
```

Expected: immutable or boundary assertions expose any missing safeguards.

**Step 3: Apply minimal hardening**

Copy every retained collection with `List.unmodifiable`. Add no production integration. If runtime boundary tests already pass, record that no production change was required.

**Step 4: Run GREEN**

```sh
cd apps/trueraid
fvm flutter test test/features/dashboard/vdev_fixture_contract_test.dart \
  test/features/dashboard/vdev_fixture_runtime_boundary_test.dart
```

**Step 5: Commit**

```sh
git add apps/trueraid/lib/features/dashboard/vdev_fixture_contract.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_contract_test.dart \
  apps/trueraid/test/features/dashboard/vdev_fixture_runtime_boundary_test.dart
git commit -m "test(storage): keep VDEV contract fixture-only"
```

### Task 8: Write evidence and run the full candidate gate

**Objective:** Produce honest implementation evidence and verify the complete stacked candidate.

**Files:**
- Create: `docs/planning/M3_VDEV_FIXTURE_CONTRACT_IMPLEMENTATION_EVIDENCE.md`

**Step 1: Write evidence**

Record:

- exact base and candidate SHA;
- focused RED commands and actual failure reasons;
- focused GREEN counts;
- complete/partial/rejected behavior;
- all bounds and Unicode property coverage;
- runtime/capability/allowlist unchanged checks;
- explicit statement that no live request, UI activation, or NAS mutation occurred;
- Codex result, if attempted, without treating self-report as evidence.

**Step 2: Run complete verification**

```sh
fvm dart format --output=none --set-exit-if-changed \
  packages/truenas_api packages/trueraid_design_system \
  examples/design_system_consumer apps/trueraid

(cd apps/trueraid && fvm flutter analyze)
(cd apps/trueraid && fvm flutter test)
(cd apps/trueraid && fvm flutter build web --release)
(cd packages/truenas_api && fvm dart analyze && fvm dart test)
(cd packages/trueraid_design_system && fvm flutter analyze && fvm flutter test)
(cd examples/design_system_consumer && fvm flutter analyze && fvm flutter test)
(cd apps/trueraid && ./tool/verify_drift_generated.sh)
(cd apps/trueraid && ./tool/verify_drift_generated.sh)
(cd apps/trueraid && fvm dart run tool/verify_drift_web_assets.dart)
(cd apps/trueraid && fvm dart run tool/verify_persistence_security_boundaries.dart)
git diff --check
```

**Step 3: Verify prohibited diffs**

```sh
git diff --exit-code 1d152e339d0374d87e492e565c6b2c1a1a713834...HEAD -- \
  packages/truenas_api/lib/src/session/true_nas_session_repository.dart \
  apps/trueraid/lib/features/dashboard/dashboard_capabilities.dart \
  apps/trueraid/lib/features/dashboard/dashboard_repository.dart \
  apps/trueraid/lib/features/dashboard/dashboard_controller.dart \
  apps/trueraid/lib/features/dashboard/dashboard_page.dart
```

Expected: exit 0 and no output.

Scan changed production source for RPC literals and ensure none exist.

**Step 4: Commit evidence**

```sh
git add docs/planning/M3_VDEV_FIXTURE_CONTRACT_IMPLEMENTATION_EVIDENCE.md
git commit -m "docs(storage): record VDEV fixture evidence"
```

**Step 5: Exact-SHA review gate**

Request independent specification and code-quality/security reviews against the final immutable SHA. Any finding requires a focused RED test, remediation commit, complete verification, and both reviews repeated at the new SHA. Do not push, create an MR, or begin runtime admission while reviews are pending.
