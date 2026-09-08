import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/app_shell/adaptive_shell.dart';
import 'package:truedash/features/credentials/credential_vault_provider.dart';
import 'package:truedash/features/local_persistence/persistence_failure.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profile_store.dart';
import 'package:truedash/features/server_profiles/server_profiles_controller.dart';
import 'package:truedash/features/server_profiles/server_switcher.dart';
import 'package:truedash_design_system/truedash_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  testWidgets('switches displayed context only and explains its limit', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(
      serverProfilesControllerProvider.notifier,
    );
    await controller.registerAndSelect(
      const ServerProfile(
        id: 'one',
        displayName: 'One',
        originalHostInput: 'one',
        normalizedEndpoint: 'wss://one',
        lastKnownVersion: '1',
      ),
    );
    await controller.registerAndSelect(
      const ServerProfile(
        id: 'two',
        displayName: 'Two',
        originalHostInput: 'two',
        normalizedEndpoint: 'wss://two',
        lastKnownVersion: '1',
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: TrueDashTheme.light(),
          home: const AdaptiveShell(),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Choose server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('One').last);
    await tester.pump();
    expect(find.text('One'), findsWidgets);
    expect(
      find.text('Server switching is display-only and does not reconnect.'),
      findsOneWidget,
    );
    expect(
      container.read(serverProfilesControllerProvider).profiles,
      hasLength(2),
    );
  });

  testWidgets('empty catalog describes the saved empty state', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: TrueDashTheme.light(),
          home: const AdaptiveShell(),
        ),
      ),
    );

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('server-catalog-trigger')),
        matching: find.text('No server selected'),
      ),
      findsOneWidget,
    );
    expect(find.text('Home needs a server connection'), findsOneWidget);
    expect(find.bySemanticsLabel('Server catalog: empty'), findsOneWidget);
    expect(find.text('No saved server profile is selected.'), findsOneWidget);
    expect(find.text('Return to connection'), findsOneWidget);
    expect(find.textContaining('Add server'), findsNothing);
    handle.dispose();
  });

  testWidgets(
    'forgetting a profile deletes its credential before profile removal',
    (tester) async {
      final vault = _RecordingVault();
      final container = ProviderContainer(
        overrides: [credentialVaultProvider.overrideWithValue(vault)],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(_profile);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: TrueDashTheme.light(),
            home: const AdaptiveShell(),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Choose server'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('forget-profile-one')));
      await tester.pumpAndSettle();
      expect(vault.deleted, ['wss://one/api/current']);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
    },
  );

  testWidgets(
    'stale open popup forget never deletes the replaced endpoint credential',
    (tester) async {
      final vault = _RecordingVault();
      final container = ProviderContainer(
        overrides: [credentialVaultProvider.overrideWithValue(vault)],
      );
      addTearDown(container.dispose);
      final controller = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await controller.registerAndSelect(
        const ServerProfile(
          id: 'one',
          displayName: 'Old one',
          originalHostInput: 'old',
          normalizedEndpoint: 'wss://old.example/api/current',
          lastKnownVersion: '1',
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: TrueDashTheme.light(),
            home: const Scaffold(body: ServerSwitcher()),
          ),
        ),
      );

      await _openCatalog(tester);
      await controller.registerAndSelect(
        const ServerProfile(
          id: 'one',
          displayName: 'New one',
          originalHostInput: 'new',
          normalizedEndpoint: 'wss://new.example/api/current',
          lastKnownVersion: '1',
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('forget-profile-one')));
      await tester.pumpAndSettle();

      expect(vault.deleted, isNot(contains('wss://old.example/api/current')));
      expect(vault.deleted, ['wss://new.example/api/current']);
      expect(
        container.read(serverProfilesControllerProvider).profiles,
        isEmpty,
      );
    },
  );

  testWidgets(
    'delete failure retains the profile, selection, and a live error',
    (tester) async {
      final vault = _RecordingVault(throwsOnDelete: true);
      final store = _Store(snapshot: _snapshot([_profile], selected: 'one'));
      final handle = tester.ensureSemantics();
      await _pumpSwitcher(tester, vault: vault, store: store);

      await _forget(tester);

      expect(vault.deleted, ['wss://one/api/current']);
      expect(store.removes, isEmpty);
      expect(
        find.text('Could not forget the saved credential. Try again.'),
        findsOneWidget,
      );
      final error = find.bySemanticsLabel(
        'Could not forget the saved credential. Try again.',
      );
      expect(error, findsOneWidget);
      expect(tester.getSemantics(error).flagsCollection.isLiveRegion, isTrue);
      expect(find.bySemanticsLabel('wss://one/api/current'), findsNothing);
      expect(find.textContaining('wss://one/api/current'), findsNothing);
      expect(find.bySemanticsLabel('Choose server'), findsOneWidget);
      expect(
        tester
            .getSemantics(find.bySemanticsLabel('Choose server'))
            .flagsCollection
            .isButton,
        isTrue,
      );
      expect(
        find.bySemanticsLabel('Choose server').evaluate().single,
        isNot(same(error.evaluate().single)),
      );
      expect(store.snapshot.selectedProfileId, 'one');
      handle.dispose();
    },
  );

  testWidgets(
    'store failure reports forgotten credential and never restores it',
    (tester) async {
      final vault = _RecordingVault();
      final store = _Store(
        snapshot: _snapshot([_profile], selected: 'one'),
        failRemove: true,
      );
      await _pumpSwitcher(tester, vault: vault, store: store);

      await _forget(tester);

      expect(vault.deleted, ['wss://one/api/current']);
      expect(vault.written, isEmpty);
      expect(store.removes, ['one']);
      expect(
        find.text(
          'Credential forgotten, but the saved server remains. Try again.',
        ),
        findsOneWidget,
      );
      expect(store.snapshot.profiles, [_profile]);
      expect(store.snapshot.selectedProfileId, 'one');
    },
  );

  testWidgets('pending forget disables its trigger and cannot delete twice', (
    tester,
  ) async {
    final delete = Completer<void>();
    final vault = _RecordingVault(deleteCompleter: delete);
    final store = _Store(snapshot: _snapshot([_profile], selected: 'one'));
    await _pumpSwitcher(tester, vault: vault, store: store);

    await _openCatalog(tester);
    await tester.tap(find.byKey(const Key('forget-profile-one')));
    await tester.pump();
    expect(vault.deleted, ['wss://one/api/current']);
    expect(store.removes, isEmpty);
    final popup = find.byWidgetPredicate((widget) => widget is PopupMenuButton);
    expect(tester.widget<PopupMenuButton>(popup).enabled, isFalse);
    await tester.tap(find.bySemanticsLabel('Choose server'));
    await tester.pump();
    expect(vault.deleted, ['wss://one/api/current']);
    expect(store.removes, isEmpty);

    delete.complete();
    await tester.pumpAndSettle();
    expect(store.removes, ['one']);
  });

  testWidgets('successful forget removes after delete and selects fallback', (
    tester,
  ) async {
    final events = <String>[];
    final vault = _RecordingVault(events: events);
    final store = _Store(
      snapshot: _snapshot([_profile, _profileTwo], selected: 'one'),
      events: events,
    );
    await _pumpSwitcher(tester, vault: vault, store: store);

    await _forget(tester);

    expect(events, ['delete:wss://one/api/current', 'remove:one']);
    expect(store.snapshot.profiles, [_profileTwo]);
    expect(store.snapshot.selectedProfileId, 'two');
  });

  testWidgets('malformed endpoint does not call vault or store', (
    tester,
  ) async {
    final vault = _RecordingVault();
    final malformed = ServerProfile(
      id: 'bad',
      displayName: 'Bad',
      originalHostInput: 'bad',
      normalizedEndpoint: ' https://bad ',
      lastKnownVersion: '1',
    );
    final store = _Store(snapshot: _snapshot([malformed], selected: 'bad'));
    await _pumpSwitcher(tester, vault: vault, store: store);

    await _forget(tester, profileId: 'bad');

    expect(vault.deleted, isEmpty);
    expect(store.removes, isEmpty);
    expect(
      find.text('This saved server cannot be forgotten safely. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets('disposing during a pending delete performs no later removal', (
    tester,
  ) async {
    final delete = Completer<void>();
    final vault = _RecordingVault(deleteCompleter: delete);
    final store = _Store(snapshot: _snapshot([_profile], selected: 'one'));
    await _pumpSwitcher(tester, vault: vault, store: store);

    await _openCatalog(tester);
    await tester.tap(find.byKey(const Key('forget-profile-one')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    delete.complete();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(store.removes, isEmpty);
  });
}

const _profile = ServerProfile(
  id: 'one',
  displayName: 'One',
  originalHostInput: 'one',
  normalizedEndpoint: 'wss://one/api/current',
  lastKnownVersion: '1',
);

final class _RecordingVault implements CredentialVault {
  _RecordingVault({
    this.throwsOnDelete = false,
    this.deleteCompleter,
    this.events,
  });
  final deleted = <String>[];
  final written = <String>[];
  final bool throwsOnDelete;
  final Completer<void>? deleteCompleter;
  final List<String>? events;
  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {
    deleted.add(endpointIdentifier);
    events?.add('delete:$endpointIdentifier');
    if (throwsOnDelete) throw StateError('unavailable');
    await deleteCompleter?.future;
  }

  @override
  Future<String?> readApiKey(String endpointIdentifier) async => null;
  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async => written.add(endpointIdentifier);
}

const _profileTwo = ServerProfile(
  id: 'two',
  displayName: 'Two',
  originalHostInput: 'two',
  normalizedEndpoint: 'wss://two/api/current',
  lastKnownVersion: '1',
);

ServerProfileSnapshot _snapshot(
  List<ServerProfile> profiles, {
  required String? selected,
}) => ServerProfileSnapshot(profiles: profiles, selectedProfileId: selected);

Future<void> _pumpSwitcher(
  WidgetTester tester, {
  required _RecordingVault vault,
  required _Store store,
}) => tester.pumpWidget(
  ProviderScope(
    overrides: [
      credentialVaultProvider.overrideWithValue(vault),
      initialServerProfileSnapshotProvider.overrideWithValue(store.snapshot),
      serverProfileStoreProvider.overrideWithValue(store),
    ],
    child: MaterialApp(
      theme: TrueDashTheme.light(),
      home: const Scaffold(body: ServerSwitcher()),
    ),
  ),
);

Future<void> _openCatalog(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Choose server'));
  await tester.pumpAndSettle();
}

Future<void> _forget(WidgetTester tester, {String profileId = 'one'}) async {
  await _openCatalog(tester);
  await tester.tap(find.byKey(Key('forget-profile-$profileId')));
  await tester.pumpAndSettle();
}

final class _Store implements ServerProfileStore {
  _Store({required this.snapshot, this.failRemove = false, this.events});

  ServerProfileSnapshot snapshot;
  final bool failRemove;
  final List<String>? events;
  final removes = <String>[];

  @override
  Future<ServerProfileSnapshot> load() async => snapshot;

  @override
  Future<ServerProfileSnapshot> remove(String id) async {
    removes.add(id);
    events?.add('remove:$id');
    if (failRemove) {
      throw const PersistenceFailure(PersistenceFailureKind.unavailable);
    }
    final profiles = snapshot.profiles
        .where((profile) => profile.id != id)
        .toList();
    return snapshot = ServerProfileSnapshot(
      profiles: profiles,
      selectedProfileId: snapshot.selectedProfileId == id
          ? (profiles.isEmpty ? null : profiles.first.id)
          : snapshot.selectedProfileId,
    );
  }

  @override
  Future<ServerProfileSnapshot> registerAndSelect(
    ServerProfile profile,
  ) async => snapshot;
  @override
  Future<ServerProfileSnapshot> registerAndSelectWithCapabilities({
    required ServerProfile profile,
    required Set<String> methodNames,
    required DateTime observedAt,
    required DateTime expiresAt,
    required bool Function() isCommitValid,
  }) async => snapshot;
  @override
  Future<ServerProfileSnapshot> select(String id) async => snapshot;
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
