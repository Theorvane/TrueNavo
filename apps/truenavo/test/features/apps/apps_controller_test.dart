import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/apps/apps_controller.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

const _app = InstalledApp(
  id: 'media',
  name: 'media',
  state: 'RUNNING',
  version: '1.0.0',
  catalogApp: 'jellyfin',
  train: 'community',
  customApp: false,
);
const _job = AppJob(id: 71, appName: 'media', operation: 'app.stop');
const _submitted = AppOperationResult(
  outcome: AppOperationOutcome.submitted,
  job: _job,
);
const _verified = AppOperationResult(
  outcome: AppOperationOutcome.verified,
  job: _job,
);

void main() {
  test(
    'duplicate commands remain blocked while submission owns the shared lock',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final completion = Completer<AppOperationResult>();
      h.api.onWrite = () => completion.future;
      final first = h.stop();
      expect(h.state.busy, isTrue);
      expect(h.lock.acquire(), isNull);
      await h.stop();
      expect(h.api.writes, 1);
      completion.complete(_verified);
      await first;
      expect(h.state.result!.outcome, AppOperationOutcome.verified);
      expect(h.state.server, h.session.endpoint);
      expect(h.lock.acquire(), isNotNull);
    },
  );

  test(
    'a different workflow owning the lock prevents application mutation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final other = h.lock.acquire()!;
      await h.stop();
      expect(h.api.writes, 0);
      expect(h.state.result!.outcome, AppOperationOutcome.rejected);
      expect(h.lock.acquire(), isNull);
      h.lock.release(other);
      await h.stop();
      expect(h.api.writes, 1);
    },
  );

  test(
    'known preflight rejection releases the lock without polling or retry',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onWrite = () =>
          Future.error(const AppsException(AppsExceptionReason.staleSnapshot));
      await h.stop();
      expect(h.state.result!.outcome, AppOperationOutcome.rejected);
      expect(h.state.locked, isFalse);
      expect(h.api.writes, 1);
      expect(h.api.polled, isEmpty);
      expect(h.lock.acquire(), isNotNull);
    },
  );

  test(
    'unknown dispatch retains the lock and does not leak remote errors',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onWrite = () =>
          Future.error(StateError('private credential or remote traceback'));
      await h.stop();
      expect(h.state.unknown, isTrue);
      expect(h.state.result!.userMessage, isNot(contains('credential')));
      expect(h.lock.acquire(), isNull);
      await h.stop();
      await h.controller.checkJob();
      expect(h.api.writes, 1);
      expect(h.api.polled, isEmpty);
      h.controller.acknowledgeAfterReconnect();
      expect(h.state.unknown, isTrue);
    },
  );

  test(
    'polls only the issued job and unlocks only after verified readback',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onWrite = () async => _submitted;
      h.api.onPoll = (_) async => const AppOperationResult(
        outcome: AppOperationOutcome.running,
        job: _job,
        progressPercent: 50,
      );
      await h.stop();
      expect(h.state.pending, isTrue);
      expect(h.lock.acquire(), isNull);
      await h.controller.checkJob();
      expect(h.state.pending, isTrue);
      expect(h.api.polled.single, same(_job));
      await h.stop();
      expect(h.api.writes, 1);
      h.api.onPoll = (_) async => _verified;
      await h.controller.checkJob();
      expect(h.api.polled, [_job, _job]);
      expect(h.state.result!.outcome, AppOperationOutcome.verified);
      expect(h.lock.acquire(), isNotNull);
    },
  );

  test(
    'a failed job releases the lock and never repeats its mutation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onWrite = () async => _submitted;
      h.api.onPoll = (_) async => const AppOperationResult(
        outcome: AppOperationOutcome.failed,
        job: _job,
      );
      await h.stop();
      await h.controller.checkJob();
      expect(h.state.result!.outcome, AppOperationOutcome.failed);
      expect(h.state.locked, isFalse);
      expect(h.api.writes, 1);
      expect(h.api.polled, [_job]);
      expect(h.lock.acquire(), isNotNull);
    },
  );

  test(
    'a poll transport failure becomes unknown and retains the lock',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onWrite = () async => _submitted;
      h.api.onPoll = (_) =>
          Future.error(TimeoutException('private RPC details'));
      await h.stop();
      await h.controller.checkJob();
      expect(h.state.unknown, isTrue);
      expect(h.state.result!.userMessage, isNot(contains('private RPC')));
      expect(h.lock.acquire(), isNull);
      await h.controller.checkJob();
      expect(h.api.polled, [_job]);
      expect(h.api.writes, 1);
    },
  );

  test('a read-only busy poll remains pending with its issued job', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onWrite = () async => _submitted;
    h.api.onPoll = (_) =>
        Future.error(const AppsException(AppsExceptionReason.busy));
    await h.stop();
    await h.controller.checkJob();
    expect(h.state.pending, isTrue);
    expect(h.state.unknown, isFalse);
    expect(h.state.result!.job, same(_job));
    expect(h.lock.acquire(), isNull);
    h.api.onPoll = (_) async => _verified;
    await h.controller.checkJob();
    expect(h.state.result!.outcome, AppOperationOutcome.verified);
    expect(h.api.writes, 1);
    expect(h.api.polled, [_job, _job]);
  });

  test('session replacement invalidates old confirmations even at the same endpoint', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.controller;
    h.select(_session(h.api));
    await h.stop();
    expect(h.api.writes, 0);
    h.select(null);
    await h.stop();
    expect(h.api.writes, 0);
  });

  test('late completion after session replacement cannot claim success or disclose the old app', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final completion = Completer<AppOperationResult>();
    h.api.onWrite = () => completion.future;
    final first = h.stop();
    h.select(_session(_AppsFake()));
    completion.complete(_verified);
    await first;
    expect(h.state.unknown, isTrue);
    expect(h.state.connectionCurrent, isFalse);
    expect(h.state.target, isNull);
    expect(h.state.server, isNull);
    expect(h.api.polled, isEmpty);
  });

  test('unknown outcome requires a new authenticated session before acknowledgement', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onWrite = () async =>
        const AppOperationResult(outcome: AppOperationOutcome.unknown);
    await h.stop();
    h.controller.acknowledgeAfterReconnect();
    expect(h.state.unknown, isTrue);
    h.select(null);
    h.controller.acknowledgeAfterReconnect();
    expect(h.state.unknown, isTrue);
    h.select(_session(_AppsFake()));
    h.controller.acknowledgeAfterReconnect();
    expect(h.state.unknown, isFalse);
    expect(h.state.locked, isFalse);
  });

  testWidgets(
    'automatic job polling is bounded and manual checks remain available',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onWrite = () async => _submitted;
      h.api.onPoll = (_) async => const AppOperationResult(
        outcome: AppOperationOutcome.running,
        job: _job,
      );
      await h.stop();
      for (var i = 0; i < 65; i++) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(h.api.polled, hasLength(60));
      expect(h.api.polled.every((job) => identical(job, _job)), isTrue);
      expect(h.api.writes, 1);
      expect(h.state.pending, isTrue);
      expect(h.lock.acquire(), isNull);
      await h.controller.checkJob();
      expect(h.api.polled, hasLength(61));
      h.api.onPoll = (_) async => _verified;
      await h.controller.checkJob();
      expect(h.state.result!.outcome, AppOperationOutcome.verified);
    },
  );

  testWidgets(
    'switching sessions cancels the accepted jobs automatic polling',
    (tester) async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onWrite = () async => _submitted;
      await h.stop();
      h.select(_session(_AppsFake()));
      await tester.pump(const Duration(seconds: 10));
      await h.controller.checkJob();
      expect(h.api.polled, isEmpty);
      expect(h.state.unknown, isTrue);
      expect(h.state.target, isNull);
    },
  );
}

