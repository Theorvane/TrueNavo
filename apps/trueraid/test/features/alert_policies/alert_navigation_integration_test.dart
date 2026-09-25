import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/dashboard_preview_main.dart';
import 'package:trueraid/features/alert_policies/alert_policies_controller.dart';
import 'package:trueraid/features/alert_policies/alert_policies_page.dart';
import 'package:trueraid/features/alert_settings/alert_settings_controller.dart';
import 'package:trueraid/features/alert_settings/alert_settings_page.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/notification_providers/notification_providers_controller.dart';
import 'package:trueraid/features/notification_providers/notification_providers_page.dart';
import 'package:trueraid/features/search/global_search.dart';
import 'package:trueraid/features/search/search_index.dart';
import 'package:truenas_api/truenas_api.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester,
  double width,
  double scale,
) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  tester.binding.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    const DashboardPreviewApp(initialAlertSettings: true),
  );
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(AlertSettingsPage));
  expect(MediaQuery.textScalerOf(context).scale(10), 10 * scale);
  return ProviderScope.containerOf(context);
}

Future<void> _visible(
  WidgetTester tester,
  Finder target, {
  bool search = false,
}) async {
  if (target.evaluate().isEmpty) {
    final scrollable = search
        ? find
              .descendant(
                of: find.byType(GlobalSearchDialog),
                matching: find.byType(Scrollable),
              )
              .first
        : find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      target,
      300,
      maxScrolls: 40,
      scrollable: scrollable,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(
  WidgetTester tester,
  String key, {
  bool search = false,
}) async {
  final target = find.byKey(Key(key));
  await _visible(tester, target, search: search);
  await tester.tap(
    search
        ? find.ancestor(of: target, matching: find.byType(InkWell)).first
        : target,
  );
  await tester.pumpAndSettle();
}

Future<void> _expectConnectorFree(ProviderContainer container) async {
  final session = container.read(dashboardActiveSessionProvider)!;
  // The actual preview repository has no JSON-RPC client and its connector is
  // an explicit rejecting stub. These calls cannot open a network connection.
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
  expect(container.read(alertSettingsControllerProvider).locked, isFalse);
  expect(container.read(alertPoliciesControllerProvider).locked, isFalse);
  expect(
    container.read(notificationProvidersControllerProvider).locked,
    isFalse,
  );
  final lock = container.read(serverOperationLockProvider),
      owner = container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  test(
    'null-method notification provider workspace resolves exact native page',
    () {
      final entry = navigationSearchIndex.singleWhere(
        (e) => e.workspace == SearchWorkspace.notificationProviders,
      );
      expect(entry.workspace!.method, isNull);
      expect(entry.operation, isNull);
      expect(navigationSearchPage(entry), isA<NotificationProvidersPage>());
      expect(
        searchNavigation('Notification providers')
            .any((e) => identical(e, entry)),
        isTrue,
      );
    },
  );

  for (final layout in [(800.0, 1.0), (320.0, 2.0)]) {
    for (final policies in [true, false]) {
      testWidgets(
        'Mail services opens ${policies ? 'policies' : 'providers'} at ${layout.$1}px/${layout.$2}x',
        (tester) async {
          final container = await _pump(tester, layout.$1, layout.$2);
          final repository = container
              .read(dashboardActiveSessionProvider)!
              .repository;
          final mail = await (repository as AuthenticatedAlertSettingsSession)
              .loadAlertSettings();
          final policy = await (repository as AuthenticatedAlertPoliciesSession)
              .loadAlertPolicies();
          final provider =
              await (repository as AuthenticatedNotificationProvidersSession)
                  .loadNotificationProviders();
          await _expectConnectorFree(container);
          await _tap(
            tester,
            policies ? 'alert-settings-policies' : 'alert-settings-providers',
          );
          final target = policies
              ? find.byType(AlertPoliciesPage)
              : find.byType(NotificationProvidersPage);
          expect(target, findsOneWidget);
          expect(find.byType(AlertSettingsPage), findsNothing);
          expect(
            identical(
              ProviderScope.containerOf(tester.element(target)),
              container,
            ),
            isTrue,
          );
          expect(find.byKey(const Key('preview-banner')), findsOneWidget);
          expect(
            identical(
              await (repository as AuthenticatedAlertSettingsSession)
                  .loadAlertSettings(),
              mail,
            ),
            isTrue,
          );
          expect(
            identical(
              await (repository as AuthenticatedAlertPoliciesSession)
                  .loadAlertPolicies(),
              policy,
            ),
            isTrue,
          );
          expect(
            identical(
              await (repository as AuthenticatedNotificationProvidersSession)
                  .loadNotificationProviders(),
              provider,
            ),
            isTrue,
          );
          await _expectConnectorFree(container);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(target)).pop();
          await tester.pumpAndSettle();
          expect(find.byType(AlertSettingsPage), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final workspace in [
      SearchWorkspace.notificationProviders,
      SearchWorkspace.alertPolicies,
    ]) {
      testWidgets(
        'global search selects ${workspace.name} exact route at ${layout.$1}px/${layout.$2}x',
        (tester) async {
          final container = await _pump(tester, layout.$1, layout.$2);
          final before = container.read(dashboardActiveSessionProvider);
          await _expectConnectorFree(container);
          unawaited(
            showGlobalSearch(tester.element(find.byType(AlertSettingsPage))),
          );
          await tester.pumpAndSettle();
          final input = find.byKey(const Key('global-search-input'));
          await _visible(tester, input, search: true);
          await tester.enterText(
            input,
            workspace == SearchWorkspace.notificationProviders
                ? 'Notification providers'
                : 'Alert policies',
          );
          await tester.pumpAndSettle();
          await _tap(
            tester,
            'search-result-workspace.${workspace.name}',
            search: true,
          );
          final target = workspace == SearchWorkspace.notificationProviders
              ? find.byType(NotificationProvidersPage)
              : find.byType(AlertPoliciesPage);
          expect(target, findsOneWidget);
          expect(find.byType(GlobalSearchDialog), findsNothing);
          expect(find.byType(AlertSettingsPage), findsNothing);
          expect(
            identical(container.read(dashboardActiveSessionProvider), before),
            isTrue,
          );
          expect(
            identical(
              ProviderScope.containerOf(tester.element(target)),
              container,
            ),
            isTrue,
          );
          await _expectConnectorFree(container);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(target)).pop();
          await tester.pumpAndSettle();
          expect(find.byType(AlertSettingsPage), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
