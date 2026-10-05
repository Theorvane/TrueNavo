import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/server_profiles/server_profile.dart';
import 'package:truenavo/features/server_profiles/server_profile_store.dart';
import 'package:truenavo/features/server_profiles/server_profiles_controller.dart';

ServerProfile profile(String id, String endpoint, {String? name}) =>
    ServerProfile(
      id: id,
      displayName: name ?? id,
      originalHostInput: endpoint,
      normalizedEndpoint: endpoint,
      lastKnownVersion: '25.10',
    );

final class ControllableServerProfileStore implements ServerProfileStore {
  ControllableServerProfileStore(this.snapshot);

  ServerProfileSnapshot snapshot;
  final removeStarted = Completer<void>();
  Completer<void>? allowRemove;
  void Function()? onRemoveCommitted;
  bool failRemove = false;

  @override
  Future<ServerProfileSnapshot> load() async => snapshot;

  @override
  Future<ServerProfileSnapshot> registerAndSelect(ServerProfile profile) async {
    final profiles = [...snapshot.profiles];
    final index = profiles.indexWhere((item) => item.id == profile.id);
    if (index < 0) {
      profiles.add(profile);
    } else {
      profiles[index] = profile;
    }
    return snapshot = ServerProfileSnapshot(
      profiles: profiles,
      selectedProfileId: profile.id,
    );
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isCommitValid,
  }) => registerAndSelect(profile);

  @override
  Future<ServerProfileSnapshot> select(String id) async => snapshot;

  @override
  Future<ServerProfileSnapshot> remove(String id) async {
    removeStarted.complete();
    await allowRemove?.future;
    if (failRemove) throw StateError('durable remove failed');
    snapshot = ServerProfileSnapshot(
      profiles: snapshot.profiles.where((item) => item.id != id).toList(),
      selectedProfileId: snapshot.selectedProfileId == id
          ? null
          : snapshot.selectedProfileId,
    );
    onRemoveCommitted?.call();
    return snapshot;
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

ProviderContainer controllerContainer(ControllableServerProfileStore store) =>
    ProviderContainer(
      overrides: [
        serverProfileStoreProvider.overrideWithValue(store),
        initialServerProfileSnapshotProvider.overrideWithValue(store.snapshot),
      ],
    );

void main() {
  test(
    'upserts by endpoint in first-registration order and selects it',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(profile('one', 'wss://one'));
      await controller.registerAndSelect(profile('two', 'wss://two'));
      await controller.registerAndSelect(
        profile('replacement', 'wss://one', name: 'One'),
      );

      final state = container.read(serverProfilesControllerProvider);
      expect(state.profiles.map((item) => item.id), ['one', 'two']);
      expect(state.profiles.first.displayName, 'One');
      expect(state.selectedProfileId, 'one');
    },
  );

  test(
    'opaque ID takes precedence and endpoint collisions are removed',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(
        profile('one', 'wss://one', name: 'One'),
      );
      await controller.registerAndSelect(
        profile('two', 'wss://two', name: 'Two'),
      );

      await controller.registerAndSelect(
        profile('one', 'wss://three', name: 'Three'),
      );
      var state = container.read(serverProfilesControllerProvider);
      expect(state.profiles.map((item) => item.id), ['one', 'two']);
      expect(state.profiles.first.normalizedEndpoint, 'wss://three');
      expect(state.selectedProfileId, 'one');

      await controller.registerAndSelect(
        profile('one', 'wss://two', name: 'Merged'),
      );
      state = container.read(serverProfilesControllerProvider);
      expect(state.profiles.map((item) => item.id), ['one']);
      expect(state.profiles.single.displayName, 'Merged');
      expect(state.profiles.single.normalizedEndpoint, 'wss://two');
      expect(state.selectedProfileId, 'one');
    },
  );

  test(
    'unknown selection is unchanged and removal selects first remaining',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(profile('one', 'wss://one'));
      await controller.registerAndSelect(profile('two', 'wss://two'));
      await controller.select('missing');
      expect(
        container.read(serverProfilesControllerProvider).selectedProfileId,
        'two',
      );
      await controller.remove('two');
      expect(
        container.read(serverProfilesControllerProvider).selectedProfileId,
        'one',
      );
      await controller.remove('one');
      expect(
        container.read(serverProfilesControllerProvider).selectedProfile,
        isNull,
      );
    },
  );

  test('a new provider container starts with no profiles', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(serverProfilesControllerProvider).profiles, isEmpty);
    expect(
      container.read(serverProfilesControllerProvider).selectedProfile,
      isNull,
    );
  });

  test(
    'queued replacement before forget resolves and deletes latest endpoint',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(profile('one', 'wss://old'));

      final replacement = controller.registerAndSelect(
        profile('one', 'wss://new'),
      );
      final deleted = <String>[];
      final forget = controller.removeSecretFirst(
        profileId: 'one',
        secretAction: (current) async {
          deleted.add(current.normalizedEndpoint);
          return ServerProfilesSecretActionResult.succeeded;
        },
      );

      await replacement;
      expect(await forget, ServerProfilesGuardedRemoveResult.removed);
      expect(deleted, ['wss://new']);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
    },
  );

  test(
    'replacement queued during pending delete runs only after removal',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(profile('one', 'wss://old'));
      final delete = Completer<void>();
      final deleted = <String>[];
      final forget = controller.removeSecretFirst(
        profileId: 'one',
        secretAction: (current) async {
          deleted.add(current.normalizedEndpoint);
          await delete.future;
          return ServerProfilesSecretActionResult.succeeded;
        },
      );
      await Future<void>.delayed(Duration.zero);
      final replacement = controller.registerAndSelect(
        profile('one', 'wss://new'),
      );

      expect(deleted, ['wss://old']);
      delete.complete();
      expect(await forget, ServerProfilesGuardedRemoveResult.removed);
      await replacement;
      final state = container.read(serverProfilesControllerProvider);
      expect(state.profiles.single.normalizedEndpoint, 'wss://new');
      expect(state.selectedProfileId, 'one');
    },
  );

  test(
    'failed or throwing secret actions retain profile and release queue',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(profile('one', 'wss://old'));
      final failed = controller.removeSecretFirst(
        profileId: 'one',
        secretAction: (_) async => ServerProfilesSecretActionResult.failed,
      );
      final replacement = controller.registerAndSelect(
        profile('one', 'wss://new'),
      );
      expect(
        await failed,
        ServerProfilesGuardedRemoveResult.secretActionFailed,
      );
      await replacement;
      expect(
        container
            .read(serverProfilesControllerProvider)
            .profiles
            .single
            .normalizedEndpoint,
        'wss://new',
      );

      expect(
        await controller.removeSecretFirst(
          profileId: 'one',
          secretAction: (_) async => throw StateError('hostile callback'),
        ),
        ServerProfilesGuardedRemoveResult.secretActionFailed,
      );
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        hasLength(1),
      );
    },
  );

  test(
    'publishes the committed removal when caller becomes false post-commit',
    () async {
      final store = ControllableServerProfileStore(
        ServerProfileSnapshot(
          profiles: [profile('one', 'wss://one')],
          selectedProfileId: 'one',
        ),
      )..allowRemove = Completer<void>();
      final container = controllerContainer(store);
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      container.read(serverProfilesControllerProvider);
      var checks = 0;
      store.onRemoveCommitted = () => checks = 2;

      final removal = controller.removeSecretFirst(
        profileId: 'one',
        isCurrent: () => ++checks < 3,
        secretAction: (_) async => ServerProfilesSecretActionResult.succeeded,
      );
      await store.removeStarted.future;
      store.allowRemove!.complete();

      expect(await removal, ServerProfilesGuardedRemoveResult.removed);
      expect(checks, 2);
      expect(store.snapshot.profiles, isEmpty);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
    },
  );

  test(
    'does not invoke a throwing caller check after durable removal commits',
    () async {
      final store = ControllableServerProfileStore(
        ServerProfileSnapshot(
          profiles: [profile('one', 'wss://one')],
          selectedProfileId: 'one',
        ),
      )..allowRemove = Completer<void>();
      final container = controllerContainer(store);
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      container.read(serverProfilesControllerProvider);
      var checks = 0;
      store.onRemoveCommitted = () => checks = 2;

      final removal = controller.removeSecretFirst(
        profileId: 'one',
        isCurrent: () {
          if (++checks > 2) throw StateError('caller was queried post-commit');
          return true;
        },
        secretAction: (_) async => ServerProfilesSecretActionResult.succeeded,
      );
      await store.removeStarted.future;
      store.allowRemove!.complete();

      expect(await removal, ServerProfilesGuardedRemoveResult.removed);
      expect(checks, 2);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
    },
  );

  test(
    'caller precondition failure before remove retains the durable profile',
    () async {
      final store = ControllableServerProfileStore(
        ServerProfileSnapshot(
          profiles: [profile('one', 'wss://one')],
          selectedProfileId: 'one',
        ),
      );
      final container = controllerContainer(store);
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      container.read(serverProfilesControllerProvider);
      var checks = 0;

      final result = await controller.removeSecretFirst(
        profileId: 'one',
        isCurrent: () => ++checks == 1,
        secretAction: (_) async => ServerProfilesSecretActionResult.succeeded,
      );

      expect(result, ServerProfilesGuardedRemoveResult.preconditionFailed);
      expect(store.removeStarted.isCompleted, isFalse);
      expect(store.snapshot.profiles, hasLength(1));
    },
  );

  test('caller throwing before remove retains the durable profile', () async {
    final store = ControllableServerProfileStore(
      ServerProfileSnapshot(
        profiles: [profile('one', 'wss://one')],
        selectedProfileId: 'one',
      ),
    );
    final container = controllerContainer(store);
    addTearDown(container.dispose);
    final controller = container.read(
      serverProfilesControllerProvider.notifier,
    );
    container.read(serverProfilesControllerProvider);
    var checks = 0;

    final result = await controller.removeSecretFirst(
      profileId: 'one',
      isCurrent: () {
        if (++checks > 1) throw StateError('stale');
        return true;
      },
      secretAction: (_) async => ServerProfilesSecretActionResult.succeeded,
    );

    expect(result, ServerProfilesGuardedRemoveResult.preconditionFailed);
    expect(store.removeStarted.isCompleted, isFalse);
    expect(store.snapshot.profiles, hasLength(1));
  });

  test('durable remove failure retains the published profile', () async {
    final store = ControllableServerProfileStore(
      ServerProfileSnapshot(
        profiles: [profile('one', 'wss://one')],
        selectedProfileId: 'one',
      ),
    )..failRemove = true;
    final container = controllerContainer(store);
    addTearDown(container.dispose);
    final controller = container.read(
      serverProfilesControllerProvider.notifier,
    );
    container.read(serverProfilesControllerProvider);

    expect(
      await controller.removeSecretFirst(
        profileId: 'one',
        secretAction: (_) async => ServerProfilesSecretActionResult.succeeded,
      ),
      ServerProfilesGuardedRemoveResult.profileRemoveFailed,
    );
    expect(
      container.read(serverProfilesControllerProvider).profiles,
      hasLength(1),
    );
  });

  test(
    'disposal during a pending durable remove does not publish stale state',
    () async {
      final store = ControllableServerProfileStore(
        ServerProfileSnapshot(
          profiles: [profile('one', 'wss://one')],
          selectedProfileId: 'one',
        ),
      )..allowRemove = Completer<void>();
      final container = controllerContainer(store);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      container.read(serverProfilesControllerProvider);

      final removal = controller.removeSecretFirst(
        profileId: 'one',
        secretAction: (_) async => ServerProfilesSecretActionResult.succeeded,
      );
      await store.removeStarted.future;
      container.dispose();
      store.allowRemove!.complete();

      expect(
        await removal,
        ServerProfilesGuardedRemoveResult.preconditionFailed,
      );
      expect(store.snapshot.profiles, isEmpty);
    },
  );

  test('queued replacement observes the committed removal snapshot', () async {
    final store = ControllableServerProfileStore(
      ServerProfileSnapshot(
        profiles: [profile('one', 'wss://old')],
        selectedProfileId: 'one',
      ),
    )..allowRemove = Completer<void>();
    final container = controllerContainer(store);
    addTearDown(container.dispose);
    final controller = container.read(
      serverProfilesControllerProvider.notifier,
    );
    container.read(serverProfilesControllerProvider);

    final removal = controller.removeSecretFirst(
      profileId: 'one',
      secretAction: (_) async => ServerProfilesSecretActionResult.succeeded,
    );
    await store.removeStarted.future;
    final replacement = controller.registerAndSelect(
      profile('one', 'wss://new'),
    );
    store.allowRemove!.complete();

    expect(await removal, ServerProfilesGuardedRemoveResult.removed);
    await replacement;
    final state = container.read(serverProfilesControllerProvider);
    expect(state.profiles.single.normalizedEndpoint, 'wss://new');
    expect(store.snapshot.profiles.single.normalizedEndpoint, 'wss://new');
  });
}
