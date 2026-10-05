import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/sample/cloud_sync_preview.dart';
import 'package:truenavo/sample/replication_preview.dart';
import 'package:truenavo/sample/rsync_preview.dart';
import 'package:truenavo/sample/snapshot_schedules_preview.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/data_protection/data_protection_overview.dart';
import 'package:truenavo/features/data_protection/data_protection_page.dart';
import 'package:truenavo/features/replication/replication_page.dart';
import 'package:truenavo/features/rsync/rsync_controller.dart';
import 'package:truenavo/features/rsync/rsync_page.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _endpoint = 'wss://nas-demo.example/api/current';
const _private = 'SYNTHETIC-PRIVATE-ERROR-TOKEN';

void main() {
  test(
    'aggregates four sequential typed reads without mutation or duplicate IDs',
    () async {
      final api = _Fake();
      final value = await _load(api);
      expect(api.events, [
        'snapshots:start',
        'snapshots:end',
        'replication:start',
        'replication:end',
        'cloud:start',
        'cloud:end',
        'rsync:start',
        'rsync:end',
      ]);
      expect(api.peak, 1);
      expect(value.tasks.length, 11);
      expect(value.tasks.map((t) => t.identity).toSet().length, 11);
      expect(value.enabled, 5);
      expect(value.disabled, 6);
      expect(value.loadedSources, 4);
      expect(value.count(ProtectionReportedState.successful), 4);
      expect(value.count(ProtectionReportedState.failed), 2);
      expect(value.count(ProtectionReportedState.attention), 1);
      expect(value.count(ProtectionReportedState.active), 0);
      expect(value.count(ProtectionReportedState.unknown), 4);
      expect(value.observedAt, DateTime.utc(2026, 9, 13));
      expect(api.mutations, 0);
      expect(api.rsyncReviews, 0);
      expect(api.rsyncChecks, 0);
      expect(() => value.tasks.clear(), throwsUnsupportedError);
      expect(() => value.sources.clear(), throwsUnsupportedError);
      expect(() => value.sources.last.tasks.clear(), throwsUnsupportedError);
    },
  );
  for (final (raw, expected) in [
    ('SUCCESS', ProtectionReportedState.successful),
    ('FINISHED', ProtectionReportedState.successful),
    ('FAILED', ProtectionReportedState.failed),
    ('ERROR', ProtectionReportedState.failed),
    ('ABORTED', ProtectionReportedState.failed),
    ('RUNNING', ProtectionReportedState.active),
    ('WAITING', ProtectionReportedState.active),
    ('HOLD', ProtectionReportedState.attention),
    ('LOCKED', ProtectionReportedState.attention),
    ('PENDING', ProtectionReportedState.unknown),
    ('success', ProtectionReportedState.unknown),
    ('SUCCESS\n', ProtectionReportedState.unknown),
    ('', ProtectionReportedState.unknown),
  ]) {
    test(
      'reported state $raw stays exact and does not invent health',
      () => expect(protectionReportedState(raw), expected),
    );
  }
  for (final fault in ['snapshots', 'replication', 'cloud', 'rsync']) {
    test(
      'failed $fault excluded from totals with redacted failure and no retry',
      () async {
        final api = _Fake()..fail = fault;
        final value = await _load(api);
        expect(value.loadedSources, 3);
        expect(value.sources.where((s) => !s.loaded).single.tasks, isEmpty);
        expect(
          value.sources.where((s) => !s.loaded).single.unavailable,
          isNot(contains(_private)),
        );
        expect(api.events.where((e) => e == '$fault:start').length, 1);
        expect(value.tasks.length, fault == 'replication' ? 9 : 8);
        expect(api.mutations, 0);
      },
    );
  }
  test(
    'unsupported family does not masquerade as an empty successful query',
    () async {
      final value = await loadDataProtectionOverview(
        repository: _Unavailable(),
        endpoint: _endpoint,
        isCurrent: () => true,
      );
      expect(value.loadedSources, 0);
      expect(value.tasks, isEmpty);
      expect(value.sources.every((s) => s.unavailable != null), isTrue);
    },
  );
  test(
    'mismatched replication endpoint is withheld while other sources survive',
    () async {
      final api = _Fake()..wrongEndpoint = true;
      final value = await _load(api);
      expect(value.sources[1].loaded, isFalse);
      expect(
        value.tasks.where((t) => t.family == ProtectionFamily.replication),
        isEmpty,
      );
      expect(value.loadedSources, 3);
    },
  );
  test('a stale attempt before reading calls nothing', () async {
    final api = _Fake();
    await expectLater(
      loadDataProtectionOverview(
        repository: api,
        endpoint: _endpoint,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(api.events, isEmpty);
  });
  test('unavailable source payloads are excluded from every aggregate', () {
    final overview = DataProtectionOverview(
      endpoint: _endpoint,
      observedAt: DateTime.utc(2026, 9, 14),
      sources: [
        ProtectionSourceSummary(
          family: ProtectionFamily.rsync,
          unavailable: 'Unavailable',
          tasks: const [
            ProtectionTaskSummary(
              family: ProtectionFamily.rsync,
              id: 1,
              name: 'Stale',
              source: '',
              destination: '',
              enabled: true,
              state: 'SUCCESS',
              schedule: '',
            ),
          ],
        ),
      ],
    );
    expect(overview.tasks, isEmpty);
    expect(overview.loadedSources, 0);
    expect(overview.enabled, 0);
    expect(overview.count(ProtectionReportedState.successful), 0);
  });
  test(
    'Rsync projection exposes configured paths but no SSH identity payload',
    () async {
      final api = _Fake();
      final value = await _load(api);
      final rsync = value.sources.singleWhere(
        (s) => s.family == ProtectionFamily.rsync,
      );
      expect(rsync.loaded, isTrue);
      expect(rsync.tasks.first.source, 'SSH PUSH · /mnt/tank/media');
      expect(rsync.tasks.first.destination, 'SSH connection #21 · /srv/backup');
      expect(rsync.tasks.first.schedule, '0 2 * * * · Asia/Seoul');
      final text = rsync.tasks
          .map((t) => '${t.name} ${t.source} ${t.destination} ${t.restriction}')
          .join(' ');
      expect(text, isNot(contains('sample-public-identity')));
      expect(text, isNot(contains('replica@backup.example')));
      expect(rsync.tasks.last.source, 'Unsupported task details withheld');
      expect(rsync.tasks.last.reportedState, ProtectionReportedState.unknown);
      expect(rsync.tasks.last.restriction, isNotNull);
      expect(api.rsyncReviews + api.rsyncChecks + api.mutations, 0);
    },
  );
  test('unsupported Rsync details and arbitrary recorded errors are withheld', () async {
    final api = _Fake()
      ..rsyncTasks = const [
        RsyncTask(
          id: 17,
          description: 'Unsupported configuration',
          mode: 'MODULE',
          direction: 'PULL',
          enabled: true,
          locked: true,
          lastJobState: _private,
          blockedReason: _private,
          settings: RsyncSettings(
            path: '/mnt/tank/$_private',
            user: _private,
            connectionId: 21,
            remotePath: '/srv/$_private',
          ),
        ),
      ];
    final rsync = (await _load(api)).sources.last;
    final task = rsync.tasks.single;
    expect(task.enabled, isTrue);
    expect(task.reportedState, ProtectionReportedState.unknown);
    expect(task.source, 'Unsupported task details withheld');
    expect(task.destination, 'Unsupported task details withheld');
    expect(
      '${task.state} ${task.source} ${task.destination} ${task.schedule} ${task.restriction}',
      isNot(contains(_private)),
    );
  });
  for (final state in ['RUNNING', 'WAITING', null, 'PENDING', 'SUCCESS']) {
    test(
      'Rsync recorded $state is not refreshed or checked as a live job',
      () async {
        final api = _Fake()
          ..rsyncTasks = [
            RsyncTask(
              id: 17,
              description: '',
              mode: 'MODULE',
              direction: 'PULL',
              enabled: false,
              locked: false,
              lastJobState: state,
            ),
          ];
        final task = (await _load(api)).sources.last.tasks.single;
        expect(task.reportedState, switch (state) {
          'RUNNING' || 'WAITING' => ProtectionReportedState.active,
          'SUCCESS' => ProtectionReportedState.successful,
          _ => ProtectionReportedState.unknown,
        });
        expect(api.events.where((e) => e == 'rsync:start').length, 1);
        expect(api.rsyncChecks + api.rsyncReviews + api.mutations, 0);
      },
    );
  }
  for (final invalid in ['too many', 'duplicate', 'invalid id']) {
    test(
      'Rsync $invalid inventory is unavailable, not silently truncated',
      () async {
        final api = _Fake()
          ..rsyncTasks = [
            for (var i = 0; i < (invalid == 'too many' ? 129 : 2); i++)
              RsyncTask(
                id: invalid == 'duplicate'
                    ? 1
                    : invalid == 'invalid id'
                    ? 0
                    : i + 1,
                description: '',
                mode: 'MODULE',
                direction: 'PULL',
                enabled: true,
                locked: false,
              ),
          ];
        final overview = await _load(api);
        expect(overview.sources.last.loaded, isFalse);
        expect(overview.sources.last.tasks, isEmpty);
        expect(overview.loadedSources, 3);
        expect(overview.tasks.length, 8);
      },
    );
  }
  test(
    'wrong Rsync endpoint is excluded without dropping other families',
    () async {
      final api = _Fake()..rsyncEndpoint = 'wss://wrong.example/api/current';
      final overview = await _load(api);
      expect(overview.sources.last.loaded, isFalse);
      expect(overview.sources.last.tasks, isEmpty);
      expect(overview.tasks.length, 8);
      expect(overview.enabled, 4);
      expect(overview.disabled, 4);
      expect(api.rsyncReviews + api.rsyncChecks + api.mutations, 0);
    },
  );
  test('session change during final Rsync read prevents publication', () async {
    final api = _Fake()
      ..pauseFamily = 'rsync'
      ..pause = Completer<void>();
    var current = true;
    final pending = loadDataProtectionOverview(
      repository: api,
      endpoint: _endpoint,
      isCurrent: () => current,
    );
    while (!api.events.contains('rsync:start')) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    current = false;
    api.pause!.complete();
    await expectLater(pending, throwsStateError);
    expect(api.events.last, 'rsync:end');
    expect(api.rsyncChecks + api.rsyncReviews + api.mutations, 0);
  });
  test('connection change during first inventory prevents later reads and publication', () async {
    final api = _Fake()..pause = Completer<void>();
    var current = true;
    final pending = loadDataProtectionOverview(
      repository: api,
      endpoint: _endpoint,
      isCurrent: () => current,
    );
    await Future<void>.delayed(Duration.zero);
    current = false;
    api.pause!.complete();
    await expectLater(pending, throwsStateError);
    expect(api.events, ['snapshots:start', 'snapshots:end']);
  });
  test('provider respects pending operation lock and retries only when invalidated', () async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    final subscription = h.container.listen(
      dataProtectionOverviewProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    await expectLater(
      h.container.read(dataProtectionOverviewProvider.future),
      throwsStateError,
    );
    expect(h.api.events, isEmpty);
    lock.release(owner);
    h.container.invalidate(dataProtectionOverviewProvider);
    expect(
      (await h.container.read(dataProtectionOverviewProvider.future))
          .tasks
          .length,
      11,
    );
    final next = lock.acquire();
    expect(next, isNotNull);
    lock.release(next!);
  });
  test(
    'disposal stops remaining families and releases original lock',
    () async {
      final h = _Harness();
      h.api.pause = Completer<void>();
      final lock = h.container.read(serverOperationLockProvider);
      final pending = h.container.read(dataProtectionOverviewProvider.future);
      // Attach an error listener before disposing a provider-owned future.
      final observed = pending.then<Object>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(Duration.zero);
      h.container.dispose();
      h.api.pause!.complete();
      await observed;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.api.events, ['snapshots:start', 'snapshots:end']);
      final next = lock.acquire();
      expect(next, isNotNull);
      lock.release(next!);
    },
  );
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets('overview and charts fit $width at200percent dark=$dark', (
        tester,
      ) async {
        _size(tester, width);
        final h = _Harness();
        addTearDown(h.container.dispose);
        await _pump(tester, h, dark: dark);
        expect(find.text('Policies at a glance'), findsOneWidget);
        expect(
          find.byKey(const Key('protection-enablement-chart')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('protection-search')));
        await tester.enterText(
          find.byKey(const Key('protection-search')),
          'Documents',
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            '3 matching policies; charts above always include all loaded policies.',
          ),
          findsOneWidget,
        );
        expect(h.api.mutations, 0);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'navigation enters dedicated workspace without issuing any mutation',
    (tester) async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      await _pump(tester, h);
      final button = find.byKey(const Key('protection-open-replication'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(ReplicationPage), findsOneWidget);
      expect(h.api.mutations, 0);
    },
  );
  testWidgets(
    'unavailable counts never appear as zero source and no raw diagnostics',
    (tester) async {
      final h = _Harness();
      h.api.fail = 'cloud';
      addTearDown(h.container.dispose);
      await _pump(tester, h);
      expect(find.textContaining('PARTIAL COVERAGE'), findsOneWidget);
      expect(find.textContaining(_private), findsNothing);
      expect(
        find.textContaining('Counts are unavailable, not zero.'),
        findsOneWidget,
      );
      expect(h.api.events.where((e) => e == 'cloud:start').length, 1);
    },
  );
  testWidgets(
    'Rsync workspace re-entry reloads only its replaced inventory lease',
    (tester) async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      final first = await tester.runAsync(
        () => h.container.read(rsyncInventoryProvider.future),
      );
      await _pump(tester, h);
      // The overview's direct read replaced the adapter lease; the cached native
      // provider must not be reused even though it belongs to the same session.
      expect(h.api.events.where((e) => e == 'rsync:start').length, 2);
      expect(
        identical(
          h.container.read(rsyncInventoryProvider).asData!.value,
          first,
        ),
        isTrue,
      );
      final button = find.byKey(const Key('protection-open-rsync'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(RsyncPage), findsOneWidget);
      expect(h.api.events.where((e) => e == 'rsync:start').length, 3);
      expect(
        identical(
          h.container.read(rsyncInventoryProvider).asData!.value,
          first,
        ),
        isFalse,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(h.api.events.where((e) => e == 'rsync:start').length, 4);
      for (final name in ['snapshots', 'replication', 'cloud']) {
        expect(h.api.events.where((e) => e == '$name:start').length, 1);
      }
      expect(h.api.rsyncChecks + h.api.rsyncReviews + h.api.mutations, 0);
    },
  );
  for (final width in [320.0, 430.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'Rsync local family and search fit $width at200percent with keyboard dark=$dark',
        (tester) async {
          _size(tester, width);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          addTearDown(tester.view.resetViewInsets);
          final h = _Harness();
          addTearDown(h.container.dispose);
          await _pump(tester, h, dark: dark);
          final search = find.byKey(const Key('protection-search'));
          await tester.ensureVisible(search);
          await tester.enterText(search, 'Documents');
          await tester.pumpAndSettle();
          final chip = find.widgetWithText(ChoiceChip, 'Rsync');
          await tester.ensureVisible(chip);
          await tester.tap(chip);
          await tester.pumpAndSettle();
          expect(
            find.text(
              '1 matching policies; charts above always include all loaded policies.',
            ),
            findsOneWidget,
          );
          expect(find.text('Documents overnight'), findsOneWidget);
          expect(
            find.textContaining('Recorded Rsync states may be stale'),
            findsOneWidget,
          );
          final row = find.byKey(const Key('protection-task-rsync:12'));
          await tester.ensureVisible(row);
          expect(tester.takeException(), isNull);
          expect(h.api.events.where((e) => e == 'rsync:start').length, 1);
          expect(h.api.rsyncChecks + h.api.rsyncReviews + h.api.mutations, 0);
        },
      );
    }
  }
  testWidgets(
    'failed Rsync source remains excluded in charts and local filters',
    (tester) async {
      final h = _Harness();
      h.api.fail = 'rsync';
      addTearDown(h.container.dispose);
      await _pump(tester, h);
      final semantics = tester.widget<Semantics>(
        find.byKey(const Key('protection-enablement-semantics')),
      );
      expect(
        semantics.properties.label,
        '8 loaded policies: 4 enabled, 4 disabled. Not backup health.',
      );
      expect(find.textContaining('PARTIAL COVERAGE'), findsOneWidget);
      expect(find.textContaining(_private), findsNothing);
      final chip = find.widgetWithText(ChoiceChip, 'Rsync');
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'No matching policies in the inventories that were successfully read.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Counts are unavailable, not zero.'),
        findsOneWidget,
      );
      expect(h.api.events.where((e) => e == 'rsync:start').length, 1);
    },
  );
  testWidgets('new session hides prior task data while new inventories load', (
    tester,
  ) async {
    final h = _Harness();
    addTearDown(h.container.dispose);
    await _pump(tester, h);
    await tester.ensureVisible(find.byKey(const Key('protection-search')));
    await tester.enterText(
      find.byKey(const Key('protection-search')),
      'Documents',
    );
    h.api.pause = Completer<void>();
    h.current = h.session();
    h.container.invalidate(dashboardActiveSessionProvider);
    await tester.pump();
    expect(find.text('Documents archive'), findsNothing);
    h.api.pause!.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('protection-search')))
          .controller!
          .text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<DataProtectionOverview> _load(_Fake api) => loadDataProtectionOverview(
  repository: api,
  endpoint: _endpoint,
  isCurrent: () => true,
  now: () => DateTime.utc(2026, 9, 13),
);

