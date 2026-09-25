import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/disks_preview.dart';
import 'package:trueraid/features/disks/disks_controller.dart';
import 'package:trueraid/features/disks/disks_editor.dart';
import 'package:trueraid/features/disks/disks_page.dart';
import 'package:trueraid/features/disks/disks_review.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _id = '{serial}SAMPLE-HDD-A',
    _secret = 'synthetic-remote-detail-do-not-display';

class _Fake with DisksPreviewAdapter implements SessionRepository {
  int reads = 0;
  final reviews = <DiskRequest>[], writes = <DiskReview>[];
  Future<DiskInventory> Function()? onLoad;
  Future<DiskReview> Function(DiskRequest)? onReview;
  Future<DiskResult> Function()? onExecute;
  bool canUpdate = true;
  @override
  DisksCapabilities get disksCapabilities => DisksCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
    canUpdate: canUpdate,
  );
  @override
  Future<DiskInventory> loadDisks() async {
    reads++;
    return onLoad?.call() ?? DisksPreviewAdapter.inventory;
  }

  @override
  Future<DiskReview> reviewDisk(DiskRequest request) async {
    reviews.add(request);
    return onReview?.call(request) ?? super.reviewDisk(request);
  }

  @override
  Future<DiskResult> executeDisk(DiskReview review, String confirmation) async {
    writes.add(review);
    return onExecute?.call() ??
        const DiskResult(DiskOutcome.succeeded, 'Stored settings observed');
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
  }) => throw StateError('No transport');
}

