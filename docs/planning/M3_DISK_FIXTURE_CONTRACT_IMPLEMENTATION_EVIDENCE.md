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
| Attempted/retained records | 128 | 128 complete; encoded record 129 makes the result partial |
| Values/entries | 512 | deceptive record map rejects at limit |
| String | 32 UTF-16 units | 33 invalidates only containing record |
| Encoded fixture | 32768 UTF-16 units | 32769 rejects before JSON decode |
| JSON nesting | 16 | depth 17 rejects before JSON decode |

- Non-String custom `Map`/`List` inputs reject without member access.
- Duplicate JSON keys at the root or record level reject before `jsonDecode`.
- JSON with 513 record entries rejects with `traversalLimitExceeded`.
- Mutating the caller's pre-encoding maps/lists after parse cannot change the
  scalar aggregate output.
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

Dedicated behavioral tests prove:

- `DiskFixtureContract.isRuntimeEnabled` is always false;
- disks remain disabled in `DashboardCapabilities`;
- the capability intersection retains the exact six methods and excludes
  advertised `disk.query`.

Repository-level diff/search gates—not source-reading unit tests—prove the
session allowlist, dashboard imports/UI, and admission/evidence files are
unchanged from the reviewed base.

No dashboard runtime, API package, persistence, generated schema, platform, CI,
or app-bootstrap file changed.

## TDD evidence

Initial RED:

```sh
cd apps/truenavo
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

Result: 20 passed (19 contract, 1 runtime-boundary).

## Exact-SHA review remediation

The initial exact-SHA reviews of
`1114ccf70545cbb965a7d91ee1011a886ffd409f` rejected the candidate. The parser
accepted duplicate entries from deceptive maps, did not traverse nested custom
containers for claimed alias/map/list limits, and could block forever inside
caller-defined `Map`/`List` getters or equality. The runtime-boundary tests also
violated repository policy by reading production source files.

The public boundary now accepts only a JSON `String` capped at 32,768 UTF-16
units. Non-String custom collections reject before member access. A bounded
depth-16 scanner rejects duplicate decoded keys—including escaped spellings—
before `jsonDecode`. Since JSON cannot encode object aliasing or cycles, the
unreachable map/list identity claims were removed; actual 128-record,
512-value/entry, string, encoded-size, and JSON-depth limits remain executable.
Runtime unit coverage now uses public capability behavior only, while exact
unchanged-path/import/UI/session/admission claims are checked by repository
diff/search commands.

The exact-SHA specification rereview of
`405d686dba94dc1fe5f5af1f99830145868ee8a2` found that the design's
credential/network/account/request/UUID/hardware matrix was not durably tested
in both key and value positions, and that lower sides of encoded-size,
value-entry, and JSON-depth boundaries were represented only by disposable
review probes. A committed matrix now checks 23 representative unsafe values in
both positions. Durable tests also cover encoded units 32768/32769, total
visited entries 512/513, JSON depth 16/17, and literal plus escaped-equivalent
duplicate keys. The focused count is verified as 19 contract tests plus one
runtime behavior test.

## Full verification

- formatting: 148 files checked, 0 changed;
- app analyzer: no issues;
- full app suite: 559 passed, 1 existing skip;
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
