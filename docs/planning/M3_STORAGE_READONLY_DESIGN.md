# M3-1 Storage/Datasets read-only design

> Status: approved design for the first bounded M3 delivery. This document does not claim complete M3 parity, live TrueNAS interoperability, or authority to mutate a NAS.

## Goal

Improve the existing TrueDash Storage destination using only the already-admitted, parameterless read-only methods:

- `pool.query`
- `pool.dataset.query`

The screen must make pool and dataset inventory easier to assess while remaining fail-closed when a server returns malformed, oversized, partial, or unavailable data.

## Scope

### Included

1. A typed, bounded projection for the existing pool and dataset response shapes.
2. Per-pool read-only presentation of safe operational state and capacity values already exposed by the current mapping.
3. Dataset grouping under a recognized pool context, deterministic ordering, and an explicit orphan/unknown-pool treatment if the server omits the parent pool from the admitted pool inventory.
4. Explicit states for:
   - both inventories available;
   - pool-only inventory;
   - dataset-only inventory;
   - neither method advertised;
   - safe query failure; and
   - empty inventory.
5. Responsive, accessible Storage UI verification at narrow and desktop widths.
6. Deterministic fixture-driven tests, analyzer, full suite, and Web release build.

### Excluded

- Any new RPC method or parameterized query.
- `disk.query`, VDEV topology rendering, `pool.snapshot.query`, ACL operations, sharing, pool/dataset creation, update, delete, import/export, scrub, resilver control, or any other mutation.
- Raw JSON/maps, server error text, identifiers/serials, credentials, certificates, or endpoint details in rendered UI, state, persistence, fixtures, logs, or evidence.
- A claim of live TrueNAS compatibility until a valid least-privilege API credential and a dedicated E2E environment are available.

## Safety and data boundary

`AuthenticatedSessionQueries.query` remains the runtime boundary and accepts only the fixed six-method allowlist. This slice must not alter that allowlist.

`DashboardRepository` continues to own decoding. It maps only a positive schema of safe scalar fields into immutable `DashboardPool` and `DashboardDataset` values. It must reject malformed rows, cap lists and display strings, and never retain an arbitrary response map. A failed optional inventory does not erase a successfully decoded companion inventory.

The UI consumes typed `DashboardStorage` only. It does not inspect RPC response data, infer a VDEV/disk capability, or use a successful `pool.query` response to expose unadmitted nested topology.

## Components and flow

```text
AuthenticatedSessionQueries (fixed allowlist)
  -> DashboardRepository.loadStorage(methods)
  -> DashboardStorage typed snapshot
  -> DashboardPage Storage destination
```

1. `DashboardController` loads the existing Storage destination using the active session's admitted method intersection.
2. `DashboardRepository` independently loads `pool.query` and `pool.dataset.query` only when each is advertised.
3. Each response is independently bounded and decoded. A safe response yields typed items; a failed optional response becomes unavailable rather than a fabricated empty list.
4. `DashboardStorage` preserves the source-availability flags and typed items.
5. The page renders pool cards first, then datasets grouped by the safe pool-name field. Datasets without a matching visible pool use an honest `Other dataset context` section; the page does not invent a parent relation.
6. VDEV/disk/snapshot/ACL content remains a static, explicit unsupported notice.

## User-visible behavior

- Pool cards show the already-admitted safe name, normalized state/status, and capacity values where they are valid.
- Dataset rows show only safe dataset name and pool context.
- The page differentiates empty data from unavailable inventory and from a failed request.
- Refresh retries the existing Storage load only; it neither reconnects nor alters server state.
- All controls retain semantic names, keyboard access, visible focus, and at least 44px touch targets.
- At 320px and 1440px widths, long safe labels wrap or truncate accessibly without horizontal overflow.

## Error handling

- Unknown or malformed rows are discarded rather than rendered.
- If both admitted inventory calls fail, return the existing safe generic failure state without remote error text.
- If one admitted inventory is unavailable or fails, retain the safe companion inventory and show only a bounded availability message.
- If neither method is admitted, return the existing unavailable state.

## Tests and evidence

### RED/GREEN tests

1. Repository tests for deterministic grouping inputs, orphan dataset handling, malformed row rejection, list/text bounds, partial availability, and no calls outside the two existing methods.
2. Widget tests for grouped/ungrouped, pool-only/dataset-only/empty/failure/unavailable states, semantic labels, refresh, 320px and desktop reflow, and no VDEV/disk/snapshot/ACL data rendering.
3. Regression tests that assert `DashboardCapabilities` and `TrueNasSessionRepository.readOnlyMethods` remain unchanged.

### Required verification

```sh
fvm dart format --output=none --set-exit-if-changed apps/truedash/lib apps/truedash/test
(cd apps/truedash && fvm flutter test test/features/dashboard)
(cd apps/truedash && fvm flutter analyze)
(cd apps/truedash && fvm flutter test)
(cd packages/truenas_api && fvm dart analyze && fvm dart test)
(cd apps/truedash && fvm flutter build web --release)
git diff --check
```

A browser QA matrix is performed only after the final candidate SHA and must inspect the production build at 320px and 1440px. Browser/tool failure must be reported as unavailable verification, not as a passing UI result.

## Acceptance criteria

- [ ] No new runtime RPC method or mutation is added.
- [ ] The existing six-method runtime allowlist is unchanged.
- [ ] Storage remains usable with safe pool-only or dataset-only data.
- [ ] Malformed and oversized storage response rows cannot reach the UI.
- [ ] VDEV, disk, snapshot, and ACL detail remains unavailable at runtime.
- [ ] Focused and full deterministic tests, static analysis, Web release build, and `git diff --check` pass.
- [ ] Any live E2E claim is withheld unless a separately authorized valid credential succeeds.
