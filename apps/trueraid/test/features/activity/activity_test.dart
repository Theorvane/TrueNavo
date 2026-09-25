import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/activity/activity_controller.dart';
import 'package:trueraid/features/activity/activity_page.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

final _job = ActivityJob(
  id: 12,
  method: 'pool.scrub',
  state: ActivityJobState.running,
  abortable: true,
  progressPercent: 42,
  startedAt: DateTime.utc(2026, 9, 12),
);
AuthenticatedSession _session(_Api api) => AuthenticatedSession(
  profileId: 'test',
  repository: api,
  availableMethodNames: const {},
  version: '25.10.1',
  endpoint: 'wss://fixture.invalid/api/current',
);

void main() {
  testWidgets(
    'reconnection hides an open cancellation review and prevents dispatch',
    (tester) async {
      final h = await _pump(tester);
      await _tap(tester, find.byKey(const ValueKey('cancel-job-12')));
      await tester.enterText(
        find.byKey(const Key('job-cancel-confirmation')),
        'job 12',
      );
      h.select(_session(_Api()));
      await tester.pumpAndSettle();
      expect(
        find.text('The server changed. Close this review and reload.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('job-cancel-confirmation')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Request cancellation'),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, 0);
    },
  );
  testWidgets(
    'failed reads expose a manual retry without background retry timers',
    (tester) async {
      final api = _Api()..failReads = true;
      await _pump(tester, api: api);
      await _visible(tester, find.text('Retry read'));
      await tester.pump(const Duration(seconds: 30));
      expect(api.reads, 1);
      expect(api.writes, 0);
      api.failReads = false;
      await _tap(tester, find.text('Retry read'));
      expect(api.reads, 2);
    },
  );
  test(
    'pending cancellation holds shared lock and polls without another write',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      await h.controller.cancel(h.session, _job, 'job 12');
      expect(h.api.writes, 1);
      expect(h.lock.acquire(), isNull);
      await h.controller.cancel(h.session, _job, 'job 12');
      expect(h.api.writes, 1);
      await h.controller.check();
      expect(h.api.checks, 1);
      expect(h.lock.acquire(), isNotNull);
    },
  );
  test(
    'wrong confirmation, replaced session and another lock reject before write',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      await h.controller.cancel(h.session, _job, '12');
      expect(h.api.writes, 0);
      final owner = h.lock.acquire()!;
      await h.controller.cancel(h.session, _job, 'job 12');
      expect(h.api.writes, 0);
      h.lock.release(owner);
      h.select(_session(h.api));
      await h.controller.cancel(h.session, _job, 'job 12');
      expect(h.api.writes, 0);
    },
  );
  test(
    'unknown blocks retries until actual reconnect and acknowledgement',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      h.api.outcome = JobCancelOutcome.unknown;
      await h.controller.cancel(h.session, _job, 'job 12');
      expect(h.lock.acquire(), isNull);
      h.controller.acknowledgeUnknown();
      expect(h.state.unresolved, isTrue);
      h.select(null);
      h.controller.acknowledgeUnknown();
      expect(h.state.unresolved, isTrue);
      h.select(_session(_Api()));
      h.controller.acknowledgeUnknown();
      expect(h.state.unresolved, isFalse);
    },
  );
  test(
    'late completion after reconnect does not overwrite unknown result',
    () async {
      final h = _Harness();
      addTearDown(h.container.dispose);
      final pending = Completer<JobCancelResult>();
      h.api.pending = pending;
      final work = h.controller.cancel(h.session, _job, 'job 12');
      h.select(_session(_Api()));
      pending.complete(
        const JobCancelResult(JobCancelOutcome.verified, 'Late success'),
      );
      await work;
      expect(h.state.unresolved, isTrue);
    },
  );
  testWidgets('jobs show progress and safe summaries without mutation', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _visible(tester, find.text('42%'));
    expect(find.text('pool.scrub'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('1 jobs on this page'), findsOneWidget);
    expect(h.api.writes, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('exact typed review is required before cancellation', (
    tester,
  ) async {
    final h = await _pump(tester);
    await _tap(tester, find.byKey(const ValueKey('cancel-job-12')));
    expect(h.api.writes, 0);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Request cancellation'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('job-cancel-confirmation')),
      'job 12',
    );
    await _tap(tester, find.text('Request cancellation'));
    expect(h.api.writes, 1);
    await _tap(tester, find.text('Check cancellation status'));
    expect(h.api.checks, 1);
    expect(h.api.writes, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('read-only capability disables cancellation controls', (
    tester,
  ) async {
    final api = _Api()..writable = false;
    await _pump(tester, api: api);
    await _visible(tester, find.byKey(const ValueKey('cancel-job-12')));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('cancel-job-12')))
          .onPressed,
      isNull,
    );
    expect(api.writes, 0);
  });
  testWidgets('audit screen applies anchored filters and never writes', (
    tester,
  ) async {
    final h = await _pump(tester, audit: true);
    await _tap(tester, find.text('Apply / refresh'));
    expect(h.api.auditQueries.last.service, AuditService.middleware);
    expect(h.api.auditQueries.last.valid, isTrue);
    await _visible(tester, find.text('METHOD_CALL'));
    expect(find.text('METHOD_CALL'), findsOneWidget);
    expect(h.api.writes, 0);
    expect(tester.takeException(), isNull);
  });
  for (final audit in [false, true]) {
    testWidgets('320px at 200% has no overflow (${audit ? 'audit' : 'jobs'})', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(tester, audit: audit, scale: 2);
      for (var i = 0; i < 10; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -350));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _visible(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _visible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      240,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<_Harness> _pump(
  WidgetTester tester, {
  _Api? api,
  bool audit = false,
  double scale = 1,
}) async {
  final h = _Harness(api: api);
  addTearDown(h.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueRAIDTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ActivityPage(initialAudit: audit),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

class _Harness {
  _Harness({_Api? api}) : api = api ?? _Api() {
    session = _session(this.api);
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final _Api api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  ActivityController get controller =>
      container.read(activityControllerProvider.notifier);
  ActivityState get state => container.read(activityControllerProvider);
  ServerOperationLock get lock => container.read(serverOperationLockProvider);
  void select(AuthenticatedSession? value) {
    active = value;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }
}

class _Api implements SessionRepository, AuthenticatedActivitySession {
  int reads = 0;
  bool failReads = false;
  int writes = 0, checks = 0;
  bool writable = true;
  JobCancelOutcome outcome = JobCancelOutcome.pending;
  Completer<JobCancelResult>? pending;
  final auditQueries = <AuditQuery>[];
  @override
  ActivityCapabilities get activityCapabilities => ActivityCapabilities(
    supported: true,
    canReadJobs: true,
    canReadAudit: true,
    canCancelJobs: writable,
  );
  @override
  Future<JobPage> loadActivityJobs(JobQuery query) async {
    reads++;
    if (failReads) {
      throw const ActivityException(ActivityExceptionReason.unavailable);
    }
    return JobPage(entries: [_job], hasMore: false);
  }

  @override
  Future<AuditPage> loadAuditEvents(AuditQuery query) async {
    auditQueries.add(query);
    return AuditPage(
      entries: [
        AuditEvent(
          id: 'event-1',
          timestamp: query.until.subtract(const Duration(minutes: 1)),
          username: 'admin',
          address: '10.0.0.1',
          service: query.service,
          event: 'METHOD_CALL',
          success: true,
        ),
      ],
      hasMore: false,
    );
  }

  @override
  Future<JobCancelResult> cancelActivityJob(
    ActivityJob job,
    String confirmation,
  ) async {
    writes++;
    return pending?.future ??
        JobCancelResult(outcome, 'Fixture cancellation status', job: job);
  }

  @override
  Future<JobCancelResult> checkActivityCancellation(ActivityJob job) async {
    checks++;
    return const JobCancelResult(JobCancelOutcome.verified, 'Fixture aborted');
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
  }) => throw UnsupportedError('No connections in tests');
}
