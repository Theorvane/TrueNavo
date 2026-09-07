# M2 Local persistence and secure credential design

**Status:** Approved

**Date:** 2026-09-07

**Issue:** #10

## 1. Goal

TrueDash will survive application restarts without weakening the TLS trust boundary delivered in M1. Safe server metadata, the selected profile, and a bounded snapshot of available TrueNAS RPC method names are stored in SQLite. API keys remain outside SQLite in platform secure storage, and certificate pins remain in the existing `PinStore`.

This slice does not automatically connect at startup and does not add broad TrueNAS management capabilities.

## 2. Chosen approach

Use Drift as the typed persistence layer and `drift_flutter` for cross-platform database opening.

- Android, iOS, macOS, Linux, and Windows use native SQLite.
- Flutter Web uses SQLite WASM with the Drift worker/OPFS strategy supported by the selected Drift release.
- Database code remains app-owned under `features/local_persistence`; `truenas_api` stays independent of Flutter and Drift.
- Secure credentials use a Flutter app adapter implementing the existing `CredentialVault` port.
- Native credential persistence uses `flutter_secure_storage`.
- Web does not offer remembered API keys because browser storage is not an OS credential vault. Web continues to accept an API key for the current connection attempt only.

Drift is preferred over raw `sqflite` because it provides one typed schema and migration surface across all six targets, deterministic in-memory tests, and compile-time query verification. Raw `sqlite3` would reduce abstraction but require significantly more manual mapping and lifecycle code. `sqflite` would require separate desktop and experimental Web adapters.

## 3. Data classification

| Data | Storage | Rationale |
|---|---|---|
| Server profile safe metadata | SQLite | Explicitly approved non-secret local state |
| Selected profile id | SQLite | Non-secret UI preference |
| RPC method-name snapshot | SQLite | Non-secret capability metadata, typed and bounded |
| API key | Native OS secure storage only | Authentication secret |
| Certificate pin record | Existing `PinStore` only | Separate trust boundary |
| Certificate fingerprint / raw DER | Never SQLite | Trust data must not leak into general storage |
| Identity/account details | Memory only in this slice | Not required for restart UX |
| RPC responses, alerts, job payloads | Never this cache | Arbitrary payloads may contain sensitive content |
| Error/native exception detail | Never persisted | Avoid local secret and host-path disclosure |

The SQLite API accepts typed fields rather than arbitrary JSON. This prevents callers from smuggling credentials or unreviewed server responses into a generic cache column.

## 4. Schema

Schema version starts at `1`.

### `server_profiles`

| Column | Type | Constraint |
|---|---|---|
| `id` | TEXT | Primary key; opaque app id |
| `display_name` | TEXT | Non-empty; bounded length |
| `original_host_input` | TEXT | Validated HTTPS/WSS input; no userinfo/query/fragment |
| `normalized_endpoint` | TEXT | Unique canonical WSS RPC endpoint |
| `last_known_version` | TEXT | Non-empty; bounded length |
| `created_at_ms` | INTEGER | UTC epoch milliseconds |
| `updated_at_ms` | INTEGER | UTC epoch milliseconds |
| `sort_order` | INTEGER | Stable first-registration order; non-negative |

### `app_selection`

A singleton row with `singleton_id = 1` and nullable `selected_profile_id`. The profile reference uses `ON DELETE SET NULL`.

### `profile_capabilities`

| Column | Type | Constraint |
|---|---|---|
| `profile_id` | TEXT | Foreign key, `ON DELETE CASCADE` |
| `method_name` | TEXT | Bounded allowlisted method-name grammar |
| `observed_at_ms` | INTEGER | UTC epoch milliseconds |
| `expires_at_ms` | INTEGER | Must be greater than observation time |

Primary key is `(profile_id, method_name)`. A snapshot is replaced transactionally and capped at 4096 distinct method names per profile. The grammar permits TrueNAS-style dotted identifiers composed of ASCII letters, digits, `_`, and `.` with no empty segment and a bounded total length. Expired snapshots read as empty and may be removed opportunistically.

## 5. Persistence ports

The domain/controller layer depends on interfaces, not Drift classes.

```dart
abstract interface class ServerProfileStore {
  Future<ServerProfileSnapshot> load();
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile);
  Future<ServerProfileSnapshot> select(String id);
  Future<ServerProfileSnapshot> remove(String id);
  Future<void> replaceCapabilities({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  });
  Future<Set<String>> readCapabilities(String profileId, DateTime now);
  Future<void> close();
}
```

`ServerProfileSnapshot` contains ordered safe profiles and a nullable selected id. Drift transactions preserve endpoint uniqueness, first-registration order, selection, and capability cascade behavior.

A deterministic in-memory implementation remains available for unit/widget tests. Production composition injects a Drift implementation opened during app bootstrap.

## 6. Startup and controller flow

