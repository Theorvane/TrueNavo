# M3-1 Storage/Datasets read-only implementation evidence

> Candidate branch: `feat/m3-storage-readonly`
>
> Scope: bounded Storage/Datasets presentation over the already-admitted `pool.query` and `pool.dataset.query` methods. This evidence does not claim complete M3 parity or successful live TrueNAS interoperability.

## Delivered behavior

- Storage summarizes the number of displayed pools and datasets.
- Pools are normalized and sorted deterministically.
- Datasets are sorted by known pool context and name, grouped under a pool only when the identity is unambiguous, and otherwise remain visible under `Other datasets`.
- Complete, partial, supported-empty, unsupported, and total-failure states remain distinct.
- Pool health/capacity presentation remains bounded to existing admitted fields.
- Dataset rows expose a minimum 44 px target and safe semantics when pool context is unavailable.
- Strings remain display-bounded and malformed records are ignored.
- Pool capacity accepts only finite numeric or strict numeric-percent input;
  arbitrary remote text is discarded.
- Dataset and pool identities over 160 UTF-16 units or containing malformed
  surrogate pairs are rejected instead of lossy truncation.
- Duplicate normalized pool identities are treated as ambiguous, so associated
  datasets remain visible under `Other datasets` rather than being duplicated.
- A malformed top-level response is rejected as a failed section rather than misrepresented as an empty successful inventory.
- VDEV, disk, snapshot, ACL, and mutation surfaces remain explicitly unavailable.

## RPC and data boundary

- `apps/truedash/lib/features/dashboard/dashboard_capabilities.dart` has no diff.
- Storage still requests only `pool.query` and `pool.dataset.query` through `_optionalList`.
- No disk, snapshot, filesystem, sharing, shell, or mutation RPC literal was added to the dashboard runtime.
- Raw response maps are consumed during parsing and do not cross the repository boundary or enter persistence.
- No credential, endpoint, TLS, session, persistence, package, generated-schema, or platform file changed.

## TDD evidence

### Initial repository RED

Command:

```bash
cd apps/truedash
fvm flutter test test/features/dashboard/dashboard_controller_test.dart
```

Expected failures observed:

- deterministic pool ordering expected `Alpha, zeta` but received server order plus a malformed fallback pool;
- dataset-only inventory incorrectly invented `tank` as known pool context.

After the minimal parser/reconciliation implementation, the focused repository suite passed.

### Initial widget RED

Command:

```bash
cd apps/truedash
fvm flutter test test/features/dashboard/dashboard_page_test.dart
```

Expected failures observed:

- no `1 pool` / `2 datasets` summary;
- no grouped `Datasets in tank` / `Other datasets` presentation;
- no `Partial inventory` state.

After the minimal rendering implementation, the focused widget suite passed.

### Truncation-collision RED

Command:

```bash
fvm flutter test test/features/dashboard/dashboard_controller_test.dart \
  --plain-name 'does not attribute a dataset through a truncated pool-name collision'
```

The test failed because distinct overlong names collapsed to the same 160-character display value. The parser now refuses to use overlong root identities for attribution.

### Independent review RED findings

A read-only independent reviewer reproduced four blocking cases against an isolated copy:

1. malformed top-level map/scalar payloads were treated as available empty lists;
2. an actual dataset root ending in `…` could collide with a truncated pool display name;
3. surrounding pool-name whitespace prevented otherwise valid grouping;
4. an orphan dataset `InkWell` measured 22 px high.

Regression commands reproduced the same failures in the implementation worktree:

```bash
fvm flutter test test/features/dashboard/dashboard_controller_test.dart \
  --plain-name 'rejects malformed top-level storage payloads'
fvm flutter test test/features/dashboard/dashboard_controller_test.dart \
  --plain-name 'does not group through a literal ellipsis display collision'
fvm flutter test test/features/dashboard/dashboard_controller_test.dart \
  --plain-name 'trims pool identity before deterministic dataset grouping'
fvm flutter test test/features/dashboard/dashboard_page_test.dart \
  --plain-name 'storage groups known datasets and keeps orphans visible'
```

