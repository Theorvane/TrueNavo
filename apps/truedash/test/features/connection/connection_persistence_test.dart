import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/connection/connection_controller.dart';
import 'package:truedash/features/connection/connection_state.dart';
import 'package:truedash/features/local_persistence/persistence_failure.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profile_store.dart';
import 'package:truedash/features/server_profiles/server_profiles_controller.dart';
import 'package:truedash/features/tls_trust/tls_trust_providers.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test(
    'connection success waits for registration and capability persistence',
    () async {
      final store = _Store();
      final registration = Completer<ServerProfileSnapshot>();
      final capabilities = Completer<void>();
      store.registration = registration.future;
      store.capabilities = () => capabilities.future;
      final container = _container(store);
      addTearDown(container.dispose);
      final connect = container
          .read(connectionControllerProvider.notifier)
          .connect(serverInput: 'https://nas.example', apiKey: 'key');
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionInProgress>(),
      );
      registration.complete(_snapshot('profile-1'));
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionInProgress>(),
      );
      capabilities.complete();
      await connect;
      expect(
        container.read(connectionControllerProvider),
        isA<ConnectionSucceeded>(),
      );
      expect(store.observedAt, DateTime.utc(2026, 1, 1));
      expect(store.expiresAt, DateTime.utc(2026, 1, 2));
    },
  );

  test(
    'capability persistence failure blocks success without database detail',
    () async {
      final store = _Store()
        ..capabilities = () =>
            Future<void>.error(StateError('/raw/sqlite/path'));
      final container = _container(store);
      addTearDown(container.dispose);
      await container
          .read(connectionControllerProvider.notifier)
          .connect(serverInput: 'https://nas.example', apiKey: 'key');
      final state = container.read(connectionControllerProvider);
      expect(state, isA<ConnectionFailed>());
      expect('$state', isNot(contains('/raw/sqlite/path')));
    },
  );

  test(
    'restored profile ids are skipped before registration after restart',
    () async {
      final restored = _profile('profile-1');
      final store = _Store(
        snapshot: ServerProfileSnapshot(
          profiles: [restored],
          selectedProfileId: restored.id,
        ),
      );
      final container = _container(store);
      addTearDown(container.dispose);
      await container
          .read(connectionControllerProvider.notifier)
          .connect(serverInput: 'https://nas.example', apiKey: 'key');
      expect(store.registered!.id, 'profile-2');
    },
  );
}

ProviderContainer _container(_Store store) => ProviderContainer(
  overrides: [
    tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.platformValidated),
    sessionRepositoryProvider.overrideWithValue(_Repository()),
    serverProfileStoreProvider.overrideWithValue(store),
    initialServerProfileSnapshotProvider.overrideWithValue(store.snapshot),
    serverProfileClockProvider.overrideWithValue(
      () => DateTime.utc(2026, 1, 1),
    ),
  ],
);

ServerProfile _profile(String id) => ServerProfile(
  id: id,
  displayName: 'nas.example',
  originalHostInput: 'https://nas.example',
  normalizedEndpoint: 'wss://nas.example/websocket',
  lastKnownVersion: '25',
);
ServerProfileSnapshot _snapshot(String id) =>
    ServerProfileSnapshot(profiles: [_profile(id)], selectedProfileId: id);

final class _Store implements ServerProfileStore {
  _Store({ServerProfileSnapshot? snapshot})
    : snapshot =
          snapshot ??
          ServerProfileSnapshot(profiles: const [], selectedProfileId: null);
  ServerProfileSnapshot snapshot;
  Future<ServerProfileSnapshot>? registration;
  Future<void> Function()? capabilities;
  ServerProfile? registered;
  DateTime? observedAt;
  DateTime? expiresAt;
  @override
  Future<ServerProfileSnapshot> load() async => snapshot;
  @override
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile) {
    registered = profile;
    return registration ?? Future.value(snapshot = _snapshot(profile.id));
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isCommitValid,
  }) async {
    registered = profile;
    final result = await (registration ?? Future.value(_snapshot(profile.id)));
    if (!isCommitValid()) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
    this.observedAt = observedAt;
    this.expiresAt = expiresAt;
    await capabilities?.call();
    if (!isCommitValid()) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
    return snapshot = result;
  }

  @override
  Future<void> replaceCapabilities({
    required String profileId,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) {
    this.observedAt = observedAt;
    this.expiresAt = expiresAt;
    return capabilities?.call() ?? Future.value();
  }

  @override
  Future<ServerProfileSnapshot> select(String id) async => snapshot;
  @override
  Future<ServerProfileSnapshot> remove(String id) async => snapshot;
  @override
  Future<Set<String>> readCapabilities(String profileId, DateTime now) async =>
      const {};
  @override
  Future<void> close() async {}
}

final class _Repository implements SessionRepository {
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => ServerSummary(
    originalHostInput: 'https://nas.example',
    endpointUri: Uri.parse('wss://nas.example/websocket'),
    identity: 'nas',
    version: '25',
    availableMethodNames: const {'core.get_jobs'},
  );
  @override
  Future<void> close() async {}
}