AuthenticatedSession _session(_AppsFake api) => AuthenticatedSession(
  profileId: 'nas',
  repository: api,
  availableMethodNames: const {},
  version: '25.10.1',
  endpoint: 'wss://nas.example/api/current',
);

class _Harness {
  _Harness() {
    session = _session(api);
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final api = _AppsFake();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AppsController get controller =>
      container.read(appsControllerProvider.notifier);
  AppsState get state => container.read(appsControllerProvider);
  ServerOperationLock get lock => container.read(serverOperationLockProvider);
  Future<void> stop() =>
      controller.changeState(session, _app, AppLifecycleAction.stop);
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}

class _AppsFake implements SessionRepository, AuthenticatedAppsSession {
  int writes = 0;
  final polled = <AppJob>[];
  Future<AppOperationResult> Function()? onWrite;
  Future<AppOperationResult> Function(AppJob)? onPoll;
  @override
  AppsCapabilities get appsCapabilities => const AppsCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
  );
  @override
  Future<AppOperationResult> changeAppState(
    InstalledApp app,
    AppLifecycleAction action,
  ) async {
    writes++;
    return onWrite?.call() ?? _verified;
  }

  @override
  Future<AppOperationResult> pollAppJob(AppJob job) async {
    polled.add(job);
    return onPoll?.call(job) ?? _verified;
  }

  @override
  Future<AppsInventory> loadAppsInventory() async =>
      AppsInventory(apps: [_app], pool: 'tank', dockerStatus: 'RUNNING');
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
