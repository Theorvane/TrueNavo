import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/dashboard_preview_main.dart';
import 'package:trueraid/features/admin/admin_workspace.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/cron_tasks/cron_tasks_page.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/init_shutdown_tasks/init_shutdown_tasks_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/search/global_search.dart';
import 'package:trueraid/features/search/search_index.dart';
import 'package:truenas_api/truenas_api.dart';

Finder _page(bool cron) =>
    find.byType(cron ? CronTasksPage : InitShutdownTasksPage);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  double width,
  double scale, {
  required bool initialCron,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  tester.binding.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    DashboardPreviewApp(
      initialCronTasks: initialCron,
      initialInitShutdownTasks: !initialCron,
    ),
  );
  await tester.pumpAndSettle();
  final context = tester.element(_page(initialCron));
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
  // Both concrete preview connectors are explicit rejecting stubs. No request
  // below can open a network connection or invoke a task on an appliance.
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
  final lock = container.read(serverOperationLockProvider);
  final owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

Future<List<Object>> _inventories(SessionRepository repository) async => [
  await (repository as AuthenticatedCronTasksSession).loadCronTasks(),
  await (repository as AuthenticatedInitShutdownTasksSession)
      .loadInitShutdownTasks(),
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

Future<void> _tap(
  WidgetTester tester,
  String key, {
  bool search = false,
}) async {
  final target = find.byKey(Key(key));
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      300,
      maxScrolls: 80,
      scrollable: search
          ? find
                .descendant(
                  of: find.byType(GlobalSearchDialog),
                  matching: find.byType(Scrollable),
                )
                .first
          : find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(
    search
        ? find.ancestor(of: target, matching: find.byType(InkWell)).first
        : target,
  );
  await tester.pumpAndSettle();
}

void main() {
  test('manual task execution does not gain a native execution route', () {
    expect(AdminOperationTile.nativePageForMethod('cronjob.run'), isNull);
    expect(
      AdminOperationTile.nativePageForMethod(
        'initshutdownscript.execute_init_tasks',
      ),
      isNull,
    );
  });

  for (final cron in [true, false]) {
    final name = cron ? 'Cron tasks' : 'Startup & shutdown tasks';
    final workspace = cron
        ? SearchWorkspace.cronTasks
        : SearchWorkspace.initShutdownTasks;
    final namespace = cron ? 'cronjob' : 'initshutdownscript';
    test('$name names and aliases resolve only the native lifecycle page', () {
      final entry = navigationSearchIndex.singleWhere(
        (e) => e.workspace == workspace,
      );
      expect(entry.workspace!.method, '$namespace.query');
      expect(entry.operation, isNull);
      expect(
        navigationSearchPage(entry),
        cron ? isA<CronTasksPage>() : isA<InitShutdownTasksPage>(),
      );
      for (final query in [
        name,
        cron ? '예약작업' : '부팅 스크립트',
        '$namespace.update',
        '$namespace.delete',
      ]) {
        expect(
          searchNavigation(query).any((e) => identical(e, entry)),
          isTrue,
          reason: query,
        );
      }
      for (final action in ['query', 'create', 'update', 'delete']) {
        expect(
          AdminOperationTile.nativePageForMethod('$namespace.$action'),
          cron ? isA<CronTasksPage>() : isA<InitShutdownTasksPage>(),
        );
      }
    });

    for (final layout in [(800.0, 1.0), (320.0, 2.0)]) {
      for (final search in [false, true]) {
        testWidgets(
          '$name ${search ? 'search' : 'system directory'} preserves connector-free preview at ${layout.$1}px/${layout.$2}x',
          (tester) async {
            final container = await _pump(
              tester,
              layout.$1,
              layout.$2,
              initialCron: !cron,
            );
            final session = container.read(dashboardActiveSessionProvider)!;
            final before = await _inventories(session.repository);
            await _connectorFree(container, session);
            final origin = tester.element(_page(!cron));
            if (search) {
              unawaited(showGlobalSearch(origin));
              await tester.pumpAndSettle();
              final input = find.byKey(const Key('global-search-input'));
              await tester.ensureVisible(input);
              await tester.enterText(input, name);
              await tester.pumpAndSettle();
              await _tap(
                tester,
                'search-result-workspace.${workspace.name}',
                search: true,
              );
              expect(find.byType(GlobalSearchDialog), findsNothing);
            } else {
              unawaited(
                Navigator.of(origin).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const AdminDomainPage(domain: AdminDomain.system),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              await _tap(
                tester,
                cron
                    ? 'admin-cron-tasks-workspace'
                    : 'admin-init-shutdown-tasks-workspace',
              );
            }
            final target = _page(cron);
            expect(target, findsOneWidget);
            expect(_page(!cron), findsNothing);
            expect(find.byKey(const Key('preview-banner')), findsOneWidget);
            final context = tester.element(target);
            expect(
              identical(ProviderScope.containerOf(context), container),
              isTrue,
            );
            expect(MediaQuery.textScalerOf(context).scale(10), 10 * layout.$2);
            await _connectorFree(container, session);
            await _unchanged(session.repository, before);
            expect(tester.takeException(), isNull);
            Navigator.of(context).pop();
            await tester.pumpAndSettle();
            if (!search) {
              final admin = find.byType(AdminDomainPage);
              expect(admin, findsOneWidget);
              Navigator.of(tester.element(admin)).pop();
              await tester.pumpAndSettle();
            }
            expect(_page(!cron), findsOneWidget);
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
