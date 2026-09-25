# M2 Local Persistence Implementation Plan

> **For Hermes:** Use Codex CLI in the isolated issue worktree to implement this plan task-by-task, with exact RED/GREEN evidence and exact-SHA independent review.

**Goal:** Persist safe TrueRAID profile/capability state in cross-platform SQLite while keeping API keys in native secure storage and preserving the M1 TLS-before-credential boundary.

**Architecture:** Drift owns typed app-local relational state behind a `ServerProfileStore` port. Production bootstrap injects the opened store and initial snapshot; controllers publish only committed snapshots. `TrueNasSessionRepository` resolves or stores credentials through its existing `CredentialVault` port only after a verified transport exists, while a native Flutter adapter uses versioned hashed endpoint keys and Web remains non-persistent.

**Tech Stack:** Flutter 3.47.0, Dart 3.13, Riverpod 3, Drift/Drift Flutter, flutter_secure_storage, build_runner/drift_dev, SQLite WASM for Web, Flutter test.

---

## Task 1: Add Drift and Web database infrastructure

**Objective:** Add pinned, lockfile-resolved Drift dependencies, generated-code tooling, and deterministic native/Web database opening.

**Files:**
- Modify: `apps/trueraid/pubspec.yaml`
- Modify: `pubspec.lock`
- Create: `apps/trueraid/lib/features/local_persistence/database_connection.dart`
- Create: `apps/trueraid/lib/features/local_persistence/database_connection_io.dart`
- Create: `apps/trueraid/lib/features/local_persistence/database_connection_web.dart`
- Create/modify Web assets under `apps/trueraid/web/` as required by the selected Drift version
- Test: `apps/trueraid/test/features/local_persistence/database_connection_test.dart`

**Steps:**
1. Add a failing platform-contract test proving the app exposes a fixed database name/path strategy and that Web selection does not import native IO.
2. Run the focused test and record the expected missing-symbol failure.
3. Add compatible `drift`, `drift_flutter`, `build_runner`, and `drift_dev` dependencies; use the selected package's documented SQLite WASM/worker setup.
4. Implement conditional connection opening with fixed constants and no user-derived filesystem paths.
5. Run dependency resolution, focused tests, analyzer, and a Web release build.
6. Commit `build(persistence): add cross-platform drift runtime`.

## Task 2: Define schema and migration contract

**Objective:** Implement schema version 1 with strict profile, selection, and capability constraints.

**Files:**
- Create: `apps/trueraid/lib/features/local_persistence/app_database.dart`
- Generate: `apps/trueraid/lib/features/local_persistence/app_database.g.dart`
- Create: `apps/trueraid/test/features/local_persistence/app_database_test.dart`
- Create: `apps/trueraid/test/features/local_persistence/migration_test.dart`
- Create schema export in the Drift-recommended test location

**Steps:**
1. Write failing in-memory tests for table creation, unique endpoint, singleton selection, foreign keys, cascade/set-null behavior, sort-order checks, method-name checks, and expiry ordering.
2. Run tests and preserve RED output.
3. Implement the three tables, indexes, schema version, foreign-key activation, and version-1 creation migration.
4. Generate Drift code deterministically.
5. Run schema/migration tests and generation consistency checks.
6. Commit `feat(persistence): define local state schema`.

## Task 3: Add typed profile/capability persistence port

**Objective:** Expose safe snapshots and transactional mutations without leaking Drift into feature controllers.

**Files:**
- Create: `apps/trueraid/lib/features/server_profiles/server_profile_store.dart`
- Create: `apps/trueraid/lib/features/local_persistence/drift_server_profile_store.dart`
- Create: `apps/trueraid/lib/features/local_persistence/persistence_failure.dart`
- Test: `apps/trueraid/test/features/local_persistence/drift_server_profile_store_test.dart`

**Steps:**
1. Write failing tests for ordered restore, new registration, endpoint/id collisions, transaction rollback, selection, unknown selection, removal, selection fallback, capability snapshot replacement, 4096 cap, grammar rejection, expiry, and cascade.
2. Confirm failures are due to missing implementation.
3. Implement `ServerProfileSnapshot`, `ServerProfileStore`, typed failures, and Drift mapper/store.
4. Revalidate every row when mapping to `ServerProfile`; do not expose malformed rows.
5. Run focused tests and analyzer.
6. Commit `feat(persistence): persist safe server metadata`.

## Task 4: Bootstrap and persist Riverpod profile state

**Objective:** Restore profiles before first render and persist every controller transition without stale/disposed publication.

**Files:**
- Modify: `apps/trueraid/lib/main.dart`
- Create: `apps/trueraid/lib/bootstrap.dart`
- Modify: `apps/trueraid/lib/features/server_profiles/server_profiles_controller.dart`
- Modify: `apps/trueraid/lib/features/server_profiles/server_switcher.dart`
- Modify: `apps/trueraid/lib/features/connection/connection_controller.dart`
- Modify relevant app-shell tests
- Test: `apps/trueraid/test/features/server_profiles/server_profiles_persistence_test.dart`
- Test: `apps/trueraid/test/bootstrap_test.dart`

**Steps:**
1. Write failing tests proving initial restored state has no empty flash, mutations publish only committed snapshots, write failures preserve prior state, late completions cannot mutate disposed providers, and connection success waits for profile/capability persistence.
2. Run focused RED tests.
3. Add store and initial-snapshot providers; bootstrap Drift before `runApp` and root-own exactly-once close.
4. Convert mutations to contained async operations and await profile persistence from `ConnectionController` while preserving M1 generation/ownership checks.
5. Persist capability names with an injected clock and 24-hour expiry.
6. Run focused profile, connection, app-shell, bootstrap, and analyzer checks.
7. Commit `feat(profiles): restore and persist server catalog`.