class _Harness {
  _Harness() {
    original = session();
    active = original;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = _Fake();
  late final AuthenticatedSession original;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession session({
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

  DiskReview review() {
    final inventory = DisksPreviewAdapter.inventory,
        disk = DisksPreviewAdapter.inventory.disks.first;
    return DiskReview(
      request: DiskRequest(
        inventory: inventory,
        disk: disk,
        settings: DiskSettings(
          description: 'Reviewed description',
          hddStandby: disk.hddStandby,
          advancedPowerManagement: disk.advancedPowerManagement,
        ),
      ),
      endpoint: original.endpoint!,
      warnings: const ['Saved policy is not proof of hardware application.'],
    );
  }

  DisksController get controller =>
      container.read(disksControllerProvider.notifier);
  Future<void> execute({DiskReview? review, String? confirmation}) {
    final r = review ?? this.review();
    return controller.execute(
      expectedSession: original,
      review: r,
      confirmation: confirmation ?? r.target,
    );
  }
}

Future<_Harness> _pump(
  WidgetTester tester, {
  double width = 800,
  double scale = 1,
  double keyboard = 0,
  bool light = false,
  _Harness? harness,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = harness ?? _Harness();
  addTearDown(h.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: light ? TrueRAIDTheme.light() : TrueRAIDTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const DisksPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.enterText(f, value);
  await tester.pumpAndSettle();
}

Future<void> _review(WidgetTester tester) async {
  await _tap(tester, 'disk-edit-$_id');
  await _enter(tester, 'disk-description', 'Reviewed description');
  await _tap(tester, 'disk-editor-review');
}

void main() {
  test('wrong target is rejected without disk dispatch', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    await h.execute(confirmation: 'UPDATE another');
    expect(h.api.writes, isEmpty);
    expect(
      h.container.read(disksControllerProvider).result!.outcome,
      DiskOutcome.rejected,
    );
  });
  test('different active session prevents dispatch', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.select(h.session());
    await h.execute();
    expect(h.api.writes, isEmpty);
  });
  test('review is single-use even after successful verification', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    final review = h.review();
    await h.execute(review: review);
    await h.execute(review: review);
    expect(h.api.writes, hasLength(1));
  });
  test('parallel submits invoke only one change', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    final pending = Completer<DiskResult>();
    h.api.onExecute = () => pending.future;
    final first = h.execute();
    await h.execute();
    expect(h.api.writes, hasLength(1));
    pending.complete(const DiskResult(DiskOutcome.succeeded, 'Stored'));
    await first;
  });
  for (final outcome in [DiskOutcome.succeeded, DiskOutcome.rejected]) {
    test('$outcome releases the shared operation lock', () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      h.api.onExecute = () async => DiskResult(outcome, 'Safe result');
      await h.execute();
      final lock = h.container.read(serverOperationLockProvider),
          owner = h.container.read(serverOperationLockProvider).acquire();
      expect(owner, isNotNull);
      lock.release(owner!);
    });
  }
  test('unknown outcome keeps lock and cannot be retried', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.onExecute = () async =>
        const DiskResult(DiskOutcome.unknown, 'Inspect server');
    await h.execute();
    await h.execute();
    expect(h.api.writes, hasLength(1));
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    expect(h.controller.canAcknowledge, isFalse);
  });
  test('another workspace lock rejects disk submission', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    final lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire();
    await h.execute();
    expect(h.api.writes, isEmpty);
    lock.release(owner!);
  });
  test('late success after connection change stays unknown', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    final pending = Completer<DiskResult>();
    h.api.onExecute = () => pending.future;
    final first = h.execute();
    h.select(h.session());
    pending.complete(const DiskResult(DiskOutcome.succeeded, 'Late'));
    await first;
    expect(
      h.container.read(disksControllerProvider).result!.outcome,
      DiskOutcome.unknown,
    );
    expect(h.api.writes, hasLength(1));
  });
  test('unknown acknowledgment requires fresh same-server session', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.onExecute = () async =>
        const DiskResult(DiskOutcome.unknown, 'Unknown');
    await h.execute();
    h.select(h.session(endpoint: 'wss://other.example/api/current'));
    expect(h.controller.canAcknowledge, isFalse);
    h.select(h.session());
    expect(h.controller.canAcknowledge, isTrue);
    h.controller.acknowledgeAfterReconnect();
    expect(h.container.read(disksControllerProvider).locked, isFalse);
    expect(h.api.writes, hasLength(1));
  });
  test('arbitrary execution error is hidden and remains unknown', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.onExecute = () => Future.error(StateError(_secret));
    await h.execute();
    final result = h.container.read(disksControllerProvider).result!;
    expect(result.outcome, DiskOutcome.unknown);
    expect(result.message, isNot(contains(_secret)));
  });
  test('typed preflight error is a safe rejection', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.onExecute = () =>
        Future.error(const DisksException(DisksExceptionReason.staleReview));
    await h.execute();
    expect(
      h.container.read(disksControllerProvider).result!.outcome,
      DiskOutcome.rejected,
    );
  });
  test('inventory from wrong endpoint is not published', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    h.api.onLoad = () async => DiskInventory(
      endpoint: 'wss://other.example/api/current',
      failoverLicensed: false,
      disks: DisksPreviewAdapter.inventory.disks,
    );
    await expectLater(
      h.container.read(disksInventoryProvider.future),
      throwsStateError,
    );
    expect(h.api.reads, 1);
  });
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final light in [false, true]) {
      testWidgets(
        'disk overview and editor at $width light=$light 200percent with keyboard',
        (tester) async {
          final h = await _pump(
            tester,
            width: width,
            scale: 2,
            keyboard: 300,
            light: light,
          );
          expect(find.text('HDD · 3'), findsOneWidget);
          expect(find.text('SSD · 1'), findsOneWidget);
          expect(find.text('Unknown · 1'), findsOneWidget);
          expect(find.text('1 capacities unavailable'), findsOneWidget);
          await _tap(tester, 'disk-edit-$_id');
          await _enter(tester, 'disk-description', 'Reviewed description');
          await _tap(tester, 'disk-editor-review');
          expect(find.byType(DisksReviewDialog), findsOneWidget);
          expect(h.api.writes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('search and kind filters preserve inventory chart counts', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _enter(tester, 'disks-search', 'SAMPLE-HDD-A');
    expect(find.text('1 matching / 5 recorded disks'), findsOneWidget);
    expect(find.text('HDD · 3'), findsOneWidget);
    await _enter(tester, 'disks-search', '');
    await _tap(tester, 'disks-type-SSD');
    expect(find.text('1 matching / 5 recorded disks'), findsOneWidget);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('unknown capacity and unverified identity stay unavailable', (
    tester,
  ) async {
    await _pump(tester);
    await _tap(tester, 'disks-type-Unknown');
    expect(find.text('Capacity unavailable'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('disk-edit-{devicename}sdd')),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.byKey(const Key('disk-capacity-{devicename}sdd')),
      findsNothing,
    );
  });
  testWidgets('read-only account cannot open changes', (tester) async {
    final h = _Harness();
    h.api.canUpdate = false;
    await _pump(tester, harness: h);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('disk-edit-$_id')))
          .onPressed,
      isNull,
    );
  });
  testWidgets('inventory failures redact details and do not retry', (
    tester,
  ) async {
    final h = _Harness();
    h.api.onLoad = () => Future.error(StateError(_secret));
    await _pump(tester, harness: h);
    expect(find.text('Disk inventory unavailable'), findsOneWidget);
    expect(find.textContaining(_secret), findsNothing);
    expect(find.byKey(const Key('disks-type-chart')), findsNothing);
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'SSD and boot disk power fields are disabled but description can be reviewed',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, 'disk-edit-{serial}SAMPLE-BOOT');
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const Key('disk-standby')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const Key('disk-apm')),
            )
            .onChanged,
        isNull,
      );
      await _enter(tester, 'disk-description', 'Boot label');
      await _tap(tester, 'disk-editor-review');
      expect(find.byType(DisksReviewDialog), findsOneWidget);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('unchanged settings cannot reach a server review', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'disk-edit-$_id');
    await _tap(tester, 'disk-editor-review');
    expect(find.byType(DisksEditor), findsOneWidget);
    expect(find.byKey(const Key('disk-editor-error')), findsOneWidget);
    expect(h.api.reviews, isEmpty);
  });
  testWidgets('confirmation needs exact target and impact acknowledgment', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _review(tester);
    final button = find.byKey(const Key('disk-confirm-submit'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await _enter(tester, 'disk-confirm-target', 'UPDATE $_id ');
    await _tap(tester, 'disk-confirm-impact');
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await _enter(tester, 'disk-confirm-target', 'UPDATE $_id');
    await _tap(tester, 'disk-confirm-submit');
    expect(h.api.writes, hasLength(1));
    expect(
      h.api.writes.single.request.settings.description,
      'Reviewed description',
    );
  });
  testWidgets('backgrounding editor hides values and blocks continuation', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, 'disk-edit-$_id');
    await _enter(tester, 'disk-description', 'Transient description');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.text('Editor expired'), findsOneWidget);
    expect(find.text('Transient description'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('disk-editor-review')))
          .onPressed,
      isNull,
    );
    expect(h.api.reviews, isEmpty);
  });
  testWidgets('connection change expires review and hides old target', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _review(tester);
    h.select(h.session());
    await tester.pumpAndSettle();
    expect(find.text('Review expired'), findsOneWidget);
    expect(find.text('UPDATE $_id'), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('inventory refresh expires review even if records match', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _review(tester);
    h.container.invalidate(disksInventoryProvider);
    await tester.pumpAndSettle();
    expect(find.text('Review expired'), findsOneWidget);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('late review after background cannot open confirmation', (
    tester,
  ) async {
    final h = await _pump(tester), pending = Completer<DiskReview>();
    h.api.onReview = (_) => pending.future;
    await _tap(tester, 'disk-edit-$_id');
    await _enter(tester, 'disk-description', 'Reviewed description');
    await _tap(tester, 'disk-editor-review');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final request = h.api.reviews.single;
    pending.complete(
      DiskReview(
        request: request,
        endpoint: h.original.endpoint!,
        warnings: const [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DisksReviewDialog), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('forged review endpoint fails without exposing remote details', (
    tester,
  ) async {
    final h = await _pump(tester);
    h.api.onReview = (request) async => DiskReview(
      request: request,
      endpoint: _secret,
      warnings: const [_secret],
    );
    await _review(tester);
    expect(find.byType(DisksReviewDialog), findsNothing);
    expect(find.textContaining(_secret), findsNothing);
    expect(h.api.writes, isEmpty);
  });
}