1. `main()` initializes Flutter bindings.
2. Production bootstrap opens Drift and loads the profile snapshot before rendering the app.
3. `ProviderScope` receives the opened store and initial snapshot through overrides.
4. `ServerProfilesController` starts synchronously from that snapshot, avoiding an empty-state flash.
5. Controller mutations call the store first and publish only the committed snapshot.
6. A failed write leaves the previous state intact and returns a typed, credential-free persistence failure.
7. `ConnectionController` awaits `registerAndSelect`; authentication success is not published with an unpersisted profile.
8. Selection/removal calls are serialized by the store transaction boundary. Duplicate endpoint registration preserves the original opaque id and sort position.

Database open failures are surfaced as a safe startup persistence failure. TrueDash must not silently claim that a profile was saved. Tests inject an in-memory store and do not require platform plugins.

## 7. Credential flow

### Explicit key

1. The user enters a server URL and API key.
2. On native platforms the user may opt into **Remember API key on this device**; default is off.
3. Trust orchestration runs exactly as in M1.
4. The session repository establishes the verified transport first.
5. Only after the transport exists does the repository choose the explicit key or read a remembered key from `CredentialVault`.
6. Authentication, `auth.me`, `system.info`, and `core.get_methods` must succeed.
7. If opt-in is enabled and an explicit key was supplied, the repository writes it to secure storage only after complete success.
8. The key never enters connection state, profile state, SQLite, logs, errors, analytics, or returned summaries.

### Remembered key

- The API-key field remains empty; stored secret material is never prefilled.
- Submitting an empty key requests a remembered credential.
- The vault lookup occurs inside `TrueNasSessionRepository` after the TLS/pinned connector has returned.
- Missing remembered credentials produce the existing safe credential-required failure.
- A user-supplied key always takes precedence over a remembered key.

### Key identity and deletion

The vault key is derived from the validated canonical WSS endpoint, hashed with SHA-256, and prefixed/versioned. Host text is not used directly as a secure-storage key. Removing a profile attempts to delete its remembered API key and then removes the SQLite profile. If secure deletion fails, the SQLite profile is retained and a safe retryable error is returned; this avoids orphaning a secret that the UI can no longer address.

Web exposes no remember control and uses a non-persistent vault implementation.

## 8. Capability snapshot flow

After a successful authenticated session returns `availableMethodNames`, `ConnectionController` persists that set with the profile in a bounded transaction. The initial TTL is 24 hours and uses an injected clock in tests. The cache supports feature discovery while offline, but it never proves current authorization and cannot authorize or execute an operation. Live server responses always override cached availability after reconnect.

Malformed, oversized, expired, or unknown-profile snapshots are rejected or read as empty. No arbitrary response values are stored.

## 9. Migration and integrity

- Drift schema version `1` creates all three tables, indexes, foreign keys, and check constraints.
- Foreign keys are enabled for every connection.
- Future versions must add migration tests from every supported prior schema.
- Database filenames and Web assets are fixed constants, never user-provided paths.
- Generated Drift source is committed and verified by build tooling.
- A schema export is retained for migration testing.
- Deserialization revalidates endpoint and field bounds; an invalid row is not surfaced as a `ServerProfile`.

## 10. Error and lifecycle behavior

- Database and secure-storage exception strings are never shown directly.
- Store operations return typed failures mapped to stable user-safe messages.
- Database close is owned by the root provider container and occurs exactly once.
- Late async restore/mutation results cannot update a disposed controller.
- Secure-storage writes are success-only; cancellation, trust rejection, pin mismatch, auth failure, or profile persistence failure cannot save a key.
- If secure key persistence fails after authentication, connection does not claim the key was remembered. The session may remain usable, but UI receives a safe remember-warning result distinct from authentication failure.
- Profile deletion is secret-first and transactional at the application orchestration level: secure key deletion must succeed before SQLite deletion.

## 11. A/E/X contract

### Accepted

- New and updated profiles survive a restart in stable order.
- Selected profile survives a restart.
- Valid bounded method names survive until TTL expiry.
- Native explicit opt-in stores a key only after verified successful authentication.
- Empty-key reconnect reads secure storage only after verified transport creation.
- Profile deletion removes the secure key first and then cascades SQLite capability rows.

### Error

- SQLite open/query/write failure yields a typed safe failure and preserves last committed state.
- Duplicate endpoint resolves to the first opaque profile id.
- Missing remembered key yields safe credential feedback.
- Secure write/delete failure is retryable and does not falsely report success.
- Corrupt or invalid rows do not enter application state.
- Expired capabilities read as empty.

### Excluded / forbidden

- No API key, pin, fingerprint, raw DER, arbitrary JSON/RPC response, auth header, cookie, token, identity, or native exception in SQLite.
- No vault read before a verified transport.
- No key write before full authentication and profile persistence success.
- No automatic startup login.
- No remembered-key feature on Web.
- No TLS trust bypass or downgrade.

## 12. Verification

Tests cover schema creation, constraints, transactionality, ordering, duplicate endpoint reconciliation, selection, deletion cascade, TTL, bounds, restore, disposal races, vault key derivation, success-only writes, post-TLS reads, Web prohibition, and UI opt-in behavior.

Release verification runs all Flutter/Dart suites and analyzers, Drift generation checks, Web release build, `git diff --check`, exact-SHA independent security review, branch/MR CI, and post-merge `main` CI.