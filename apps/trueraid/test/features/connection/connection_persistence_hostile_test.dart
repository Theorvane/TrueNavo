import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/connection/connection_state.dart';
import 'package:trueraid/features/local_persistence/persistence_failure.dart';
import 'package:trueraid/features/server_profiles/server_profile.dart';
import 'package:trueraid/features/server_profiles/server_profile_store.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:trueraid/features/tls_trust/tls_trust_providers.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('capability write failure preserves prior profile state', () async {
    final store = ProbeStore()..failCapabilities = true;
    final container = probeContainer(store);
    addTearDown(container.dispose);

    await container
        .read(connectionControllerProvider.notifier)
        .connect(
          serverInput: 'https://nas.example',
          apiKey: 'probe-key',
          username: 'test-account',
        );

    expect(
      container.read(connectionControllerProvider),
      isA<ConnectionFailed>(),
    );
    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
  });

  test('stale connection generation cannot publish delayed profile', () async {
    final store = ProbeStore()..holdRegistration = true;
    final container = probeContainer(store);
    addTearDown(container.dispose);

    final connecting = container
        .read(connectionControllerProvider.notifier)
        .connect(
          serverInput: 'https://nas.example',
          apiKey: 'probe-key',
          username: 'test-account',
        );
    await store.registrationStarted.future;
    container.invalidate(connectionControllerProvider);
    store.releaseRegistration();
    await connecting;

    expect(container.read(connectionControllerProvider), isA<ConnectionIdle>());
    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
  });
}

ProviderContainer probeContainer(ProbeStore store) => ProviderContainer(
  overrides: [
    tlsTrustRouteProvider.overrideWithValue(TlsTrustRoute.platformValidated),
    sessionRepositoryProvider.overrideWithValue(ProbeRepository()),
    serverProfileStoreProvider.overrideWithValue(store),
    initialServerProfileSnapshotProvider.overrideWithValue(store.snapshot),
    serverProfileClockProvider.overrideWithValue(
      () => DateTime.utc(2026, 1, 1),
    ),
  ],
);

final class ProbeRepository implements SessionRepository {
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => ServerSummary(
    originalHostInput: serverInput,
    endpointUri: Uri.parse('wss://nas.example/websocket'),
    identity: 'probe',
    version: '25',
    availableMethodNames: const {'core.get_jobs'},
  );
  @override
  Future<void> close() async {}
}

final class ProbeStore implements ServerProfileStore {
  ServerProfileSnapshot snapshot = ServerProfileSnapshot(
    profiles: const [],
    selectedProfileId: null,
  );
  bool failCapabilities = false;
  bool holdRegistration = false;
  final registrationStarted = Completer<void>();
  final _registrationGate = Completer<void>();
  void releaseRegistration() => _registrationGate.complete();
  @override
  Future<ServerProfileSnapshot> load() async => snapshot;
  @override
  Future<ServerProfileSnapshot> registerAndSelect(
    ServerProfile profile,
  ) async => snapshot = ServerProfileSnapshot(
    profiles: [profile],
    selectedProfileId: profile.id,
  );
  @override
  Future<ServerProfileSnapshot> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isCommitValid,
  }) async {
    if (!registrationStarted.isCompleted) registrationStarted.complete();
    if (holdRegistration) await _registrationGate.future;
    if (!isCommitValid() || failCapabilities) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
    return snapshot = ServerProfileSnapshot(
      profiles: [profile],
      selectedProfileId: profile.id,
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
  Future<ServerProfileSnapshot> select(String id) async => snapshot;
  @override
  Future<ServerProfileSnapshot> remove(String id) async => snapshot;
  @override
  Future<Set<String>> readCapabilities(String profileId, DateTime now) async =>
      const {};
  @override
  Future<void> close() async {}
}
