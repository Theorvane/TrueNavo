import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profiles_controller.dart';

ServerProfile profile(String id, String endpoint, {String? name}) =>
    ServerProfile(
      id: id,
      displayName: name ?? id,
      originalHostInput: endpoint,
      normalizedEndpoint: endpoint,
      lastKnownVersion: '25.10',
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
}
