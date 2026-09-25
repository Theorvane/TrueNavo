# Native cloud credentials (partial WebUI parity)

Targets stable TrueNAS 25.10 using pinned public **TS-25.10.1** middleware source. This is a bounded native lifecycle workspace, not full WebUI parity or an official TrueNAS application. Implementation and tests use only synthetic transports and connector-free previews. No NAS connection, supplied credential, live cloud authentication or live write was used.

## Scope

- Inventory contains only credential ID, name and provider type, plus cloud sync/cloud backup reference IDs and enabled flags. Existing access keys, tokens, custom client values and hidden provider settings are not requested.
- Create complete S3 records or Dropbox records containing an already-issued token JSON object.
- Rename with a **name-only patch** that preserves every stored provider field.
- Replace the **entire provider record**, requiring all new values explicitly. Blank optional fields intentionally overwrite prior values; the adapter never reads or substitutes an existing secret. Provider conversion is unsupported.
- Delete unused S3/Dropbox records after checking both cloud sync and cloud backup references. Deletion removes the NAS configuration, not the provider credential or remote objects.
- Show an accessible reference-count doughnut and separate sync/backup counts. These are configuration counts, not authentication validity, cloud health, backup integrity or recoverability.

Other providers remain visible but immutable. OAuth browser authorization, token refresh, verification, cloud browsing, restore and provider-side revocation are not implemented. No credential verification, remote directory listing, dry run or transfer occurs automatically.

## Public wire contract

| Operation | Exact method/arguments | Effects |
| --- | --- | --- |
| Credential inventory | `cloudsync.credentials.query [[], {limit:129, select:["id","name","provider.type"]}]` | Bounded projection; provider secrets omitted. |
| Dependency inventory | `cloudsync.query` and `cloud_backup.query`, each `[[], {limit:257, select:["id","credentials.id","enabled"]}]` | Local task/reference state, without task passwords, scripts or nested provider secrets. |
| Active jobs | `core.get_jobs [[["state","in",["WAITING","RUNNING"]]], {limit:129, select:["id","method","state"]}]` | Read-only job safety information; no job result/log/arguments selected. |
| Create | `cloudsync.credentials.create [{name, provider:completeRecord}]` | Validates uniqueness, stores credential configuration. No implicit provider verification. |
| Rename | `cloudsync.credentials.update [id, {name}]` | Preserves provider object through the server's top-level merge. |
| Replace | `cloudsync.credentials.update [id, {provider:completeRecord}]` | Replaces the complete nested provider object; not a nested patch. |
| Delete | `cloudsync.credentials.delete [id]` | Checks both dependency types, then deletes stored configuration. |

S3 submits all fields: `type`, `access_key_id`, `secret_access_key`, `endpoint`, `region`, `skip_region`, `signatures_v2`, `max_upload_parts`. Dropbox submits `type`, `token`, `client_id`, `client_secret`. Optional values are explicit, not inferred from an unread existing record. The app accepts bare HTTPS S3 endpoints only (or empty for AWS); embedded user info, query, fragment, non-root path and control characters are blocked. Provider string limits follow the source's 1024-character default, with tighter local region/name bounds and a bounded 16384-character Dropbox token. Token input must be a single-line JSON object with a nonempty access token and bearer token type; CR/LF/NUL and other controls are rejected to prevent rclone configuration line injection.

Primary sources:

- [Credential CRUD and verification service](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/plugins/cloud_sync.py): `CredentialsService.do_update` does `old.copy()` then `new.update(data)`, so nested provider fields are replaced wholesale. `_validate` checks name uniqueness. `do_delete` checks both `cloudsync.query` and `cloud_backup.query` references.
- [Credential API models](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/cloud_credential.py), [typed provider schemas](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/cloud_sync_providers.py), [base model string bounds](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/base/model.py).
- [Nested select implementation](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/utils/filter_list.py), [cloud backup model](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/api/v25_10_0/cloud_backup.py), [S3 provider behavior](https://github.com/truenas/middleware/blob/TS-25.10.1/src/middlewared/middlewared/rclone/remote/s3.py).

`cloudsync.credentials.verify` is deliberately absent: the service announces network activity, writes a restricted temporary rclone configuration, and runs `lsjson remote:`. Its raw errors/excerpts may expose provider details. A future explicit verification flow must separately review those effects and redact all results; it must not be classified as a harmless inventory query.

## Secret handling and safety

`CloudCredentialWriteOnlyInput` is a separate ephemeral execute argument. It never enters an inventory, request/review, Riverpod controller state, profile, credential vault or application cache. Secret input is obscured with autocorrect, suggestions and personalized IME learning disabled. Editor cancellation/disposal clears controllers; session or inventory changes permanently expire and hide editors/reviews. Any non-resumed app lifecycle state discards secret input and permanently expires open editor/review flows; resuming cannot revive them. An already-inactive app cannot open the secret editor. The workflow releases the write-only input on cancellation, stale review, preflight rejection, success, uncertainty and preview rejection. Its `toString` is always redacted. Releasing references is **not guaranteed memory zeroization**; Dart strings and serialized request/response bytes may exist transiently in memory.

CRUD responses can include secret-bearing provider fields. The adapter immediately projects only ID/name/provider type and returns a fixed local status message, never the raw response or error. It does not compare or retain returned secret values.

Session-issued inventory/review identities are required. Reviews expire after five minutes, require exact case-sensitive target typing and impact acknowledgment, and are consumed once. Review and execute re-read credential identity/type/name, both dependency sets and active-job state. Delete blocks any reference. Replacement blocks enabled dependent schedules and active conflicting cloud/storage/system jobs; disabled references are included in the review because the next run will inherit the new authentication material. No client retry occurs.

All errors **after dispatch** are unknown, including permission errno values: CRUD hooks/events can fail after the datastore mutation. Malformed receipts, timeout and connection loss likewise retain the native/shared operation fence. Reconnecting and inspecting the original server is required before further changes. An in-flight or unknown credential change blocks API-key, replication, cloud sync, update and legacy mutations.

No public secret-free revision/hash can detect a same-ID/name/provider secret-only change made by another administrator. Fingerprints cover only projected identity and dependencies, not secrets. TrueNAS exposes no atomic compare-and-swap for these CRUD methods; an administrator, scheduler or manual task can race after the final preflight. Coordinate changes and keep affected schedules disabled until new cloud access is independently checked. Success means the server acknowledged stored configuration, not that the credentials work or future tasks will succeed.

## Verification

- SDK synthetic transport suite: **103 tests** passing, including public projections, complete replacement/name-only preservation, both dependency classes, malformed inventories/receipts, drift, one-use reviews, secret bounds/redaction/disposal (including direct disconnected execution), unknown fences and zero-frame cross-family rejection.
- Flutter connector-free suite: **30 tests** passing, including cancellation/session/inventory/background expiry, no secret autofill/provider-state retention, explicit review/confirmation, shared locks, count semantics, and create/review/confirm at 320/430 logical pixels with 200% text and a 300-pixel keyboard inset.
- `CloudCredentialsPreviewAdapter` contains no real credentials or connector and rejects all writes.

Commands: `fvm dart test test/session/session_cloud_credentials_test.dart` from `packages/truenas_api`; `fvm flutter test test/features/cloud_credentials/cloud_credentials_test.dart` from `apps/trueraid`. No live write or cloud-authentication result is claimed.
