import 'package:drift/drift.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profile_store.dart';
import 'package:truenas_api/truenas_api.dart';

import 'app_database.dart';
import 'persistence_failure.dart';

final class DriftServerProfileStore implements ServerProfileStore {
  DriftServerProfileStore(this._database, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const maxCapabilities = 4096;
  static final _methodName = RegExp(r'^[A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*$');

  final AppDatabase _database;
  final DateTime Function() _clock;

  @override
  Future<ServerProfileSnapshot> load() async {
    try {
      return await _loadSnapshot();
    } on PersistenceFailure {
      rethrow;
    } catch (_) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile) async {
    _validateProfile(profile);
    try {
      return await _database.transaction(() async {
        final sameEndpoint =
            await (_database.select(_database.serverProfiles)..where(
                  (row) =>
                      row.normalizedEndpoint.equals(profile.normalizedEndpoint),
                ))
                .getSingleOrNull();
        if (sameEndpoint != null) {
          await _setSelection(sameEndpoint.id);
          return _loadSnapshot();
        }
        final sameId = await (_database.select(
          _database.serverProfiles,
        )..where((row) => row.id.equals(profile.id))).getSingleOrNull();
        if (sameId != null) {
          throw const PersistenceFailure(PersistenceFailureKind.conflict);
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
        return _loadSnapshot();
      });
    } on PersistenceFailure {
      rethrow;
    } catch (_) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
  }

  @override
  Future<ServerProfileSnapshot> select(String id) async {
    if (!_isBounded(id, 128)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
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
  }

  @override
  Future<ServerProfileSnapshot> remove(String id) async {
    if (!_isBounded(id, 128)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
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
  }

  @override
  Future<void> replaceCapabilities({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) async {
    if (!_isBounded(profileId, 128) ||
        methodNames.length > maxCapabilities ||
        !methodNames.every(_isValidMethodName) ||
        !expiresAt.isAfter(observedAt)) {
      throw const PersistenceFailure(PersistenceFailureKind.validation);
    }
    try {
      await _database.transaction(() async {
        if (!await _profileExists(profileId)) {
          throw const PersistenceFailure(PersistenceFailureKind.notFound);
        }
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
      });
    } on PersistenceFailure {
      rethrow;
    } catch (_) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
  }

  @override
  Future<Set<String>> readCapabilities(String profileId, DateTime now) async {
    if (!_isBounded(profileId, 128)) {
      return const <String>{};
    }
    try {
      final nowMs = now.toUtc().millisecondsSinceEpoch;
      return await _database.transaction(() async {
        await (_database.delete(_database.profileCapabilities)..where(
              (row) =>
                  row.profileId.equals(profileId) &
                  row.expiresAtMs.isSmallerOrEqualValue(nowMs),
            ))
            .go();
        final rows =
            await (_database.select(_database.profileCapabilities)..where(
                  (row) =>
                      row.profileId.equals(profileId) &
                      row.expiresAtMs.isBiggerThanValue(nowMs),
                ))
                .get();
        return Set.unmodifiable(rows.map((row) => row.methodName));
      });
    } on PersistenceFailure {
      rethrow;
    } catch (_) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
  }

  @override
  Future<void> close() => _database.close();

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
      value.isNotEmpty && value.length <= max;
  static bool _isValidMethodName(String value) =>
      value.length <= 255 && _methodName.hasMatch(value);
}
