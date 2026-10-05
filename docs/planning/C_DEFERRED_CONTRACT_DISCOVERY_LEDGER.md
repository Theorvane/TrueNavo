# Deferred contract discovery ledger

> **Status: discovery only — default deny.** Nothing in this ledger admits a
> runtime query, adds a method to the dashboard allowlist, or permits UI
> activation. Every row remains fixture-only until it completes the separate
> [runtime admission gate](C_DEFERRED_RUNTIME_ADMISSION_GATE.md).

## Purpose and boundary

This ledger records the first source-backed input for a future per-tuple
admission review. A row is not an API integration specification. It has no
request implementation, response model, fixture, live-appliance evidence, or
approval.

The current dashboard runtime query allowlist remains exactly:
`system.info`, `pool.query`, `pool.dataset.query`, `service.query`,
`alert.list`, and `core.get_jobs`. In particular, VDEV, disk, snapshot, and
apps remain runtime-disabled despite any method named below.

Every future review is isolated to this tuple:

`(version family, domain, exact method, request-shape fingerprint, response-schema fingerprint)`

A documented method name is only a discovery fact. It does not establish the
safe request shape, response fields, RBAC behavior on a real appliance, or a
cross-version schema guarantee.

## Candidate status legend

| Status | Meaning | Runtime effect |
| --- | --- | --- |
| `candidate-documentation` | A version-specific public method page was located. | None — disabled. |
| `blocked-source` | A stable method-level source has not been captured. | None — disabled. |
| `rejected` | A later admission gate failed. | None — disabled. |
| `admitted` | Reserved for a separately approved tuple only. | Still needs a distinct code MR. |

There are **no `admitted` rows** in this document.

## Discovery matrix

| Version family | Domain | Candidate method or existing surface | Status | Source | Mandatory next evidence |
| --- | --- | --- | --- | --- | --- |
| 25.04 | VDEV | Existing `pool.query` topology field | `candidate-documentation` | The version-specific `pool.query` schema documents a physical topology including VDEVs and the `POOL_READ` role.[11] | Exact selected fields, topology bounds, redaction review, and appliance A/E/X evidence. |
| 25.10 | VDEV | Existing `pool.query` topology field | `candidate-documentation` | `pool.query` documents pool topology as physical structure including VDEVs.[1] | Exact selected fields, topology bounds, redaction review, and appliance A/E/X evidence. |
| 26+ | VDEV | Existing `pool.query` topology field | `candidate-documentation` | The 26.0 `pool.query` page documents a topology object containing VDEV structure.[2] | Exact selected fields, topology bounds, redaction review, and appliance A/E/X evidence. |
| 25.04 | Disk | `disk.query` | `candidate-documentation` | The version-specific `disk.query` schema documents the method and the `READONLY_ADMIN` role.[12] | Exact safe projection, exclusion of optional/sensitive expansion, bounds, RBAC proof, and A/E/X evidence. |
| 25.10 | Disk | `disk.query` | `candidate-documentation` | The method page documents `disk.query` and the `DISK_READ` role.[3] | Exact safe projection, explicit exclusion of sensitive extra options, bounds, RBAC proof, and A/E/X evidence. |
| 26+ | Disk | `disk.query` | `candidate-documentation` | The method page documents `disk.query` and the `DISK_READ` role.[4] | Exact safe projection, explicit exclusion of sensitive extra options, bounds, RBAC proof, and A/E/X evidence. |
| 25.04 | Snapshot | `pool.snapshot.query` | `candidate-documentation` | The version-specific snapshot-query schema documents the method and the `SNAPSHOT_READ` role.[13] | Exact projection, exclusion of optional expanded data, bounds, RBAC proof, and A/E/X evidence. |
| 25.10 | Snapshot | `pool.snapshot.query` | `candidate-documentation` | The method page documents snapshot querying and the `SNAPSHOT_READ` role.[5] | Exact projection, exclusion of optional expanded data, bounds, RBAC proof, and A/E/X evidence. |
| 26+ | Snapshot | `pool.snapshot.query` | `candidate-documentation` | The method page documents snapshot querying and the `SNAPSHOT_READ` role.[6] | Exact projection, exclusion of optional expanded data, bounds, RBAC proof, and A/E/X evidence. |
| 25.04 | Apps | `app.query` | `candidate-documentation` | A version-specific `app.query` method page was located.[7] | Exact safe projection, config/schema exclusion, bounds, RBAC proof, and A/E/X evidence. |
| 25.10 | Apps | `app.query` | `candidate-documentation` | The method page documents `app.query` and the `APPS_READ` role.[8] | Exact safe projection, config/schema exclusion, bounds, RBAC proof, and A/E/X evidence. |
| 26+ | Apps | `app.query` | `candidate-documentation` | The method page documents `app.query` and the `APPS_READ` role.[9] | Exact safe projection, config/schema exclusion, bounds, RBAC proof, and A/E/X evidence. |

## Request and response hazards

A future typed contract must start with the smallest source-backed request and
safe response projection. It must reject unknown fields and never pass through
query options or server-controlled nested maps.

The documented pages expose options that are specifically **not** candidates
for an initial observation tuple:

- Disk query documents a `passwords` extra option that changes password
  hiding, as well as optional pool joining.[3][4]
- Snapshot query documents optional holds, retention, transaction-group, and
  properties expansion.[5][6]