Observed failures matched the intended regressions: `DashboardData` instead of `DashboardFailure`, non-empty incorrect pool attribution, untrimmed ` tank `, and a 22 px target instead of at least 44 px.

A second read-only review after those fixes found no blocker, confirmed that the capability file remained unchanged, and confirmed the focused 42 tests passed. It reported one Medium issue: the parsers scanned beyond 50 malformed records while searching for 50 valid records. A regression named `bounds storage parsing to the first 50 response records` failed because a valid record at index 50 was accepted. Both parsers now inspect only `value.take(50)`; the regression passes.

### Final focused GREEN

```bash
cd apps/truedash
fvm flutter test test/features/dashboard/dashboard_controller_test.dart
# 33 tests passed

fvm flutter test test/features/dashboard/dashboard_page_test.dart
# 15 tests passed
```

The widget suite includes real 320 x 900 and 1440 x 1200 surface checks,
long-content, supported-empty and partial-state checks, semantics verification,
the static ACL-unavailable notice, and the 44 px dataset target assertion.

## Final repository verification

### Formatting

```bash
fvm dart format --output=none --set-exit-if-changed \
  packages/truenas_api packages/truedash_design_system \
  examples/design_system_consumer apps/truedash
```

Result: 142 files checked, 0 changed.

### App

```bash
cd apps/truedash
fvm flutter analyze
fvm flutter test
fvm flutter build web --release
test -f build/web/sqlite3.wasm
test -f build/web/drift_worker.js
```

Results:

- analyze: no issues;
- full app suite: 510 tests passed, 1 existing skip;
- Web release build: succeeded;
- `sqlite3.wasm` and `drift_worker.js`: present.

The build emitted the existing non-fatal Cupertino icon font warning and a WebAssembly dry-run recommendation.

### API package

```bash
cd packages/truenas_api
fvm dart analyze
fvm dart test
```

Results:

- 64 tests passed;
- analyze completed with 2 pre-existing info-level findings in unchanged files (`curly_braces_in_flow_control_structures` and `prefer_initializing_formals`).

### Design system and external consumer

```bash
cd packages/truedash_design_system
fvm flutter analyze
fvm flutter test
# no issues; 27 tests passed

cd examples/design_system_consumer
fvm flutter analyze
fvm flutter test
# no issues; 1 test passed
```

### Drift and security gates

```bash
cd apps/truedash
./tool/verify_drift_generated.sh
./tool/verify_drift_generated.sh
fvm dart run tool/verify_drift_web_assets.dart
fvm dart run tool/verify_persistence_security_boundaries.dart
```

Result: all commands passed; repeated generation left no generated diff.

### Diff integrity

```bash
git diff --check
git diff -- apps/truedash/lib/features/dashboard/dashboard_capabilities.dart
```

Result: clean whitespace; capability diff empty.

## Exact-SHA review remediation

The first exact-SHA review of `73e7cdcbadc15bde7696d29f15a041eb7030866e`
was rejected. Focused RED tests reproduced arbitrary capacity text retention,
lossy dataset identity truncation, duplicate pool attribution, the missing ACL
notice, and missing committed 1440 px coverage. Production changes then made
those tests GREEN by enforcing a positive capacity grammar, rejecting unsafe
identities, treating duplicate pool identities as ambiguous, adding the static
ACL notice, and adding a desktop-width render test. Unknown pool status text is
also normalized to a fixed `Unknown` label rather than retained.

## Live verification limitation

The production Web artifact was built, and the changed Storage surface was
exercised through committed Flutter rendering tests at 320 px and 1440 px. A
browser inspection of the authenticated Storage route was not possible because
the previously supplied TrueNAS credential returns `AUTH_ERR`; the
unauthenticated production app cannot enter that route. Per the clarified design
boundary, authenticated production-browser QA is a separate live-interoperability
gate and remains deferred. No NAS mutation or additional credential attempt was
performed. Live TrueNAS interoperability remains explicitly unproven.

## Tooling note

Codex CLI was invoked first in the approved isolated worktree with `--sandbox workspace-write`, but both WebSocket and HTTPS transports returned `401 Unauthorized` before any file change. Implementation was therefore completed directly under the same bounded plan, with RED/GREEN evidence and independent review. Codex output was not treated as implementation or verification evidence.
