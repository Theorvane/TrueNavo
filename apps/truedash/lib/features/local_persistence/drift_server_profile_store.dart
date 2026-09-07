import 'dart:async';

import 'package:drift/drift.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profile_store.dart';
import 'package:truenas_api/truenas_api.dart';

import 'app_database.dart';
import 'persistence_failure.dart';

final class _PersistedState {
  const _PersistedState({
    required this.profiles,
    required this.selection,
    required this.capabilities,
  });

  final List<StoredServerProfile> profiles;
  final AppSelectionData? selection;
  final List<ProfileCapability> capabilities;
}

final class DriftServerProfileStore implements ServerProfileStore {
  DriftServerProfileStore(this._database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _ownerZone = Zone.current;

  static const maxCapabilities = 4096;
  static final _methodName = RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*$');

  final AppDatabase _database;
  final DateTime Function() _clock;
  final Zone _ownerZone;
  // Every public operation takes this store-owned lease. In particular, a
  // stale guarded commit restores its exact prior state before a later,
  // recreated controller can begin its own mutation.
  Future<void> _lease = Future<void>.value();
  Future<void>? _closeFuture;
  bool _isClosed = false;

  @override
  Future<ServerProfileSnapshot> load() async {
    return _withLease(() async {
      try {
        return await _loadSnapshot();
      } on PersistenceFailure {
        rethrow;
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    });
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile) async {
    _validateProfile(profile);
    return _withLease(() async {
      try {
        return await _database.transaction(() async {
          await _upsertAndSelect(profile);
          return _loadSnapshot();
        });
      } on PersistenceFailure {
        rethrow;
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    });
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isCommitValid,
  }) async {
    _validateProfile(profile);
    _validateCapabilities(
      methodNames: methodNames,
      observedAt: observedAt,
      expiresAt: expiresAt,
    );
    return _withLease(() async {
      try {
        // Keep a complete, store-private restore point while holding the
        // lease. It includes selection and every capability row, not just the
        // profile being registered.
        final prior = await _captureState();
        final committed = await _database.transaction(() async {
          if (!_isCommitValid(isCommitValid)) {
            throw const PersistenceFailure(PersistenceFailureKind.unavailable);
          }
          final retainedId = await _upsertAndSelect(profile);
          await _replaceCapabilitiesForExistingProfile(
            profileId: retainedId,
            methodNames: methodNames,
            observedAt: observedAt,
            expiresAt: expiresAt,
          );
          final snapshot = await _loadSnapshot();
          // This early guard avoids committing a lifecycle already known to
          // be stale. The post-transaction guard below closes the commit
          // TOCTOU.
          if (!_isCommitValid(isCommitValid)) {
            throw const PersistenceFailure(PersistenceFailureKind.unavailable);
          }
          return snapshot;
        });

        // Drift has actually committed when transaction completes. This is
        // the linearization point: a revoked lifecycle observed here wins and
        // is compensated before this lease permits another store operation.
        if (!_isCommitValid(isCommitValid)) {
          await _database.transaction(() => _restoreState(prior));
          throw const PersistenceFailure(PersistenceFailureKind.unavailable);
        }
        return committed;
      } on PersistenceFailure {
        rethrow;
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    });
  }

  @override
  Future<ServerProfileSnapshot> select(String id) async {
    if (!_isBounded(id, 128)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
    return _withLease(() async {
      try {
        return await _database.transaction(() async {
          if (!await _profileExists(id)) {
            throw const PersistenceFailure(PersistenceFailureKind.notFound);
          }
          await _setSelection(id);
          return _loadSnapshot();
        });
      } on PersistenceFailure {
        rethrow;
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    });
  }

  @override
  Future<ServerProfileSnapshot> remove(String id) async {
    if (!_isBounded(id, 128)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
    return _withLease(() async {
      try {
        return await _database.transaction(() async {
          if (!await _profileExists(id)) {
            throw const PersistenceFailure(PersistenceFailureKind.notFound);
          }
          await (_database.delete(
            _database.serverProfiles,
          )..where((row) => row.id.equals(id))).go();
          final selected = await _selectedId();
          if (selected == null) {
            final first =
                await (_database.select(_database.serverProfiles)
                      ..orderBy([(row) => OrderingTerm.asc(row.sortOrder)])
                      ..limit(1))
                    .getSingleOrNull();
            await _setSelection(first?.id);
          }
          return _loadSnapshot();
        });
      } on PersistenceFailure {
        rethrow;
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    });
  }

  @override
  Future<void> replaceCapabilities({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) async {
    if (!_isBounded(profileId, 128)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
    _validateCapabilities(
      methodNames: methodNames,
      observedAt: observedAt,
      expiresAt: expiresAt,
    );
    return _withLease(() async {
      try {
        await _database.transaction(() async {
          if (!await _profileExists(profileId)) {
            throw const PersistenceFailure(PersistenceFailureKind.notFound);
          }
          await _replaceCapabilitiesForExistingProfile(
            profileId: profileId,
            methodNames: methodNames,
            observedAt: observedAt,
            expiresAt: expiresAt,
          );
        });
      } on PersistenceFailure {
        rethrow;
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    });
  }

  @override
  Future<Set<String>> readCapabilities(String profileId, DateTime now) async {
    if (!_isBounded(profileId, 128)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
    return _withLease(() async {
      try {
        final nowMs = now.toUtc().millisecondsSinceEpoch;
        return await _database.transaction(() async {
          final storedRows =
              await (_database.select(_database.profileCapabilities)
                    ..where((row) => row.profileId.equals(profileId))
                    ..limit(maxCapabilities + 1))
                  .get();
          if (storedRows.length > maxCapabilities ||
              storedRows.any((row) => !_isValidCapabilityRow(row))) {
            throw const PersistenceFailure(PersistenceFailureKind.unavailable);
          }
          await (_database.delete(_database.profileCapabilities)..where(
                (row) =>
                    row.profileId.equals(profileId) &
                    row.expiresAtMs.isSmallerOrEqualValue(nowMs),
              ))
              .go();
          return Set.unmodifiable(
            storedRows
                .where((row) => row.expiresAtMs > nowMs)
                .map((row) => row.methodName),
          );
        });
      } on PersistenceFailure {
        rethrow;
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    });
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _isClosed = true;
    final closing = _ownerZone.run(() async {
      await _lease;
      await _database.close();
    });
    _closeFuture = closing;
    return closing;
  }

  Future<T> _withLease<T>(Future<T> Function() operation) {
    // A validity callback runs inside Drift's transaction zone. Registering a
    // queued mutation from that callback must not retain the transaction's
    // executor after it commits, so all lease continuations run in the zone
    // that owns this store.
    return _ownerZone.run(() {
      if (_isClosed) {
        return Future<T>.error(
          const PersistenceFailure(PersistenceFailureKind.unavailable),
        );
      }
      final result = _lease.then((_) => operation());
      _lease = result.then<void>((_) {}, onError: (_, _) {});
      return result;
    });
  }

  Future<_PersistedState> _captureState() async => _PersistedState(
    profiles: await _database.select(_database.serverProfiles).get(),
    selection: await _database.select(_database.appSelection).getSingleOrNull(),
    capabilities: await _database.select(_database.profileCapabilities).get(),
  );

  Future<void> _restoreState(_PersistedState prior) async {
    await _database.delete(_database.profileCapabilities).go();
    await _database.delete(_database.appSelection).go();
    await _database.delete(_database.serverProfiles).go();
    for (final profile in prior.profiles) {
      await _database
          .into(_database.serverProfiles)
          .insert(
            ServerProfilesCompanion.insert(
              id: profile.id,
              displayName: profile.displayName,
              originalHostInput: profile.originalHostInput,
              normalizedEndpoint: profile.normalizedEndpoint,
              lastKnownVersion: profile.lastKnownVersion,
              createdAtMs: profile.createdAtMs,
              updatedAtMs: profile.updatedAtMs,
              sortOrder: profile.sortOrder,
            ),
          );
    }
    final selection = prior.selection;
    if (selection != null) {
      await _database
          .into(_database.appSelection)
          .insert(
            AppSelectionCompanion.insert(
              singletonId: Value(selection.singletonId),
              selectedProfileId: Value(selection.selectedProfileId),
            ),
          );
    }
    for (final capability in prior.capabilities) {
      await _database
          .into(_database.profileCapabilities)
          .insert(
            ProfileCapabilitiesCompanion.insert(
              profileId: capability.profileId,
              methodName: capability.methodName,
              observedAtMs: capability.observedAtMs,
              expiresAtMs: capability.expiresAtMs,
            ),
          );
    }
  }

  Future<ServerProfileSnapshot> _loadSnapshot() async {
    final rows = await (_database.select(
      _database.serverProfiles,
    )..orderBy([(row) => OrderingTerm.asc(row.sortOrder)])).get();
    final profiles = <ServerProfile>[];
    for (final row in rows) {
      try {
        profiles.add(_mapProfile(row));
      } catch (_) {
        throw const PersistenceFailure(PersistenceFailureKind.unavailable);
      }
    }
    final selectedId = await _selectedId();
    return ServerProfileSnapshot(
      profiles: profiles,
      selectedProfileId: profiles.any((profile) => profile.id == selectedId)
          ? selectedId
          : null,
    );
  }

  ServerProfile _mapProfile(StoredServerProfile row) {
    final profile = ServerProfile(
      id: row.id,
      displayName: row.displayName,
      originalHostInput: row.originalHostInput,
      normalizedEndpoint: row.normalizedEndpoint,
      lastKnownVersion: row.lastKnownVersion,
    );
    _validateProfile(profile);
    return profile;
  }

  Future<bool> _profileExists(String id) async =>
      await (_database.select(
        _database.serverProfiles,
      )..where((row) => row.id.equals(id))).getSingleOrNull() !=
      null;

  Future<String?> _selectedId() async =>
      (await _database.select(_database.appSelection).getSingleOrNull())
          ?.selectedProfileId;

  Future<void> _setSelection(String? id) => _database
      .into(_database.appSelection)
      .insertOnConflictUpdate(
        AppSelectionCompanion(
          singletonId: const Value(1),
          selectedProfileId: Value(id),
        ),
      );

  Future<void> _updateProfile(String retainedId, ServerProfile profile) =>
      (_database.update(
        _database.serverProfiles,
      )..where((row) => row.id.equals(retainedId))).write(
        ServerProfilesCompanion(
          displayName: Value(profile.displayName),
          originalHostInput: Value(profile.originalHostInput),
          normalizedEndpoint: Value(profile.normalizedEndpoint),
          lastKnownVersion: Value(profile.lastKnownVersion),
          updatedAtMs: Value(_clock().toUtc().millisecondsSinceEpoch),
        ),
      );

  Future<String> _upsertAndSelect(ServerProfile profile) async {
    final sameId = await (_database.select(
      _database.serverProfiles,
    )..where((row) => row.id.equals(profile.id))).getSingleOrNull();
    final sameEndpoint =
        await (_database.select(_database.serverProfiles)..where(
              (row) =>
                  row.normalizedEndpoint.equals(profile.normalizedEndpoint),
            ))
            .getSingleOrNull();

    // The opaque id is authoritative when it collides. Deleting a different
    // endpoint row first keeps the following update valid and lets SQLite
    // cascade its old capability snapshot in this same transaction.
    if (sameId != null) {
      if (sameEndpoint != null && sameEndpoint.id != sameId.id) {
        await (_database.delete(
          _database.serverProfiles,
        )..where((row) => row.id.equals(sameEndpoint.id))).go();
      }
      await _updateProfile(sameId.id, profile);
      await _setSelection(sameId.id);
      return sameId.id;
    }
    if (sameEndpoint != null) {
      await _updateProfile(sameEndpoint.id, profile);
      await _setSelection(sameEndpoint.id);
      return sameEndpoint.id;
    }
    final last =
        await (_database.select(_database.serverProfiles)
              ..orderBy([(row) => OrderingTerm.desc(row.sortOrder)])
              ..limit(1))
            .getSingleOrNull();
    final now = _clock().toUtc().millisecondsSinceEpoch;
    await _database
        .into(_database.serverProfiles)
        .insert(
          ServerProfilesCompanion.insert(
            id: profile.id,
            displayName: profile.displayName,
            originalHostInput: profile.originalHostInput,
            normalizedEndpoint: profile.normalizedEndpoint,
            lastKnownVersion: profile.lastKnownVersion,
            createdAtMs: now,
            updatedAtMs: now,
            sortOrder: (last?.sortOrder ?? -1) + 1,
          ),
        );
    await _setSelection(profile.id);
    return profile.id;
  }

  Future<void> _replaceCapabilitiesForExistingProfile({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) async {
    await (_database.delete(
      _database.profileCapabilities,
    )..where((row) => row.profileId.equals(profileId))).go();
    final observed = observedAt.toUtc().millisecondsSinceEpoch;
    final expires = expiresAt.toUtc().millisecondsSinceEpoch;
    await _database.batch((batch) {
      batch.insertAll(
        _database.profileCapabilities,
        methodNames.map(
          (name) => ProfileCapabilitiesCompanion.insert(
            profileId: profileId,
            methodName: name,
            observedAtMs: observed,
            expiresAtMs: expires,
          ),
        ),
      );
    });
  }

  void _validateCapabilities({
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) {
    if (methodNames.length > maxCapabilities ||
        !methodNames.every(_isValidMethodName) ||
        !expiresAt.isAfter(observedAt)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
  }

  bool _isCommitValid(bool Function() callback) {
    try {
      return callback();
    } catch (_) {
      return false;
    }
  }

  void _validateProfile(ServerProfile profile) {
    if (!_isBounded(profile.id, 128) ||
        !_isBounded(profile.displayName, 256) ||
        !_isBounded(profile.originalHostInput, 2048) ||
        !_isBounded(profile.normalizedEndpoint, 2048) ||
        !_isBounded(profile.lastKnownVersion, 128)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
    try {
      final endpoint = ValidatedEndpoint.parse(profile.originalHostInput);
      if (endpoint.connectionUri.toString() != profile.normalizedEndpoint) {
        throw const PersistenceFailure(PersistenceFailureKind.validation);
      }
    } on EndpointValidationException {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
  }

  static bool _isBounded(String value, int max) =>
      value.isNotEmpty &&
      value.length <= max &&
      !_containsUnsafePersistentContent(value);
  static bool _isValidMethodName(String value) =>
      value.length <= 255 &&
      _methodName.hasMatch(value) &&
      (_isDocumentedSensitiveMethodName(value) ||
          !_containsUnsafePersistentContent(value));

  static bool _isDocumentedSensitiveMethodName(String value) => switch (value) {
    'auth.generate_token' || 'auth.login_with_api_key' => true,
    _ => false,
  };

  static bool _isValidCapabilityRow(ProfileCapability row) =>
      _isBounded(row.profileId, 128) &&
      _isValidMethodName(row.methodName) &&
      row.expiresAtMs > row.observedAtMs;

  /// The persistence model has no secret or unstructured payload fields.
  /// Keep this deliberately narrow so ordinary hosts, versions and RPC names
  /// remain valid while obvious credential material fails before a transaction.
  static bool _containsUnsafePersistentContent(String value) {
    final trimmed = value.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) return true;
    if (value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return true;
    }
    return RegExp(
      r'(?:api[_ -]?key(?:[ _:=]|$)|authorization(?:[ _:=]|$)|'
      r'auth[_ -]?header(?:[ _:=]|$)|bearer[ _-]|'
      r'password(?:[ _:=]|$)|secret(?:[ _:=]|$)|'
      r'token(?:[ _:=]|$)|AIza[\w-]{8,}|-----BEGIN)',
      caseSensitive: false,
    ).hasMatch(value);
  }
}
