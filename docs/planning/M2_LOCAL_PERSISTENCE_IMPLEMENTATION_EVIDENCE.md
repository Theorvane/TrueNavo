# M2 local persistence implementation evidence

**Evidence date:** 2026-09-08
**Issue:** #11 (evidence-only follow-up for M2 / issue #10)
**Pinned merge base:** `480c772baa12788fd81c6947dea1867bac661574`
**MR !12 source tip:** `5ab607f758968b2aec6a91b143e8a170a1e30a12`
**Merge:** `480c772baa12788fd81c6947dea1867bac661574` is the non-squash merge of that source tip into `main`. Its message identifies MR !12 and closes #10. This evidence file is deliberately not a product change.

## Scope and sources of truth

This record is grounded in the pinned source tree; the approved [M2 design](M2_LOCAL_PERSISTENCE_DESIGN.md) and [implementation plan](M2_LOCAL_PERSISTENCE_IMPLEMENTATION.md); committed tests and verification tools; MR !12's source SHA above; and the requested hosted-pipeline traceability records [#654](https://git.sanhouse.kr/sjungwon03/trueraid/-/pipelines/654) (feature) and [#655](https://git.sanhouse.kr/sjungwon03/trueraid/-/pipelines/655) (`main`).

The documentation-generation subprocess could not resolve `git.sanhouse.kr`; that transient, isolated failure is not evidence about the hosted jobs. The orchestration session independently queried GitLab after merge: pipeline [#654](https://git.sanhouse.kr/sjungwon03/trueraid/-/pipelines/654), for MR source SHA `5ab607f758968b2aec6a91b143e8a170a1e30a12`, is `success`; pipeline [#655](https://git.sanhouse.kr/sjungwon03/trueraid/-/pipelines/655), for `main` merge SHA `480c772baa12788fd81c6947dea1867bac661574`, is `success`. In each pipeline, both `portable_quality_and_web` and `macos_release` are `success`. The checked-in [CI definition](../../.gitlab-ci.yml) remains the authoritative local statement of what those jobs execute.

## Data boundary, schema, and migration

| Classification | Persisted location | Evidence and boundary |
| --- | --- | --- |
| Profile metadata (`id`, display name, original validated host input, canonical endpoint, version, timestamps, order) | Drift/SQLite `server_profiles` | Typed columns and length/uniqueness/non-negative constraints in [`app_database.dart`](../../apps/truenavo/lib/features/local_persistence/app_database.dart). |
| Current selection | Drift/SQLite `app_selection` | Singleton `singleton_id = 1`; nullable FK is `SET NULL` when a profile is removed. |
| Capability method names | Drift/SQLite `profile_capabilities` | Composite key, profile `CASCADE`, grammar/length check, expiry ordering check, and expiry index; store caps snapshots at 4096 names and treats expired entries as empty. |
| API key | Native secure storage only | Native `flutter_secure_storage` adapter; `credentialStorageKey` hashes/version-prefixes a canonical validated WSS endpoint. SQLite has no credential column. |
| Certificate pins, fingerprints, DER, RPC payloads, identities, error/native exception details | Not M2 SQLite | The design classifies pins under the existing `PinStore`; `persistence_security_test.dart` rejects forbidden schema terms/values and unstructured payloads. |

`AppDatabase.schemaVersion` is `1`. Its `onCreate` runs `createAll()` and `beforeOpen` enables `PRAGMA foreign_keys = ON`. The committed schema export is [`test/drift/schema_v1.json`](../../apps/truenavo/test/drift/schema_v1.json); [`migration_test.dart`](../../apps/truenavo/test/features/local_persistence/migration_test.dart) opens that committed v1 schema against the current database. The generation verifier dumps the schema, generates against a temporary copy, and compares it to committed generated sources. There is no upgrade migration yet because version 1 has no supported predecessor; the design requires future versions to add tests from every supported prior schema.

## Platform storage strategy

| Target | Safe local state | Remembered API key | What source proves |
| --- | --- | --- | --- |
| Android, iOS, macOS, Linux, Windows | Native SQLite via `drift_flutter`, fixed database name `truenavo_local_state` | `flutter_secure_storage` native adapter | Conditional IO database opener and the native vault options/adapter are compiled source and unit-tested contracts. |
| Web | SQLite WASM plus Drift worker, configured as `sqlite3.wasm` and `drift_worker.js` | Deliberately unsupported/non-persistent | Web opener declares both assets; `WebSecureCredentialVault` reads `null`, rejects writes, and has no browser secret persistence. |

The Web package includes [`web/drift-assets.json`](../../apps/truenavo/web/drift-assets.json), `sqlite3.wasm`, and `drift_worker.js`; `verify_drift_web_assets.dart` validates their declared integrity. A local Chrome smoke harness serves a Web build and waits for `TRUENAVO_WEB_PERSISTENCE_OK` through the Chrome DevTools Protocol. **A passing local Chrome smoke proves browser Drift persistence only.** It does not prove remembered-key storage, native secure storage, TLS, authentication, or interoperability with a real TrueNAS server.

## Remembered-key lifecycle and removal/reset semantics

1. The UI exposes native-only, unchecked-by-default opt-in; an entered API key is not placed in profile or connection state.
2. `TrueNasSessionRepository.connect` first parses the endpoint and obtains the connector transport. Only then does it choose an explicit non-empty key or read the vault. The explicit key wins.
3. It requires successful `auth.login_ex`, `auth.me`, `system.info`, and `core.get_methods`; only then, and only for an explicit opt-in key, it writes the vault.
4. The native vault serializes operations, accepts only bounded non-empty keys, maps storage errors to typed credential failures, uses `androidResetOnError: false`, non-synchronizing Apple options, and opaque `com.truenavo.api-key.v1.<sha256>` identifiers. A cancellation after a replacement write attempts restoration of the prior value.
5. An empty-key reconnect asks the vault after transport verification. A missing/unavailable key maps to safe credential feedback. Web reads no remembered key and rejects writes.
6. Forget/reset is secret-first: `ServerProfileForgetCoordinator` validates the saved canonical endpoint and deletes the secure key before asking the controller/store to remove the profile. If deletion fails, the profile remains addressable and the result is retryable. If the later profile removal fails, the documented/tested result is that the key is already forgotten; it is never restored. Successful database deletion cascades capability rows. If the removed profile was selected, the store uses the FK's temporary `SET NULL` state to detect it, then selects the first remaining profile when one exists; selection is `null` only when no profile remains.

This sequence is an application-level ordering guarantee, not a cross-store atomic transaction: OS secure storage and SQLite cannot be committed as one transaction. The A/E/X policy avoids an orphaned secret by retaining the profile whenever secret deletion fails, so the user can address and retry that deletion.

## A/E/X evidence

| Contract | Committed evidence |
| --- | --- |
| **Accepted**: safe profile order/selection and bounded unexpired capabilities survive load/reopen | `app_database_test.dart`, `migration_test.dart`, `drift_server_profile_store_test.dart`, `persistence_security_test.dart`, and `server_profiles_persistence_test.dart` cover constraints, migration/open, ordering, selection, cap replacement/TTL, and reopen. |
| **Accepted**: explicit native key is success-only; remembered key is read after transport | `packages/truenas_api/test/session/true_nas_session_repository_test.dart`, `connection_persistence_test.dart`, `connection_persistence_hostile_test.dart`, `credential_storage_key_test.dart`, and `secure_credential_vault_test.dart`. |
| **Accepted**: secret-first forget and cascade | `server_profile_forget_coordinator_test.dart` and `server_switcher_test.dart` cover deletion-before-profile-removal, retry outcomes, stale UI, and success/fallback behaviour. |
| **Error**: invalid/corrupt/oversized data, duplicate endpoints, expired capabilities, persistence failures, and vault failures fail safely | `persistence_security_test.dart`, `drift_server_profile_store_lifecycle_test.dart`, profile/controller persistence tests, and vault/repository tests exercise typed failures and preservation of committed state. |
| **Excluded**: secrets/trust material/unstructured cache payloads in SQLite; browser remembered keys; pre-TLS vault access; automatic login | M2 design §§3, 7, 10–11; schema/static security tests; `persistence_web_security_test.dart`; and the repository ordering tests. |

These are test and source-level claims, not a claim that every OS implementation has run on hardware.

## Verification commands and observed results

### Recorded feature/main CI contract

`portable_quality_and_web` in `.gitlab-ci.yml` runs formatting, two Drift-generation consistency passes, all package/app analysis and tests, Web asset and persistence-boundary verification, a release Web build, and existence checks for generated WASM/worker artifacts. `macos_release` runs a macOS Xcode release build with signing disabled, ad-hoc signs and strictly verifies the app, inspects entitlements, builds iOS Simulator, and runs the iOS Keychain restart integration script. GitLab independently reports both jobs `success` for pipeline #654 (the MR source SHA) and #655 (the merged `main` SHA).

### This evidence worktree

| Command | Observed result |
| --- | --- |
| `git rev-parse HEAD` | Exit 0; `480c772baa12788fd81c6947dea1867bac661574`. |
| `git status --short` before creating this file | Exit 0; no output (clean base). |
| `git show --no-patch --format=fuller 5ab607f758968b2aec6a91b143e8a170a1e30a12` | Exit 0; identifies the requested MR !12 source-tip commit. |
| `git show --no-patch --format=fuller 480c772baa12788fd81c6947dea1867bac661574` | Exit 0; identifies the merge and its parent source tip. |
| GitLab pipeline status (queried after merge) | #654 (`5ab607f758968b2aec6a91b143e8a170a1e30a12`): `success`; #655 (`480c772baa12788fd81c6947dea1867bac661574`): `success`; `portable_quality_and_web` and `macos_release` are `success` in both. |

No Flutter test, Web build, Chrome smoke, macOS build, codesign, or device integration command was re-run while creating evidence-only documentation. Their presence in the CI contract and their committed unit/integration harnesses is not a substitute for a newly observed run.

## Limits and non-claims

- Local Chrome smoke proves browser Drift persistence only.
- macOS CI/local build and ad-hoc codesign do **not** prove full native OS secure-storage behaviour or TLS interoperability.
- Do not claim Android, iOS, Windows, or Linux runtime validation. The iOS CI script is configured as an integration check and `macos_release` succeeded in #654 and #655, but this record does not inspect its job trace or elevate that job status into a device-runtime claim.
- No claim is made that any live TrueNAS server, TLS certificate path, login, or OS credential store was exercised in this worktree.
- This record makes no README, source, configuration, generated-code, commit, or push change; it documents the already merged M2 implementation only.
