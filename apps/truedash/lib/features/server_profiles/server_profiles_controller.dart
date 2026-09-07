import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../local_persistence/persistence_failure.dart';
import 'server_profile.dart';
import 'server_profile_store.dart';

/// Production bootstrap overrides this with its single opened Drift store.
final serverProfileStoreProvider = Provider<ServerProfileStore>(
  (ref) => _EphemeralServerProfileStore(),
);

/// Production bootstrap supplies the already-hydrated, immutable snapshot.
final initialServerProfileSnapshotProvider = Provider<ServerProfileSnapshot>(
  (ref) => ServerProfileSnapshot(profiles: const [], selectedProfileId: null),
);

final serverProfilesControllerProvider =
    NotifierProvider<ServerProfilesController, ServerProfilesState>(
      ServerProfilesController.new,
    );

final class ServerProfilesState {
  ServerProfilesState({
    required List<ServerProfile> profiles,
    this.selectedProfileId,
  }) : profiles = UnmodifiableListView(profiles);

  factory ServerProfilesState.fromSnapshot(ServerProfileSnapshot snapshot) =>
      ServerProfilesState(
        profiles: snapshot.profiles,
        selectedProfileId: snapshot.selectedProfileId,
      );

  final UnmodifiableListView<ServerProfile> profiles;
  final String? selectedProfileId;

  ServerProfile? get selectedProfile => switch (selectedProfileId) {
    null => null,
    final id => _profileWithId(id),
  };

  ServerProfile? _profileWithId(String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }
}

/// A contained result for UI callbacks: persistence errors never escape an
/// unawaited callback and state changes only after the store commits.
final class ServerProfilesMutationResult {
  const ServerProfilesMutationResult._(this.snapshot, this.failure);
  factory ServerProfilesMutationResult.success(
    ServerProfileSnapshot snapshot,
  ) => ServerProfilesMutationResult._(snapshot, null);
  factory ServerProfilesMutationResult.failed(
    ServerProfileSnapshot snapshot,
    PersistenceFailureKind failure,
  ) => ServerProfilesMutationResult._(snapshot, failure);

  final ServerProfileSnapshot snapshot;
  final PersistenceFailureKind? failure;
  bool get succeeded => failure == null;
}

final class ServerProfilesController extends Notifier<ServerProfilesState> {
  Future<void> _serial = Future<void>.value();
  var _disposed = false;
  var _lifecycle = 0;

  @override
  ServerProfilesState build() {
    _disposed = false;
    final lifecycle = ++_lifecycle;
    ref.onDispose(() {
      if (_lifecycle == lifecycle) _disposed = true;
      _lifecycle++;
    });
    return ServerProfilesState.fromSnapshot(
      ref.read(initialServerProfileSnapshotProvider),
    );
  }

  Future<ServerProfilesMutationResult> registerAndSelect(
    ServerProfile profile,
  ) => _mutate((store) => store.registerAndSelect(profile));

