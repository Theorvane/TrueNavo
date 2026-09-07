import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/persistence_failure.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profile_store.dart';
import 'package:truedash/features/server_profiles/server_profiles_controller.dart';

void main() {
  test(
    'hydrates directly from the injected snapshot without an empty state',
    () {
      final restored = _profile('profile-7', 'seven.example');
      final store = _Store(
        ServerProfileSnapshot(
          profiles: [restored],
          selectedProfileId: restored.id,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          serverProfileStoreProvider.overrideWithValue(store),
          initialServerProfileSnapshotProvider.overrideWithValue(
            store.snapshot,
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(serverProfilesControllerProvider).profiles, [
        restored,
      ]);
      expect(
        container.read(serverProfilesControllerProvider).selectedProfileId,
        restored.id,
      );
    },
  );

  test(
    'publishes only the committed snapshot and serializes mutations',
    () async {
      final store = _Store(
        ServerProfileSnapshot(profiles: const [], selectedProfileId: null),
      );
      final first = Completer<ServerProfileSnapshot>();
      store.registerResults.add(() => first.future);
      store.registerResults.add(
        () => Future.value(
          ServerProfileSnapshot(
            profiles: [
              _profile('one', 'one.example'),
              _profile('two', 'two.example'),
            ],
            selectedProfileId: 'two',
          ),
        ),
      );
      final container = _container(store);
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );

      final one = controller.registerAndSelect(_profile('one', 'one.example'));
      final two = controller.registerAndSelect(_profile('two', 'two.example'));
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      await Future<void>.delayed(Duration.zero);
      expect(store.registerCalls, 1);
      first.complete(
        ServerProfileSnapshot(
          profiles: [_profile('one', 'one.example')],
          selectedProfileId: 'one',
        ),
      );
      await one;
      await two;

      expect(store.registerCalls, 2);
      expect(
        container.read(serverProfilesControllerProvider).selectedProfileId,
        'two',
      );
    },
  );

  test('write failure preserves state and returns a typed result', () async {
    final initial = _profile('one', 'one.example');
    final store =
        _Store(
            ServerProfileSnapshot(
              profiles: [initial],
              selectedProfileId: initial.id,
            ),
          )
          ..registerResults.add(
            () => Future<ServerProfileSnapshot>.error(
              const PersistenceFailure(PersistenceFailureKind.unavailable),
            ),
          );
    final container = _container(store);
    addTearDown(container.dispose);

    final result = await container
        .read(serverProfilesControllerProvider.notifier)
        .registerAndSelect(_profile('two', 'two.example'));
    expect(result.failure, PersistenceFailureKind.unavailable);
    expect(container.read(serverProfilesControllerProvider).profiles, [
      initial,
    ]);
  });

  test('late store completion cannot publish after disposal', () async {
    final store = _Store(
      ServerProfileSnapshot(profiles: const [], selectedProfileId: null),
    );
    final pending = Completer<ServerProfileSnapshot>();
    store.registerResults.add(() => pending.future);
    final container = _container(store);
    final controller = container.read(
      serverProfilesControllerProvider.notifier,
    );
    final mutation = controller.registerAndSelect(
      _profile('one', 'one.example'),
    );
    container.dispose();
    pending.complete(
      ServerProfileSnapshot(
        profiles: [_profile('one', 'one.example')],
        selectedProfileId: 'one',
      ),
    );
    final result = await mutation;
    expect(result.failure, PersistenceFailureKind.unavailable);
  });
}

ProviderContainer _container(_Store store) => ProviderContainer(
  overrides: [
    serverProfileStoreProvider.overrideWithValue(store),
    initialServerProfileSnapshotProvider.overrideWithValue(store.snapshot),
  ],
);

ServerProfile _profile(String id, String host) => ServerProfile(
  id: id,
  displayName: host,
  originalHostInput: 'https://$host',
  normalizedEndpoint: 'wss://$host/websocket',
  lastKnownVersion: '25.10',
);

final class _Store implements ServerProfileStore {
  _Store(this.snapshot);
  ServerProfileSnapshot snapshot;
  final Queue<Future<ServerProfileSnapshot> Function()> registerResults =
      Queue();
  int registerCalls = 0;
  @override
  Future<ServerProfileSnapshot> load() async => snapshot;
  @override
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile) {
    registerCalls++;
    return registerResults.isEmpty
        ? Future.value(snapshot)
        : registerResults.removeFirst()();
  }

  @override
  Future<ServerProfileSnapshot> select(String id) async => snapshot;
  @override
  Future<ServerProfileSnapshot> remove(String id) async => snapshot;
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
