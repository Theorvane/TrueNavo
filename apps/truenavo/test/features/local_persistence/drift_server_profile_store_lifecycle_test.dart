import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/local_persistence/app_database.dart';
import 'package:truenavo/features/local_persistence/drift_server_profile_store.dart';
import 'package:truenavo/features/local_persistence/persistence_failure.dart';
import 'package:truenavo/features/server_profiles/server_profile.dart';
import 'package:truenavo/features/server_profiles/server_profile_store.dart';
import 'package:truenavo/features/server_profiles/server_profiles_controller.dart';

void main() {
  ServerProfile profile(String id, String host) => ServerProfile(
    id: id,
    displayName: host,
    originalHostInput: 'https://$host',
    normalizedEndpoint: 'wss://$host/api/current',
    lastKnownVersion: '25',
  );

  ProviderContainer containerFor(DriftServerProfileStore store) =>
      ProviderContainer(
        overrides: [
          serverProfileStoreProvider.overrideWithValue(store),
          initialServerProfileSnapshotProvider.overrideWithValue(
            ServerProfileSnapshot(profiles: const [], selectedProfileId: null),
          ),
        ],
      );

  test(
    'invalidation queued by final validity check prevents durable commit',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final store = DriftServerProfileStore(
        database,
        clock: () => DateTime.utc(2026),
      );
      addTearDown(store.close);
      late ProviderContainer container;
      var checks = 0;
      container = containerFor(store);
      addTearDown(container.dispose);

      final result = await container
          .read(serverProfilesControllerProvider.notifier)
          .registerAndSelectWithCapabilities(
            profile: profile('stale', 'stale.example'),
            methodNames: const {'core.get_methods'},
            observedAt: DateTime.utc(2026, 1, 1),
            expiresAt: DateTime.utc(2026, 1, 2),
            isConnectionCurrent: () {
              if (++checks == 3) {
                scheduleMicrotask(
                  () => container.invalidate(serverProfilesControllerProvider),
                );
              }
              return true;
            },
          );
      expect(result.failure, PersistenceFailureKind.unavailable);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
      expect((await store.load()).profiles, isEmpty);
      expect(
        await store.readCapabilities('stale', DateTime.utc(2026, 1, 1)),
        isEmpty,
      );
    },
  );

  test(
    'stale compensation cannot overwrite a recreated controller mutation',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final store = DriftServerProfileStore(
        database,
        clock: () => DateTime.utc(2026),
      );
      addTearDown(store.close);
      late ProviderContainer container;
      final secondCompleted = Completer<ServerProfileSnapshot>();
      var checks = 0;
      container = containerFor(store);
      addTearDown(container.dispose);

      final first = container
          .read(serverProfilesControllerProvider.notifier)
          .registerAndSelectWithCapabilities(
            profile: profile('stale', 'stale.example'),
            methodNames: const {'core.get_methods'},
            observedAt: DateTime.utc(2026, 1, 1),
            expiresAt: DateTime.utc(2026, 1, 2),
            isConnectionCurrent: () {
              if (++checks == 3) {
                scheduleMicrotask(() {
                  container.invalidate(serverProfilesControllerProvider);
                  unawaited(
                    store
                        .registerAndSelectWithCapabilities(
                          profile: profile('current', 'current.example'),
                          methodNames: const {'system.info'},
                          observedAt: DateTime.utc(2026, 1, 1),
                          expiresAt: DateTime.utc(2026, 1, 2),
                          isCommitValid: () => true,
                        )
                        .then(secondCompleted.complete),
                  );
                });
              }
              return true;
            },
          );

      expect((await first).failure, PersistenceFailureKind.unavailable);
      expect((await secondCompleted.future).selectedProfileId, 'current');
      final durable = await store.load();
      expect(durable.profiles.map((item) => item.id), ['current']);
      expect(durable.selectedProfileId, 'current');
      expect(
        await store.readCapabilities('current', DateTime.utc(2026, 1, 1)),
        {'system.info'},
      );
      expect(
        await store.readCapabilities('stale', DateTime.utc(2026, 1, 1)),
        isEmpty,
      );
    },
  );

  test(
    'post-commit invalidation restores the complete prior durable snapshot',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final store = DriftServerProfileStore(
        database,
        clock: () => DateTime.utc(2026),
      );
      addTearDown(store.close);
      final observedAt = DateTime.utc(2026, 1, 1);
      await store.registerAndSelectWithCapabilities(
        profile: profile('prior', 'prior.example'),
        methodNames: const {'prior.method'},
        observedAt: observedAt,
        expiresAt: DateTime.utc(2026, 1, 2),
        isCommitValid: () => true,
      );
      var valid = true;
      var checks = 0;

      await expectLater(
        store.registerAndSelectWithCapabilities(
          profile: profile('stale', 'stale.example'),
          methodNames: const {'stale.method'},
          observedAt: observedAt,
          expiresAt: DateTime.utc(2026, 1, 2),
          isCommitValid: () {
            if (++checks == 2) scheduleMicrotask(() => valid = false);
            return valid;
          },
        ),
        throwsA(isA<PersistenceFailure>()),
      );

      final restored = await store.load();
      expect(restored.profiles.map((item) => item.id), ['prior']);
      expect(restored.selectedProfileId, 'prior');
      expect(await store.readCapabilities('prior', observedAt), {
        'prior.method',
      });
      expect(await store.readCapabilities('stale', observedAt), isEmpty);
    },
  );
}
