# M3-1 Storage/Datasets read-only implementation plan

> Scope: strengthen the existing Storage destination using only `pool.query` and `pool.dataset.query`. This plan does not authorize new RPCs, mutations, live NAS changes, or full M3 completion.

## Acceptance criteria

1. Storage data remains session-scoped and read-only.
2. Runtime RPC surface remains exactly the existing bounded allowlist; M3-1 invokes only `pool.query` and `pool.dataset.query`.
3. Pool and dataset payloads are normalized into bounded typed presentation models; raw payloads are not retained or rendered.
4. Pools and datasets have deterministic ordering.
5. Datasets are grouped by their derived root pool where possible; orphan/ambiguous items remain visible without inventing relationships.
6. Pool cards show bounded health and capacity data already admitted by the current contract.
7. The UI distinguishes complete inventory, partial inventory, empty inventory, unsupported inventory, and total query failure.
8. VDEVs, disks, snapshots, ACLs, and all mutations remain explicitly unavailable.
9. Narrow-width UI has no overflow and exposed controls/sections have usable semantics.
10. Focused and repository-wide verification passes with `fvm` tooling.

## Safety invariants

- Do not add any method to `DashboardCapabilities._boundedMethods`.
- Do not invoke `disk.query`, `pool.snapshot.query`, `pool.dataset.get_instance`, VDEV methods, filesystem methods, sharing methods, shell methods, or job-creating methods.
- Do not add create/update/delete/unlock/export/import operations.
- Do not persist API response maps, credentials, dataset properties, mount paths, ACL data, or raw error details.
- Preserve independent failure handling: a successful pool response remains useful if datasets fail, and vice versa.
- Keep parser limits at or below existing display bounds (50 records, 160 display characters).

## Task 1 — Specify deterministic bounded storage models

**Files**
- Modify: `apps/truenavo/test/features/dashboard/dashboard_controller_test.dart`
- Modify: `apps/truenavo/lib/features/dashboard/dashboard_repository.dart`

**RED**

Add focused repository tests proving:

- pools sort by normalized name rather than server response order;
- datasets sort by pool then full name;
- dataset root-pool derivation handles `tank/media`, a top-level `tank`, blank names, and unknown pool names without false attribution;
- malformed maps/scalars are ignored safely;
- record counts and strings remain bounded;
- capacity accepts existing admitted fields only and clamps display percentage;
- partial query failure preserves the successful side and exposes availability flags.

Run:

```bash
cd apps/truenavo
fvm flutter test test/features/dashboard/dashboard_controller_test.dart
```

Confirm new assertions fail for the missing deterministic/grouped behavior rather than a test setup error.

**GREEN**

Make the smallest production changes required:

- retain typed `DashboardPool` and `DashboardDataset` values only;
- add deterministic sort/group metadata as immutable computed values;
- preserve existing parsing bounds and safe unknown fallbacks;
- do not broaden accepted response fields beyond what the current repository already reads unless a test documents a bounded, non-sensitive presentation field.

Re-run the focused test and confirm it passes.

## Task 2 — Specify Storage summary and grouped rendering

**Files**
- Modify: `apps/truenavo/test/features/dashboard/dashboard_page_test.dart`
- Modify: `apps/truenavo/lib/features/dashboard/dashboard_page.dart`

**RED**

Add widget tests for:

- a complete response renders pool summary, health/capacity, and datasets grouped under matching pools;
- orphan datasets remain visible in an `Other datasets` group;
- pool-only and dataset-only partial responses display a concise partial-inventory notice;
- supported empty lists display an empty state, not an unsupported state;
- unsupported VDEV/disk/snapshot/ACL sections remain visible and clearly read-only/unavailable;
- 320 px and 1440 px viewports do not overflow with long bounded names/statuses;
- section labels and the Refresh action are discoverable through Flutter semantics.

Run:

```bash
cd apps/truenavo
fvm flutter test test/features/dashboard/dashboard_page_test.dart
```

The committed widget suite is the deterministic responsive gate. An
authenticated production-browser pass is recorded separately when a valid,
authorized TrueNAS session is available; it is not inferred from an
unauthenticated shell or from a failed credential attempt.

Confirm failures describe the missing UI behavior.

**GREEN**

Implement the minimum UI needed:

- compact summary metrics derived from typed data;
- deterministic pool sections with status badge, capacity indicator when known, and matching dataset rows;
- explicit complete/partial/empty/unsupported copy;
- no interactive mutation affordances;
- responsive wrapping rather than fixed-width assumptions;
- semantic section labels and existing refresh behavior.

Re-run the focused widget test and confirm it passes.

## Task 3 — Refactor while preserving closed capabilities

**Files**
- Modify only if needed: `apps/truenavo/lib/features/dashboard/dashboard_repository.dart`
- Modify only if needed: `apps/truenavo/lib/features/dashboard/dashboard_page.dart`
- Verify unchanged authority: `apps/truenavo/lib/features/dashboard/dashboard_capabilities.dart`

After both focused suites are green:

- remove duplicated presentation helpers;
- keep grouping and formatting pure and deterministic;
- ensure no raw response object crosses the repository boundary;
- assert in tests that called methods remain exactly `pool.query` and `pool.dataset.query`;
- inspect the diff for accidental allowlist, session, persistence, or navigation changes.

## Task 4 — Focused verification

From `apps/truenavo`:

```bash
fvm dart format --output=none --set-exit-if-changed \
  lib/features/dashboard/dashboard_repository.dart \
  lib/features/dashboard/dashboard_page.dart \
  test/features/dashboard/dashboard_controller_test.dart \
  test/features/dashboard/dashboard_page_test.dart
fvm flutter analyze
fvm flutter test test/features/dashboard/dashboard_controller_test.dart
fvm flutter test test/features/dashboard/dashboard_page_test.dart
```

Also run from the repository root:

```bash
git diff --check
git diff -- apps/truenavo/lib/features/dashboard/dashboard_capabilities.dart
```

The capability diff must be empty.

## Task 5 — Repository-wide verification

Use repository scripts/commands already established by the project. At minimum:

```bash
cd apps/truenavo
fvm flutter test
fvm flutter build web --release

cd ../../packages/truenas_api
fvm dart analyze
fvm dart test

cd ../truenavo_design_system
fvm flutter analyze
fvm flutter test
```

Run any root-level generated-artifact, Drift schema, external consumer, or formatting checks required by repository documentation/CI. Confirm the Web release contains required persistence assets and finish with `git diff --check`.

## Task 6 — Independent review and evidence

Before committing implementation:

1. Review the exact diff against this plan and `M3_STORAGE_READONLY_DESIGN.md`.
2. Confirm only the two approved read-only RPCs are called by Storage.
3. Confirm capabilities for VDEV, disk, snapshot, apps, and mutations remain closed.
4. Record RED/GREEN commands and final verification evidence in `docs/planning/M3_STORAGE_READONLY_IMPLEMENTATION_EVIDENCE.md`.
5. Commit only after fresh verification passes.

## Explicitly deferred

- Live TrueNAS E2E remains blocked until valid credentials authenticate; the previously supplied key produced `AUTH_ERR` and is not evidence of interoperability.
- VDEV topology, disk inventory, snapshots, ACLs, dataset property expansion, and any storage mutation require separate contracts, admission evidence, RBAC design, and dedicated follow-up milestones.
