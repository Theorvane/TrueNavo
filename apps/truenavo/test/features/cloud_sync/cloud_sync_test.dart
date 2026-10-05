import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/cloud_sync_preview.dart';
import 'package:truenavo/features/cloud_sync/cloud_sync_controller.dart';
import 'package:truenavo/features/cloud_sync/cloud_sync_editor.dart';
import 'package:truenavo/features/cloud_sync/cloud_sync_page.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class _Fake with CloudSyncPreviewAdapter implements SessionRepository {
  int reads = 0;
  final reviews = <CloudSyncRequest>[],
      writes = <CloudSyncReview>[],
      polls = <CloudSyncJob>[];
  Future<CloudSyncInventory> Function()? onLoad;
  Future<CloudSyncReview> Function(CloudSyncRequest)? onReview;
  Future<CloudSyncResult> Function()? onExecute, onPoll;
  @override
  Future<CloudSyncInventory> loadCloudSync() async {
    reads++;
    return onLoad?.call() ?? CloudSyncPreviewAdapter.inventory;
  }

  @override
  Future<CloudSyncReview> reviewCloudSync(CloudSyncRequest request) async {
    reviews.add(request);
    return onReview?.call(request) ?? super.reviewCloudSync(request);
  }

  @override
  Future<CloudSyncResult> executeCloudSync(
    CloudSyncReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call() ??
        const CloudSyncResult(
          CloudSyncOutcome.succeeded,
          'Saved configuration only',
        );
  }

  @override
  Future<CloudSyncResult> pollCloudSync(CloudSyncJob job) async {
    polls.add(job);
    return onPoll?.call() ??
        CloudSyncResult(
          CloudSyncOutcome.pending,
          'Running',
          job: job,
          percent: 30,
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

  CloudSyncReview review() => CloudSyncReview(
    request: CloudSyncRequest(
      inventory: CloudSyncPreviewAdapter.inventory,
      action: CloudSyncAction.run,
      task: CloudSyncPreviewAdapter.inventory.tasks.first,
    ),
    endpoint: session.endpoint!,
    warnings: const ['Review both endpoints.'],
  );
  CloudSyncController get controller =>
      container.read(cloudSyncControllerProvider.notifier);
  Future<void> execute([CloudSyncReview? value]) {
    final r = value ?? review();
    return controller.execute(
      expectedSession: session,
      review: r,
      confirmation: r.target,
    );
  }

  void dispose() => container.dispose();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  double width = 800,
  double scale = 1,
  bool light = false,
  bool disconnected = false,
  double keyboardInset = 0,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = _Harness();
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    await h.container.read(cloudSyncInventoryProvider.future);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: light ? TrueNavoTheme.light() : TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboardInset),
          ),
          child: child!,
        ),
        home: const CloudSyncPage(),
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