## Task 5: Implement native secure credential vault

**Objective:** Persist API keys only in native secure storage under versioned hashed canonical endpoint keys.

**Files:**
- Create: `apps/trueraid/lib/features/credentials/secure_credential_vault.dart`
- Create: `apps/trueraid/lib/features/credentials/secure_credential_vault_io.dart`
- Create: `apps/trueraid/lib/features/credentials/secure_credential_vault_web.dart`
- Create: `apps/trueraid/lib/features/credentials/credential_storage_key.dart`
- Modify: `apps/trueraid/lib/features/connection/connection_controller.dart`
- Test: `apps/trueraid/test/features/credentials/secure_credential_vault_test.dart`
- Test: `apps/trueraid/test/features/credentials/credential_storage_key_test.dart`

**Steps:**
1. Write failing tests for deterministic SHA-256 endpoint key derivation, domain separation/version prefix, native read/write/delete delegation, Web non-persistence, safe exception mapping, and no plaintext endpoint in storage keys.
2. Verify RED.
3. Implement conditional native/Web vault adapters and production provider wiring.
4. Ensure exceptions never contain the API key, raw secure-storage exception, or host filesystem detail.
5. Run focused tests, analyzer, and Web build.
6. Commit `feat(credentials): add native secure API key vault`.

## Task 6: Move remembered credential resolution behind verified transport

**Objective:** Read and write remembered credentials only inside the session repository after transport verification and successful authentication.

**Files:**
- Modify: `packages/truenas_api/lib/src/session/session_repository.dart` or current defining source
- Modify: `packages/truenas_api/lib/src/session/true_nas_session_repository.dart`
- Modify: `packages/truenas_api/lib/src/session/credential_vault.dart`
- Modify: `packages/truenas_api/test/session/true_nas_session_repository_test.dart`
- Modify: `apps/trueraid/lib/features/connection/connection_controller.dart`
- Modify: `apps/trueraid/test/features/connection/connection_controller_tls_test.dart`

**Steps:**
1. Add failing protocol tests proving vault read occurs after connector success, explicit key precedence, missing remembered key safety, write only after all summary calls succeed, and no write on TLS/auth/RPC/cancel failure.
2. Add failing controller tests across first trust, stored pin, replacement, platform TLS, stale/disposed, and wrong-endpoint paths.
3. Implement nullable explicit credential plus `rememberApiKey` intent without placing a credential in any returned/state object.
4. Derive the vault credential id only from validated canonical endpoint data.
5. Re-run hostile M1 ownership/race matrix and API package suite.
6. Commit `feat(connection): resolve remembered keys after TLS`.

## Task 7: Add explicit remember/forget UX

**Objective:** Offer native-only opt-in without prefilling secret material and make removal secret-first.

**Files:**
- Modify: `apps/trueraid/lib/features/connection/connection_screen.dart`
- Modify: `apps/trueraid/lib/features/server_profiles/server_switcher.dart` or profile action surface
- Modify: `apps/trueraid/test/features/connection/connection_screen_test.dart`
- Modify: `apps/trueraid/test/features/server_profiles/server_switcher_test.dart`

**Steps:**
1. Write failing widget tests for native unchecked-by-default remember control, Web absence/explanation, empty-key remembered connection intent, no secret prefill, busy/keyboard/accessibility behavior, save warning, and secret-first profile removal.
2. Verify RED at 320px and desktop widths with 200% text where applicable.
3. Implement minimal accessible controls and credential-free copy.
4. Ensure secure deletion failure preserves the SQLite profile and reports a safe retryable error.
5. Run focused widget tests and analyzer.
6. Commit `feat(connection): add remembered credential controls`.

## Task 8: Security and database hostile tests

**Objective:** Prove the storage boundary cannot accept secrets or violate lifecycle guarantees.

**Files:**
- Create: `apps/trueraid/test/features/local_persistence/persistence_security_test.dart`
- Extend focused credential/profile/connection tests

**Steps:**
1. Add tests scanning schema/rows for forbidden columns and values; reject arbitrary JSON, API-key-like cache input, malformed endpoints/methods, oversized snapshots, expired rows, DB write races, disposed completion, vault exceptions, and double-close.
2. Add a deterministic database reopen test and Web conditional route test.
3. Run RED against isolated old behavior where applicable, then GREEN.
4. Search added source and generated schema for forbidden credential/pin/fingerprint/raw-DER/logging patterns.
5. Commit `test(persistence): harden local storage boundaries`.

## Task 9: Documentation and full verification

**Objective:** Produce reviewable evidence and a release-quality candidate.

**Files:**
- Create: `docs/planning/M2_LOCAL_PERSISTENCE_IMPLEMENTATION_EVIDENCE.md`
- Modify: `README.md` only if user-visible storage behavior is currently documented there

**Steps:**
1. Document schema, platform matrix, data classification, migration contract, remembered-key behavior, reset/removal semantics, RED/GREEN evidence, and known platform limitations.
2. Run generation consistency, all package tests/analyzers, Web release build, native macOS build where signing permits, formatter, `git diff --check`, and forbidden-pattern scans.
3. Inspect generated Web artifacts for required SQLite WASM/worker files.
4. Commit `docs(persistence): record local storage verification`.
5. Push the exact candidate, obtain exact-SHA independent review, remediate with new RED/GREEN commits as necessary, require hosted branch/MR CI, merge without squash while preserving the source branch, verify post-merge `main` CI, fast-forward local `main`, and remove the worktree.
