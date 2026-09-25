import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/dashboard_preview_main.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nfs_settings/nfs_settings_page.dart';
import 'package:trueraid/features/nfs_shares/nfs_shares_page.dart';
import 'package:trueraid/features/search/global_search.dart';
import 'package:trueraid/features/search/search_index.dart';
import 'package:trueraid/features/smb_settings/smb_settings_page.dart';
import 'package:trueraid/features/smb_shares/smb_shares_page.dart';
import 'package:truenas_api/truenas_api.dart';

Finder _shares(bool smb) => find.byType(smb ? SmbSharesPage : NfsSharesPage);
Finder _settings(bool smb) =>
    find.byType(smb ? SmbSettingsPage : NfsSettingsPage);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  double width,
  double scale, {
  required bool smb,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  tester.binding.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    DashboardPreviewApp(initialSmbShares: smb, initialNfsShares: !smb),
  );
  await tester.pumpAndSettle();
  final context = tester.element(_shares(smb));
  expect(MediaQuery.textScalerOf(context).scale(10), 10 * scale);
  return ProviderScope.containerOf(context);
}

Future<void> _connectorFree(
  ProviderContainer container,
  AuthenticatedSession session,
) async {
  expect(
    identical(container.read(dashboardActiveSessionProvider), session),
    isTrue,
  );
  // Actual preview adapters have no RPC client. Their explicit rejecting
  // connector stubs must remain in scope when navigating to native settings.
  expect(session.repository, isNot(isA<TrueNasSessionRepository>()));
  await expectLater(
    session.repository.connect(
      serverInput: 'https://fixture.invalid',
      apiKey: null,
      username: null,
    ),
    throwsUnsupportedError,
  );
  await expectLater(
    container
        .read(rpcConnectorProvider)
        .connect(Uri.parse('wss://fixture.invalid/api/current')),
    throwsUnsupportedError,
  );
  final lock = container.read(serverOperationLockProvider),
      owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

Future<List<Object>> _inventories(SessionRepository repository) async => [
  await (repository as AuthenticatedSmbSharesSession).loadSmbShares(),
  await (repository as AuthenticatedNfsSharesSession).loadNfsShares(),
  await (repository as AuthenticatedSmbSettingsSession).loadSmbSettings(),
  await (repository as AuthenticatedNfsSettingsSession).loadNfsSettings(),
];

Future<void> _unchanged(
  SessionRepository repository,
  List<Object> before,
) async {
  final after = await _inventories(repository);
  expect(after.length, before.length);
  for (var index = 0; index < before.length; index++) {
    expect(identical(after[index], before[index]), isTrue);
  }
}

Future<void> _searchTap(WidgetTester tester, SearchWorkspace workspace) async {
  final target = find.byKey(Key('search-result-workspace.${workspace.name}'));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      300,
      maxScrolls: 40,
      scrollable: find
          .descendant(
            of: find.byType(GlobalSearchDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(
    find.ancestor(of: target, matching: find.byType(InkWell)).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final smb in [true, false]) {
    final name = smb ? 'SMB' : 'NFS';
    final workspace = smb
        ? SearchWorkspace.smbSettings
        : SearchWorkspace.nfsSettings;
    test('$name server settings search resolves the native global page', () {
      final entry = navigationSearchIndex.singleWhere(
        (e) => e.workspace == workspace,
      );
      expect(entry.workspace!.method, smb ? 'smb.config' : 'nfs.config');
      expect(entry.operation, isNull);
      expect(
        navigationSearchPage(entry),
        smb ? isA<SmbSettingsPage>() : isA<NfsSettingsPage>(),
      );
      expect(
        searchNavigation('$name server settings')
            .any((e) => identical(e, entry)),
        isTrue,
      );
    });

    for (final layout in [(800.0, 1.0), (320.0, 2.0)]) {
      for (final search in [false, true]) {
        testWidgets(
          '$name ${search ? 'global search' : 'share settings icon'} preserves preview at ${layout.$1}px/${layout.$2}x',
          (tester) async {
            final container = await _pump(
              tester,
              layout.$1,
              layout.$2,
              smb: smb,
            );
            final session = container.read(dashboardActiveSessionProvider)!;
            final before = await _inventories(session.repository);
            await _connectorFree(container, session);
            if (search) {
              unawaited(showGlobalSearch(tester.element(_shares(smb))));
              await tester.pumpAndSettle();
              final input = find.byKey(const Key('global-search-input'));
              await tester.ensureVisible(input);
              await tester.enterText(input, '$name server settings');
              await tester.pumpAndSettle();
              await _searchTap(tester, workspace);
              expect(find.byType(GlobalSearchDialog), findsNothing);
            } else {
              final icon = find.byKey(
                Key('${name.toLowerCase()}-server-settings'),
              );
              expect(icon, findsOneWidget);
              expect(tester.widget<IconButton>(icon).onPressed, isNotNull);
              await tester.tap(icon);
              await tester.pumpAndSettle();
            }
            final target = _settings(smb);
            expect(target, findsOneWidget);
            expect(_shares(smb), findsNothing);
            expect(_settings(!smb), findsNothing);
            expect(find.byKey(const Key('preview-banner')), findsOneWidget);
            expect(
              identical(
                ProviderScope.containerOf(tester.element(target)),
                container,
              ),
              isTrue,
            );
            expect(
              MediaQuery.textScalerOf(tester.element(target)).scale(10),
              10 * layout.$2,
            );
            await _connectorFree(container, session);
            await _unchanged(session.repository, before);
            expect(tester.takeException(), isNull);
            Navigator.of(tester.element(target)).pop();
            await tester.pumpAndSettle();
            expect(_shares(smb), findsOneWidget);
            expect(target, findsNothing);
            await _connectorFree(container, session);
            await _unchanged(session.repository, before);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
