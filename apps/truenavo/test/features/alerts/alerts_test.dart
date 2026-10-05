import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/alerts_preview.dart';
import 'package:truenavo/features/alerts/alerts_controller.dart';
import 'package:truenavo/features/alerts/alerts_dialog.dart';
import 'package:truenavo/features/alerts/alerts_page.dart';
import 'package:truenavo/features/email_settings/email_settings_page.dart';
import 'package:truenavo/features/alert_settings/alert_settings_page.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _id = '11111111-1111-4111-8111-111111111111',
    _restore = '33333333-3333-4333-8333-333333333333',
    _oneShot = '44444444-4444-4444-8444-444444444444',
    _secret = 'synthetic-secret-never-display';

class _Fake with AlertsPreviewAdapter implements SessionRepository {
  int reads = 0;
  final reviews = <AlertRequest>[], writes = <AlertReview>[];
  Future<AlertInventory> Function()? onLoad;
  Future<AlertReview> Function(AlertRequest)? onReview;
  Future<AlertResult> Function()? onExecute;
  @override
  Future<AlertInventory> loadAlerts() async {
    reads++;
    return onLoad?.call() ?? AlertsPreviewAdapter.inventory;
  }

  @override
  Future<AlertReview> reviewAlert(AlertRequest request) async {
    reviews.add(request);
    return onReview?.call(request) ?? super.reviewAlert(request);
  }