- App query documents optional app schema and installation/management
  configuration retrieval.[7][8][9]

These options are not request defaults, display fields, or evidence inputs for
TrueNavo. Any future request must prove an immutable parameter fingerprint and
an allowlisted, bounded projection without them.

For VDEV observation, `pool.query` is already a permitted dashboard method;
that does not admit arbitrary nested topology rendering. A VDEV tuple must
still pin a response-schema fingerprint, select safe typed fields, and pass the
same evidence and approval gates before a VDEV view can be enabled.[1][2]

## Required admission package for one row

Before changing production code for one row, attach all of the following to a
single tuple review:

1. Immutable source artifact: version-specific URL, recorded version identifier,
   retrieval timestamp, and SHA-256 digest; a future review must fail closed if
   a re-fetch does not match this artifact or if the source cannot be archived.
2. Exact method, parameter fingerprint, and response-schema fingerprint.
3. Role/capability evidence from the same tested version and appliance class.
4. Typed bounded fixture contract with unknown-field, list/map/text-bound, and
   secret-shaped data regressions.
5. Redacted live evidence that retains only safe typed observations.
6. A/E/X matrix: admitted request, expected safe data, and excluded unsupported
   or unsafe paths.
7. Explicit independent approval with `approved: true` for this exact tuple.
8. A distinct narrow code MR, exact-SHA review, CI, and live re-verification.

No evidence, no approval, or any schema/RBAC/redaction mismatch leaves the row
runtime-disabled.

## Non-goals

- No runtime API method is enabled by this ledger.
- No raw appliance payload, endpoint, TLS pin, credential, identifier, serial,
  request parameter, or remote error is collected or retained.
- No mutation, broad query passthrough, generic payload renderer, or uncertain
  auto-retry is authorized.

## Source retrieval record

The following record binds this discovery pass to the exact HTTP bodies retrieved
at `2026-09-09T03:33:23Z` and the 25.04 correction bodies retrieved at
`2026-09-09T05:55:30Z`. These public documentation URLs are mutable hosts;
the SHA-256 digest is the immutable review artifact. A future admission review
must re-fetch, compare the digest, and archive the matching body or fail closed.
A matching digest does not constitute runtime approval.

| Source | HTTP | Bytes | SHA-256 |
| --- | ---: | ---: | --- |
| [1] | 200 | 377296 | `ea2fafeb1eeca4aab1339d992e10d7848eab0392bfddf9f4d7d27c4be36d0182` |
| [2] | 200 | 422915 | `745870ac49f9ae709b00102fe3217d23e9771bd77f1307eaa33e83081ca755ef` |
| [3] | 200 | 308868 | `69ae577162a69a2632ef5d80203733575b1b7edecd219d5f97a9fda01b9102db` |
| [4] | 200 | 335945 | `43ab19dc4b7a568f115e469d0835a3618e2fdf63dcb88eddfeecda6f370af380` |
| [5] | 200 | 247595 | `77dfb291564a6b4fe7304bf4bf494fb21ee2fc804da07c48520aee301b31103e` |
| [6] | 200 | 258784 | `8ee892d111f67ff77e51b71c114ead5b8680b17d8084039f049e887f025774d0` |
| [7] | 200 | 251245 | `9fcba318f6b9a3aa7960d6ca8d94b119953e9c338ff259e97cf028f91fe0e1ba` |
| [8] | 200 | 316367 | `f26309e0a7b21cda1aca7347e63eb390c6f47f2db82cd4abdb19a29e6dd13bb0` |
| [9] | 200 | 341370 | `cc70fe5bac431e12e7939a55cb0150aa178ec4ee76f2c46c6c7fa0e4778ccd2b` |
| [10] | 200 | 109384 | `781f1b3042328dc5972dae7adbe4f9c51ae176c242f1fc81ad763b7b7a73850b` |
| [11] | 200 | 234234 | `ddc8103e3bbe78a0f63a103dcc842fef185b058cdff0d16df4d25b93c0663ec0` |
| [12] | 200 | 172094 | `f81cd72ef4d5cf90c63d6443f2f1d96665aef6c6f4577968be6a4055c49ae8bb` |
| [13] | 200 | 147199 | `5b24593e2bca321160c4acb75ca1a26ba4abb87697625bddd22b6cbdfccfcb72` |

## Sources

[1] https://api.truenas.com/v25.10/api_methods_pool.query.html
[2] https://api.truenas.com/v26.0/api_methods_pool.query.html
[3] https://api.truenas.com/v25.10/api_methods_disk.query.html
[4] https://api.truenas.com/v26.0/api_methods_disk.query.html
[5] https://api.truenas.com/v25.10/api_methods_pool.snapshot.query.html
[6] https://api.truenas.com/v26.0/api_methods_pool.snapshot.query.html
[7] https://api.truenas.com/v25.04/api_methods_app.query.html
[8] https://api.truenas.com/v25.10/api_methods_app.query.html
[9] https://api.truenas.com/v26.0/api_methods_app.query.html
[10] https://api.truenas.com/v25.04/jsonrpc.html
[11] https://api.truenas.com/v25.04/api_events_pool.query.html
[12] https://api.truenas.com/v25.04/api_events_disk.query.html
[13] https://api.truenas.com/v25.04/api_events_pool.snapshot.query.html