class _Unavailable implements SessionRepository {
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw StateError('No connector');
}

class _Fake extends _Unavailable
    with
        SnapshotSchedulesPreviewAdapter,
        ReplicationPreviewAdapter,
        CloudSyncPreviewAdapter,
        RsyncPreviewAdapter {
  final events = <String>[];
  int active = 0, peak = 0, mutations = 0;
  int rsyncReviews = 0, rsyncChecks = 0;
  String? fail;
  bool wrongEndpoint = false;
  String? rsyncEndpoint;
  List<RsyncTask>? rsyncTasks;
  String pauseFamily = 'snapshots';
  Completer<void>? pause;
  Future<T> _read<T>(String name, Future<T> Function() read) async {
    events.add('$name:start');
    active++;
    if (active > peak) peak = active;
    try {
      if (name == pauseFamily) await pause?.future;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (fail == name) throw StateError(_private);
      return await read();
    } finally {
      active--;
      events.add('$name:end');
    }
  }

  @override
  Future<SnapshotScheduleInventory> loadSnapshotSchedules() =>
      _read('snapshots', super.loadSnapshotSchedules);
  @override
  Future<ReplicationInventory> loadReplication() =>
      _read('replication', () async {
        final i = await super.loadReplication();
        return wrongEndpoint
            ? ReplicationInventory(
                endpoint: 'wss://wrong.example/api/current',
                tasks: i.tasks,
                datasets: i.datasets,
              )
            : i;
      });
  @override
  Future<CloudSyncInventory> loadCloudSync() =>
      _read('cloud', super.loadCloudSync);
  @override
  Future<RsyncInventory> loadRsync() => _read('rsync', () async {
    final inventory = await super.loadRsync();
    return RsyncInventory(
      endpoint: rsyncEndpoint ?? inventory.endpoint,
      timezone: inventory.timezone,
      failoverLicensed: inventory.failoverLicensed,
      tasks: rsyncTasks ?? inventory.tasks,
      connections: inventory.connections,
      users: inventory.users,
      datasets: inventory.datasets,
      conflictingJob: inventory.conflictingJob,
    );
  });
  @override
  Future<RsyncReview> reviewRsync(RsyncRequest request) {
    rsyncReviews++;
    return super.reviewRsync(request);
  }

  @override
  Future<RsyncResult> executeRsync(RsyncReview review, String confirmation) {
    mutations++;
    return super.executeRsync(review, confirmation);
  }

  @override
  Future<RsyncResult> checkRsyncJob(RsyncJob job) {
    rsyncChecks++;
    return super.checkRsyncJob(job);
  }

  @override
  Future<SnapshotScheduleResult> executeSnapshotSchedule(
    SnapshotScheduleReview review,
    String confirmation,
  ) {
    mutations++;
    return super.executeSnapshotSchedule(review, confirmation);
  }

  @override
  Future<ReplicationResult> executeReplication(
    ReplicationReview review,
    String confirmation,
  ) {
    mutations++;
    return super.executeReplication(review, confirmation);
  }

  @override
  Future<CloudSyncResult> executeCloudSync(
    CloudSyncReview review,
    String confirmation,
  ) {
    mutations++;
    return super.executeCloudSync(review, confirmation);
  }
}

class _Harness {
  _Harness() {
    current = session();
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => current),
      ],
    );
  }
  final api = _Fake();
  AuthenticatedSession? current;
  late final ProviderContainer container;
  AuthenticatedSession session() => AuthenticatedSession(
    profileId: 'sample',
    repository: api,
    availableMethodNames: const {},
    version: '25.10.1',
    endpoint: _endpoint,
  );
}

void _size(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.binding.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> _pump(WidgetTester tester, _Harness h, {bool dark = true}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
        home: const DataProtectionPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
