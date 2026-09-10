# M3-3 Disk fixture contract implementation evidence

> Branch: `feat/m3-disk-fixture-contract`
> Base: M3-2 reviewed SHA `84405d5fea7222d88621aebb401cfa75d028d3a9`
> Scope: static redacted fixtures only. `disk.query`, Disk UI, live appliance access,
> credential use, persistence, and NAS mutation remain disabled.

## Delivered behavior

- Explicit markers bind fixtures to `25.04`, `25.10`, and `26+` before the
  `disks` collection is touched.
- Exact root shape is `{contract, disks}`.
- Exact record shape is `{media, membership}`.
- `ROTATIONAL` and `UNCLASSIFIED` are the only media inputs.
- `ASSIGNED`, `UNASSIGNED`, and `UNKNOWN` are the only membership inputs.
- Output retains no record, label, identifier, or source order; it contains only
  version family, six derived scalar counts, and a partial flag.
- `UNCLASSIFIED` deliberately combines SSD and unknown. No SSD claim is made.
- Complete, partial, and rejected results are mutually exclusive and use fixed
  local rejection enums.

## Bounds and adversarial behavior

| Boundary | Limit | Verified behavior |
|---|---:|---|
| Attempted/retained records | 128 | 128 complete; 129 and billion-length tail partial without indexing tail |
| Maps | 256 | fixed global counter |
| Lists | 16 | fixed global counter |
| Values/entries | 512 | deceptive record map rejects at limit |
| String | 32 UTF-16 units | 33 invalidates only containing record |

- Repeated record map identity rejects with `sharedContainer`.
- A deceptive `MapBase` reporting two entries but yielding 513 terminates and
  rejects with `traversalLimitExceeded`.
- Source maps/lists can be mutated after parse without changing aggregate output.
- Aggregate output is independent of fixture order.

## Positive-schema safety

Exact-shape tests invalidate records containing identifier, name, number,
serial, LUN ID, model/vendor, bus, device path/name, ZFS GUID, WWN,
enclosure/slot, pool, description, transfer mode, password(s), query `pools` or
`extra`, SED, or SMART fields.

Admitted token fields reject malformed surrogates, controls, bidi, visually
blank strings, and the complete 4,174-code-point Unicode 17
`Default_Ignorable_Code_Point` set. Arbitrary enum strings never enter output.

## Runtime exclusion

Dedicated tests prove:

- `DiskFixtureContract.isRuntimeEnabled` is always false;
- disks remain disabled in `DashboardCapabilities`;
- the authenticated session retains the exact six-method allowlist and excludes
  `disk.query`;
- dashboard repository/controller/page/capabilities do not import the contract;
- the Storage page retains `VDEVs and disks unavailable`; and
- deferred admission/evidence still expose `apiCapabilityEnabled == false`.

No dashboard runtime, API package, persistence, generated schema, platform, CI,
or app-bootstrap file changed.

## TDD evidence

Initial RED:

```sh
cd apps/truedash
fvm flutter test test/features/dashboard/disk_fixture_contract_test.dart
```

The test failed to compile because `disk_fixture_contract.dart` and all declared
Disk fixture types were absent.

Focused GREEN:

```sh
fvm flutter test \
  test/features/dashboard/disk_fixture_contract_test.dart \
  test/features/dashboard/disk_fixture_runtime_boundary_test.dart
```

Result: 18 passed (14 contract, 4 runtime-boundary).

## Full verification

- formatting: 148 files checked, 0 changed;
- app analyzer: no issues;
- full app suite: 557 passed, 1 existing skip;
- Web release build: success; `sqlite3.wasm` and `drift_worker.js` present;
- `truenas_api`: 64 passed, with two pre-existing informational analyzer notices
  in unchanged files;
- design system: 27 passed;
- external consumer: 1 passed;
- Drift generation twice: passed and idempotent;
- Web asset and persistence-security gates: passed;
- `git diff --check`: passed.

## Tooling

Codex CLI was attempted first with `--sandbox workspace-write`, but WebSocket
and HTTPS fallback returned `401 Unauthorized: Missing bearer or basic
authentication in header` before any file change. Implementation was completed
directly under the approved TDD plan; Codex output is not evidence.

## Delivery boundary

- No TrueNAS host was contacted.
- No API key or account was used.
- No NAS state changed.
- No runtime API or Disk UI was enabled.
- No branch push or MR has occurred at this evidence commit stage.