  @override
  Future<AlertResult> executeAlert(
    AlertReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call() ??
        const AlertResult(
          AlertOutcome.succeeded,
          'Current state observed, not resolved',
        );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnsupportedError('No transport');
}

class _Harness {
  _Harness() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = _Fake();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String endpoint = 'wss://nas-demo.example/api/current',
  }) => AuthenticatedSession(
    profileId: 'sample',
    repository: api,
    availableMethodNames: const {},
    version: '25.10.1',
    endpoint: endpoint,
  );
  void select(AuthenticatedSession? value) {
    active = value;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  AlertReview review() => AlertReview(
    request: AlertRequest(
      inventory: AlertsPreviewAdapter.inventory,
      action: AlertAction.dismiss,
      alert: AlertsPreviewAdapter.inventory.alerts.first,
    ),
    endpoint: session.endpoint!,
    warnings: const ['Dismissed is not resolved.'],
  );
  AlertsController get controller =>
      container.read(alertsControllerProvider.notifier);
  Future<void> execute({AlertReview? review, String? confirmation}) {
    final r = review ?? this.review();
    return controller.execute(
      expectedSession: session,
      review: r,
      confirmation: confirmation ?? r.target,
    );
  }

  void dispose() => container.dispose();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  double width = 800,
  double scale = 1,
  double keyboard = 0,
  bool light = false,
  bool disconnected = false,
  bool ha = false,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = _Harness();
  addTearDown(h.dispose);
  if (ha) {
    h.api.onLoad = () async => AlertInventory(
      endpoint: h.session.endpoint!,
      failoverLicensed: true,
      alerts: AlertsPreviewAdapter.inventory.alerts,
    );
  }
  if (disconnected) {
    h.select(null);
  } else {
    await h.container.read(alertsInventoryProvider.future);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: light ? TrueNavoTheme.light() : TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const AlertsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> _filter(
  WidgetTester tester,
  String dimension,
  String value,
) async {
  await _tap(tester, 'alerts-filter-$dimension-ALL');
  await tester.tap(find.text(value).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'notification services link only navigates without alert writes or sends',
    (tester) async {
      final h = await _pump(tester, width: 320, scale: 2);
      final reads = h.api.reads;
      await _tap(tester, 'alerts-notification-services');
      expect(find.byType(AlertSettingsPage), findsOneWidget);
      expect(h.api.reads, reads);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'email settings link only navigates without alert writes or mail sending',
    (tester) async {
      final h = await _pump(tester, width: 320, scale: 2);
      final reads = h.api.reads;
      await _tap(tester, 'alerts-email-settings');
      expect(find.byType(EmailSettingsPage), findsOneWidget);
      expect(h.api.reads, reads);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  test('inventory failure neither retries nor mutates', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onLoad = () => Future.error(StateError(_secret));
    await expectLater(
      h.container.read(alertsInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
  });
  test('one-shot review and sharedlock prevent double dispatch', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final held = Completer<AlertResult>();
    h.api.onExecute = () => held.future;
    final r = h.review(), first = h.execute(review: r);
    await h.execute(review: r);
    expect(h.api.writes.length, 1);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    held.complete(const AlertResult(AlertOutcome.succeeded, 'Observed'));
    await first;
    await h.execute(review: r);
    expect(h.api.writes.length, 1);
    expect(h.container.read(alertsControllerProvider).locked, false);
  });
  test('another workspace lock rejects before dispatch', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider),
        owner = lock.acquire()!;
    await h.execute();
    expect(h.api.writes, isEmpty);
    lock.release(owner);
  });
  for (final thrown in [false, true]) {
    test(
      '${thrown ? 'exception' : 'unknown reply'} retains fence and never replays',
      () async {
        final h = _Harness();
        addTearDown(h.dispose);
        h.api.onExecute = thrown
            ? () => Future.error(StateError(_secret))
            : () async => const AlertResult(AlertOutcome.unknown, 'Unknown');
        await h.execute();
        expect(h.container.read(alertsControllerProvider).unknown, true);
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        expect(
          h.container.read(alertsControllerProvider).result!.message,
          isNot(contains(_secret)),
        );
        await h.execute();
        expect(h.api.writes.length, 1);
      },
    );
  }
  test('switching sessions drops late completion and requires original-server reconnect', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final held = Completer<AlertResult>();
    h.api.onExecute = () => held.future;
    final operation = h.execute();
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    held.complete(const AlertResult(AlertOutcome.succeeded, 'Late'));
    await operation;
    expect(h.container.read(alertsControllerProvider).unknown, true);
    expect(h.controller.canAcknowledge, false);
    h.select(h.newSession());
    expect(h.controller.canAcknowledge, true);
    h.controller.acknowledgeAfterReconnect();
    expect(h.container.read(alertsControllerProvider).locked, false);
    expect(h.api.writes.length, 1);
  });
  for (final mismatch in ['confirmation', 'endpoint', 'session']) {
    test('$mismatch rejects before adapter call', () async {
      final h = _Harness();
      addTearDown(h.dispose);
      var r = h.review();
      if (mismatch == 'endpoint') {
        r = AlertReview(
          request: r.request,
          endpoint: 'wss://other.example/api/current',
          warnings: const [],
        );
      }
      if (mismatch == 'session') h.select(h.newSession());
      await h.execute(
        review: r,
        confirmation: mismatch == 'confirmation' ? '${r.target} ' : null,
      );
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('open and manual refresh only read visible list', (tester) async {
    final h = await _pump(tester);
    expect(find.byKey(const Key('alerts-status-chart')), findsOneWidget);
    expect(find.text('Pool health needs attention'), findsOneWidget);
    await _tap(tester, 'alerts-refresh');
    expect(h.api.reads, 2);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('disconnected page performs zero reads', (tester) async {
    final h = await _pump(tester, disconnected: true);
    expect(find.text('Alerts unavailable'), findsOneWidget);
    expect(h.api.reads, 0);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('charts expose counts without claiming resolution', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Dismissed ≠ resolved'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label == '4 visible alerts, 3 active, 1 dismissed',
      ),
      findsOneWidget,
    );
    expect(find.text('Severity · all visible'), findsOneWidget);
    expect(find.text('Sources · all visible'), findsOneWidget);
  });
  testWidgets('status legend maps each count to its doughnut color', (
    tester,
  ) async {
    for (final light in [false, true]) {
      await _pump(tester, width: 320, scale: 2, light: light);
      final colors = Theme.of(
        tester.element(find.byKey(const Key('alerts-status-chart'))),
      ).colorScheme;
      for (final entry in {
        'active': colors.surfaceContainerHighest,
        'dismissed': colors.primary,
      }.entries) {
        final swatch = tester.widget<DecoratedBox>(
          find.byKey(Key('alerts-status-legend-${entry.key}')),
        );
        expect((swatch.decoration as BoxDecoration).color, entry.value);
      }
      expect(find.text('Active · 3'), findsOneWidget);
      expect(find.text('Dismissed · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('one-shot and unknown handler classes are display-only', (
    tester,
  ) async {
    await _pump(tester);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('alerts-change-$_oneShot')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('alerts-details-$_oneShot')))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('licensed HA inventory displays but cannot change alerts', (
    tester,
  ) async {
    final h = await _pump(tester, ha: true);
    expect(find.text('HA display-only'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('alerts-change-$_id')))
          .onPressed,
      isNull,
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets('details do not request mutation review', (tester) async {
    final h = await _pump(tester);
    await _tap(tester, 'alerts-details-$_id');
    expect(find.text('Alert details'), findsOneWidget);
    expect(find.text('UUID: $_id'), findsOneWidget);
    expect(find.byKey(const Key('alerts-confirm-target')), findsNothing);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('explicit UUID and separate impact acknowledgment required', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'alerts-change-$_id');
    expect(h.api.reviews.length, 1);
    expect(h.api.writes, isEmpty);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('alerts-confirm-submit')))
          .onPressed,
      isNull,
    );
    await _enter(tester, 'alerts-confirm-target', 'DISMISS $_id ');
    await _tap(tester, 'alerts-confirm-impact');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('alerts-confirm-submit')))
          .onPressed,
      isNull,
    );
    await _enter(tester, 'alerts-confirm-target', 'DISMISS $_id');
    await _tap(tester, 'alerts-confirm-submit');
    expect(h.api.writes.length, 1);
    expect(h.api.writes.single.action, AlertAction.dismiss);
  });
  testWidgets('restore current dismissed alert is separately reviewed', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'alerts-change-$_restore');
    await _enter(tester, 'alerts-confirm-target', 'RESTORE $_restore');
    await _tap(tester, 'alerts-confirm-impact');
    await _tap(tester, 'alerts-confirm-submit');
    expect(h.api.writes.single.action, AlertAction.restore);
  });
  testWidgets('cancel review submits nothing', (tester) async {
    final h = await _pump(tester);
    await _tap(tester, 'alerts-change-$_id');
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.api.writes, isEmpty);
  });
  testWidgets('safe search matches title/source/UUID not hidden payload', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _enter(tester, 'alerts-search', 'certificate');
    expect(find.text('1 matching / 4 visible alerts'), findsOneWidget);
    expect(find.text('Certificate expiry warning'), findsOneWidget);
    await _enter(tester, 'alerts-search', _id);
    expect(find.text('1 matching / 4 visible alerts'), findsOneWidget);
    await _enter(tester, 'alerts-search', _secret);
    expect(find.text('No matching visible alerts'), findsOneWidget);
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
  });
  for (final dimension in ['severity', 'status', 'source']) {
    testWidgets('$dimension filter works locally without reads', (
      tester,
    ) async {
      final h = await _pump(tester);
      await _filter(
        tester,
        dimension,
        dimension == 'severity'
            ? 'CRITICAL'
            : dimension == 'status'
            ? 'DISMISSED'
            : 'ZpoolCapacity',
      );
      expect(
        find.text(
          '${dimension == 'severity' ? 2 : 1} matching / 4 visible alerts',
        ),
        findsOneWidget,
      );
      expect(h.api.reads, 1);
      expect(h.api.writes, isEmpty);
    });
  }
  for (final phase in ['details', 'review']) {
    testWidgets(
      '$phase permanently expires on session switch and reselection',
      (tester) async {
        final h = await _pump(tester);
        await _tap(
          tester,
          'alerts-${phase == 'details' ? 'details' : 'change'}-$_id',
        );
        h.select(null);
        await tester.pumpAndSettle();
        expect(find.text('Alert view expired'), findsOneWidget);
        expect(find.text('UUID: $_id'), findsNothing);
        h.select(h.session);
        await tester.pumpAndSettle();
        expect(find.text('Alert view expired'), findsOneWidget);
        expect(h.api.writes, isEmpty);
      },
    );
  }
  testWidgets('inventory reload permanently expires review', (tester) async {
    final h = await _pump(tester);
    await _tap(tester, 'alerts-change-$_id');
    h.container.invalidate(alertsInventoryProvider);
    await tester.pumpAndSettle();
    expect(find.text('Alert view expired'), findsOneWidget);
    expect(h.api.writes, isEmpty);
  });
  for (final phase in ['details', 'review']) {
    testWidgets('background permanently expires $phase', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final h = await _pump(tester);
      await _tap(
        tester,
        'alerts-${phase == 'details' ? 'details' : 'change'}-$_id',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.text('Alert view expired'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Alert view expired'), findsOneWidget);
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('already inactive app cannot open review', (tester) async {
    final h = await _pump(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await _tap(tester, 'alerts-change-$_id');
    expect(find.byType(AlertsDialog), findsNothing);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  for (final width in [320.0, 430.0]) {
    testWidgets('review fits $width at 200% above keyboard', (tester) async {
      final h = await _pump(tester, width: width, scale: 2, keyboard: 300);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'alerts-change-$_id');
      expect(tester.takeException(), isNull);
      await _enter(tester, 'alerts-confirm-target', 'DISMISS $_id');
      await _tap(tester, 'alerts-confirm-impact');
      await _tap(tester, 'alerts-confirm-submit');
      expect(tester.takeException(), isNull);
      expect(h.api.writes.length, 1);
    });
  }
  testWidgets('light theme 320px charts do not overflow', (tester) async {
    await _pump(tester, width: 320, light: true);
    expect(tester.takeException(), isNull);
  });
  test('connector-free preview rejects writes', () async {
    final api = _Preview(), inventory = AlertsPreviewAdapter.inventory;
    final r = await api.reviewAlert(
      AlertRequest(
        inventory: inventory,
        action: AlertAction.dismiss,
        alert: inventory.alerts.first,
      ),
    );
    expect(
      (await api.executeAlert(r, r.target)).outcome,
      AlertOutcome.rejected,
    );
  });
}

class _Preview with AlertsPreviewAdapter {}