void main() {
  for (final width in [320.0, 430.0]) {
    testWidgets('review controls fit $width at 200% above keyboard', (
      tester,
    ) async {
      final h = await _pump(tester, width: width, scale: 2, keyboardInset: 300);
      await _tap(tester, 'cloud-sync-run-1');
      expect(tester.takeException(), isNull);
      final input = find.byKey(const Key('cloud-sync-confirm-target'));
      await tester.ensureVisible(input);
      await tester.enterText(input, 'RUN #1');
      await _tap(tester, 'cloud-sync-confirm-impact');
      await _tap(tester, 'cloud-sync-confirm-submit');
      expect(tester.takeException(), isNull);
      expect(h.api.writes.length, 1);
    });
  }
  testWidgets('connection change permanently hides editor fields', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'cloud-sync-update-1');
    h.select(null);
    await tester.pumpAndSettle();
    expect(find.text('Editor expired'), findsOneWidget);
    expect(find.byKey(const Key('cloud-sync-field-folder')), findsNothing);
    h.select(h.session);
    await tester.pumpAndSettle();
    expect(find.text('Editor expired'), findsOneWidget);
    expect(h.api.writes, isEmpty);
  });
  test('inventory errors do not retry or mutate automatically', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onLoad = () => Future.error(StateError('private-secret'));
    await expectLater(
      h.container.read(cloudSyncInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
    expect(h.api.polls, isEmpty);
  });
  test('one-shot review and global lock prevent double submission', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final held = Completer<CloudSyncResult>();
    h.api.onExecute = () => held.future;
    final r = h.review(), first = h.execute(r);
    await h.execute(r);
    expect(h.api.writes.length, 1);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    held.complete(const CloudSyncResult(CloudSyncOutcome.succeeded, 'Saved'));
    await first;
    await h.execute(r);
    expect(h.api.writes.length, 1);
    expect(h.container.read(cloudSyncControllerProvider).locked, false);
  });
  test('another workspace lock prevents cloud writes', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final owner = h.container.read(serverOperationLockProvider).acquire()!;
    await h.execute();
    expect(h.api.writes, isEmpty);
    h.container.read(serverOperationLockProvider).release(owner);
  });
  test('unknown result retains fence and has no automatic poll', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onExecute = () async =>
        const CloudSyncResult(CloudSyncOutcome.unknown, 'Unknown');
    await h.execute();
    expect(h.container.read(cloudSyncControllerProvider).locked, true);
    await h.execute();
    expect(h.api.writes.length, 1);
    expect(h.api.polls, isEmpty);
    expect(h.controller.canPoll, false);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test(
    'unknown owned read retains job and terminal result releases it',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      const job = CloudSyncJob(
        id: 5,
        taskId: 1,
        endpoint: 'wss://nas-demo.example/api/current',
      );
      h.api.onExecute = () async =>
          const CloudSyncResult(CloudSyncOutcome.pending, 'Accepted', job: job);
      await h.execute();
      expect(h.api.polls, isEmpty);
      expect(h.controller.canPoll, true);
      h.api.onPoll = () => Future.error(StateError('secret'));
      await h.controller.poll();
      expect(
        h.container.read(cloudSyncControllerProvider).result?.job,
        same(job),
      );
      expect(h.controller.canPoll, true);
      h.api.onPoll = () async =>
          const CloudSyncResult(CloudSyncOutcome.succeeded, 'Done');
      await h.controller.poll();
      expect(h.container.read(cloudSyncControllerProvider).locked, false);
      expect(h.api.writes.length, 1);
    },
  );
  test('connection switch drops late completion and never replays', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final held = Completer<CloudSyncResult>();
    h.api.onExecute = () => held.future;
    final operation = h.execute();
    h.select(h.newSession(endpoint: 'wss://different.example/api/current'));
    held.complete(const CloudSyncResult(CloudSyncOutcome.succeeded, 'Late'));
    await operation;
    expect(h.container.read(cloudSyncControllerProvider).unknown, true);
    expect(h.controller.canPoll, false);
    expect(h.controller.canAcknowledge, false);
    h.select(h.newSession());
    expect(h.controller.canAcknowledge, true);
    h.controller.acknowledgeAfterReconnect();
    expect(h.container.read(cloudSyncControllerProvider).locked, false);
    expect(h.api.writes.length, 1);
  });
  test('wrong endpoint review rejected before adapter call', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final r = h.review();
    await h.execute(
      CloudSyncReview(
        request: r.request,
        endpoint: 'wss://different.example/api/current',
        warnings: const [],
      ),
    );
    expect(h.api.writes, isEmpty);
  });
  testWidgets('opening and refresh load local inventory only', (tester) async {
    final h = await _pump(tester);
    expect(find.byKey(const Key('cloud-sync-chart')), findsOneWidget);
    expect(find.text('Documents archive'), findsOneWidget);
    await _tap(tester, 'cloud-sync-refresh');
    expect(h.api.reads, 2);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
    expect(h.api.polls, isEmpty);
  });
  testWidgets('disconnected workspace has no create or read', (tester) async {
    final h = await _pump(tester, disconnected: true);
    expect(find.text('Cloud sync unavailable'), findsOneWidget);
    expect(find.byKey(const Key('cloud-sync-create')), findsNothing);
    expect(h.api.reads, 0);
  });
  testWidgets('chart counts are accessible and do not imply backup health', (
    tester,
  ) async {
    await _pump(tester);
    final semantics = tester.widget<Semantics>(
      find.byKey(const Key('cloud-sync-chart-semantics')),
    );
    expect(
      semantics.properties.label,
      '3 tasks: 2 push, 1 pull; 1 enabled. Not backup success.',
    );
    expect(
      find.text(
        'Configuration counts, not transferred bytes or successful backups.',
      ),
      findsOneWidget,
    );
  });
  testWidgets(
    'filter does not change total chart and unsupported actions disabled',
    (tester) async {
      await _pump(tester);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('cloud-sync-run-3')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('cloud-sync-filter')),
        'Design',
      );
      await tester.pumpAndSettle();
      expect(find.text('Documents archive'), findsNothing);
      expect(find.text('Design intake'), findsOneWidget);
      expect(find.text('PUSH · 2'), findsOneWidget);
    },
  );
  testWidgets('run requires exact target plus separate impact confirmation', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'cloud-sync-run-1');
    expect(h.api.writes, isEmpty);
    final field = find.byKey(const Key('cloud-sync-confirm-target'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'RUN #1 ');
    await _tap(tester, 'cloud-sync-confirm-impact');
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('cloud-sync-confirm-submit')),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(field, 'RUN #1');
    await _tap(tester, 'cloud-sync-confirm-submit');
    expect(h.api.writes.length, 1);
    expect(h.api.writes.single.action, CloudSyncAction.run);
    expect(h.api.polls, isEmpty);
  });
  testWidgets('cancel run and delete never submit', (tester) async {
    final h = await _pump(tester);
    for (final action in ['run', 'delete']) {
      await _tap(tester, 'cloud-sync-$action-1');
      final cancel = find.widgetWithText(TextButton, 'Cancel');
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
    }
    expect(h.api.reviews.length, 2);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'connection change hides old review destination and disables confirm',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, 'cloud-sync-run-1');
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pumpAndSettle();
      expect(find.text('Review expired'), findsOneWidget);
      expect(find.text('RUN #1'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('cloud-sync-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('delayed review cannot open after connection changes', (
    tester,
  ) async {
    final h = await _pump(tester);
    final held = Completer<CloudSyncReview>();
    h.api.onReview = (_) => held.future;
    await _tap(tester, 'cloud-sync-run-1');
    final request = h.api.reviews.single;
    h.select(null);
    held.complete(
      CloudSyncReview(
        request: request,
        endpoint: request.inventory.endpoint,
        warnings: const [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloud-sync-confirm-target')), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('editor starts disabled and rejects incomplete destination', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'cloud-sync-create');
    expect(find.byType(CloudSyncEditor), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('cloud-sync-enabled')))
          .value,
      false,
    );
    await _tap(tester, 'cloud-sync-editor-review');
    expect(find.byKey(const Key('cloud-sync-editor-error')), findsOneWidget);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'editing preserves destination and sends enablement through review',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, 'cloud-sync-update-1');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('cloud-sync-field-folder')))
            .enabled,
        false,
      );
      await _tap(tester, 'cloud-sync-enabled');
      await _tap(tester, 'cloud-sync-editor-review');
      expect(h.api.reviews.single.settings?.enabled, false);
      expect(h.api.writes, isEmpty);
      expect(find.text('UPDATE #1'), findsOneWidget);
    },
  );
  for (final width in [320.0, 430.0]) {
    for (final light in [false, true]) {
      testWidgets(
        'workspace and editor fit $width at 200% ${light ? 'light' : 'dark'}',
        (tester) async {
          await _pump(tester, width: width, scale: 2, light: light);
          expect(tester.takeException(), isNull);
          await _tap(tester, 'cloud-sync-create');
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(
            find.byKey(const Key('cloud-sync-field-exclusions')),
          );
          await tester.enterText(
            find.byKey(const Key('cloud-sync-field-exclusions')),
            '*.tmp',
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await _tap(tester, 'cloud-sync-editor-review');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('empty chart has accessible zero denominator', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: const Scaffold(body: CloudSyncChart(tasks: [])),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('No configured tasks'), findsOneWidget);
  });
}