  /// Persists the profile selection and its bounded capability snapshot as one
  /// guarded store transaction. Neither store data nor Riverpod state changes
  /// when this controller or the caller's connection generation goes stale.
  Future<ServerProfilesMutationResult> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isConnectionCurrent,
  }) {
    final lifecycle = _lifecycle;
    bool isCommitValid() =>
        _isCurrent(lifecycle) && _validityOf(isConnectionCurrent);
    return _mutate(
      (store) => store.registerAndSelectWithCapabilities(
        profile: profile,
        methodNames: methodNames,
        observedAt: observedAt,
        expiresAt: expiresAt,
        isCommitValid: isCommitValid,
      ),
      isCurrent: isCommitValid,
    );
  }

  Future<ServerProfilesMutationResult> select(String id) =>
      _mutate((store) => store.select(id));

  Future<ServerProfilesMutationResult> remove(String id) =>
      _mutate((store) => store.remove(id));

  Future<ServerProfilesMutationResult> _mutate(
    Future<ServerProfileSnapshot> Function(ServerProfileStore store)
    operation, {
    bool Function()? isCurrent,
  }) {
    final before = _snapshotOf(state);
    final lifecycle = _lifecycle;
    final prior = _serial;
    final result = prior.then((_) async {
      if (!_isCurrent(lifecycle) || !_validityOf(isCurrent)) {
        return ServerProfilesMutationResult.failed(
          before,
          PersistenceFailureKind.unavailable,
        );
      }
      try {
        final committed = await operation(ref.read(serverProfileStoreProvider));
        if (!_isCurrent(lifecycle) || !_validityOf(isCurrent)) {
          return ServerProfilesMutationResult.failed(
            before,
            PersistenceFailureKind.unavailable,
          );
        }
        state = ServerProfilesState.fromSnapshot(committed);
        return ServerProfilesMutationResult.success(committed);
      } on PersistenceFailure catch (failure) {
        return ServerProfilesMutationResult.failed(before, failure.kind);
      } catch (_) {
        return ServerProfilesMutationResult.failed(
          before,
          PersistenceFailureKind.unavailable,
        );
      }
    });
    _serial = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }

  ServerProfileSnapshot _snapshotOf(ServerProfilesState value) =>
      ServerProfileSnapshot(
        profiles: value.profiles,
        selectedProfileId: value.selectedProfileId,
      );

  bool _isCurrent(int lifecycle) => !_disposed && _lifecycle == lifecycle;

  bool _validityOf(bool Function()? callback) {
    try {
      return callback?.call() ?? true;
    } catch (_) {
      return false;
    }
  }
}

/// Keeps isolated widget/unit tests usable. It is never used by production,
/// where bootstrap provides the opened Drift store and hydrated snapshot.
final class _EphemeralServerProfileStore implements ServerProfileStore {
  ServerProfileSnapshot _snapshot = ServerProfileSnapshot(
    profiles: const [],
    selectedProfileId: null,
  );

  @override
  Future<ServerProfileSnapshot> load() async => _snapshot;

  @override
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile) async {
    final profiles = [..._snapshot.profiles];
    final byId = profiles.indexWhere((item) => item.id == profile.id);
    final byEndpoint = profiles.indexWhere(
      (item) => item.normalizedEndpoint == profile.normalizedEndpoint,
    );
    final replacement = byId >= 0 ? byId : byEndpoint;
    if (replacement < 0) {
      profiles.add(profile);
      return _snapshot = ServerProfileSnapshot(
        profiles: profiles,
        selectedProfileId: profile.id,
      );
    }
    final retainedId = profiles[replacement].id;
    if (byEndpoint >= 0 && byEndpoint != replacement) {
      profiles.removeAt(byEndpoint);
    }
    final actual = profiles.indexWhere((item) => item.id == retainedId);
    profiles[actual] = ServerProfile(
      id: retainedId,
      displayName: profile.displayName,
      originalHostInput: profile.originalHostInput,
      normalizedEndpoint: profile.normalizedEndpoint,
      lastKnownVersion: profile.lastKnownVersion,
    );
    return _snapshot = ServerProfileSnapshot(
      profiles: profiles,
      selectedProfileId: retainedId,
    );
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isCommitValid,
  }) async {
    if (!isCommitValid()) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
    return registerAndSelect(profile);
  }

  @override
  Future<ServerProfileSnapshot> select(String id) async {
    if (_snapshot.profiles.every((profile) => profile.id != id)) {
      throw const PersistenceFailure(PersistenceFailureKind.notFound);
    }
    return _snapshot = ServerProfileSnapshot(
      profiles: _snapshot.profiles,
      selectedProfileId: id,
    );
  }

  @override
  Future<ServerProfileSnapshot> remove(String id) async {
    final profiles = _snapshot.profiles
        .where((profile) => profile.id != id)
        .toList();
    if (profiles.length == _snapshot.profiles.length) {
      throw const PersistenceFailure(PersistenceFailureKind.notFound);
    }
    return _snapshot = ServerProfileSnapshot(
      profiles: profiles,
      selectedProfileId: _snapshot.selectedProfileId == id
          ? (profiles.isEmpty ? null : profiles.first.id)
          : _snapshot.selectedProfileId,
    );
  }

  @override
  Future<void> replaceCapabilities({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) async {}
  @override
  Future<Set<String>> readCapabilities(String profileId, DateTime now) async =>
      const {};
  @override
  Future<void> close() async {}
}
