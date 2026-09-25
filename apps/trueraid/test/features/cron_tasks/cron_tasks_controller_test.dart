import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/cron_tasks/cron_tasks_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'cron_tasks_fakes.dart';

CronTasksController controller(CronHarness h) =>
    h.container.read(cronTasksControllerProvider.notifier);
CronTasksState state(CronHarness h) =>
    h.container.read(cronTasksControllerProvider);
Future<CronTasksReview> review(
  CronHarness h, {
  CronTasksAction action = CronTasksAction.edit,
  bool replace = false,
}) async => (await controller(h).review(
  expectedSession: h.session,
  request: cronRequest(h.api.inventory, action: action, replace: replace),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  CronHarness h,
  CronTasksReview r, {
  String? omit,
  String? target,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: r,
  confirmation: target ?? r.target,
  configurationImpactAccepted: omit != 'impact',
  executionImpactAccepted: omit != 'execution',
  commandRiskAccepted: omit != 'command',
  disclosureAccepted: omit != 'disclosure',
  isRouteCurrent: route ?? () => true,
);
void background() {
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.inactive,
  );
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.resumed,
  );
}

void locked(CronHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void unlocked(CronHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['route', 'inventory', 'disconnected']) {
    test('early $mode rejection wipes new capsule', () async {
      final h = CronHarness();
      addTearDown(h.dispose);
      await h.load();
      final req = cronRequest(h.api.inventory, replace: true);
      if (mode == 'inventory') {
        h.container.invalidate(cronTasksInventoryProvider);
      }
      if (mode == 'disconnected') {
        h.select(null);
      }
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: req,
          isRouteCurrent: () => mode != 'route',
        ),
        isNull,
      );
      expect(req.command!.isDisposed, isTrue);
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final mode in ['expire', 'abandon', 'refresh', 'complete', 'unknown']) {
    test('controller $mode wipes adopted replacement', () async {
      final h = CronHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h, replace: true);
      expect(r.request.command!.isDisposed, isFalse);
      switch (mode) {
        case 'expire':
          controller(h).expireContext();
        case 'abandon':
          controller(h).abandonRoute();
          await Future<void>.delayed(Duration.zero);
        case 'refresh':
          controller(h).refreshConfiguration();
        case 'complete':
          await execute(h, r);
        case 'unknown':
          h.api.onExecute = (_, _) async =>
              const CronTasksResult(CronTasksOutcome.unknown, 'private');
          await execute(h, r);
      }
      expect(r.request.command!.isDisposed, isTrue);
    });
  }
  for (final mode in CronTasksAction.values) {
    test('$mode reviewed one-use config only', () async {
      final h = CronHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h, action: mode);
      expect(h.api.executes, isEmpty);
      await execute(h, r);
      expect(h.api.mutations, 1);
      expect(state(h).status, CronTasksStatus.completed);
      expect(
        state(h).message,
        mode == CronTasksAction.run
            ? contains('may still be waiting')
            : contains('not established'),
      );
      expect(h.api.reads, 1);
      unlocked(h);
      await execute(h, r);
      expect(h.api.executes, hasLength(1));
    });
    for (final omit in [
      'impact',
      if (mode == CronTasksAction.enable || mode == CronTasksAction.run) ...[
        'execution',
        'disclosure',
      ],
      if (mode == CronTasksAction.create ||
          mode == CronTasksAction.edit ||
          mode == CronTasksAction.enable ||
          mode == CronTasksAction.run)
        'command',
    ]) {
      test('$mode requires $omit consent', () async {
        final h = CronHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action: mode);
        await execute(h, r, omit: omit);
        expect(h.api.executes, isEmpty);
        unlocked(h);
      });
    }
    test('$mode wrong target and forged review block', () async {
      final h = CronHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h, action: mode);
      await execute(h, r, target: '${r.target} ');
      await execute(
        h,
        CronTasksReview(
          request: r.request,
          endpoint: r.endpoint,
          warnings: const [],
        ),
      );
      expect(h.api.executes, isEmpty);
    });
  }
  for (final value in [
    cronInventory(admin: false),
    cronInventory(ha: true),
    cronInventory(jobs: true),
    cronInventory(healthy: false),
  ]) {
    test('readiness blocks ${value.readinessBlockedReason}', () async {
      final h = CronHarness(fake: CronFake(inventory: value));
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: cronRequest(value),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final phase in ['review', 'execute']) {
    for (final reason in ['background', 'route', 'disconnect', 'inventory']) {
      test('$phase late $reason cannot dispatch or unlock', () async {
        final h = CronHarness();
        addTearDown(h.dispose);
        await h.load();
        var route = true;
        if (phase == 'review') {
          final held = Completer<CronTasksReview>();
          h.api.onReview = (_) => held.future;
          final request = cronRequest(h.api.inventory),
              pending = controller(h).review(
                expectedSession: h.session,
                request: cronRequest(h.api.inventory),
                isRouteCurrent: () => route,
              );
          await Future<void>.delayed(Duration.zero);
          switch (reason) {
            case 'background':
              background();
            case 'route':
              route = false;
              controller(h).abandonRoute();
            case 'disconnect':
              h.select(null);
            case 'inventory':
              h.container.invalidate(cronTasksInventoryProvider);
          }
          held.complete(
            CronTasksReview(
              request: request,
              endpoint: h.api.inventory.endpoint,
              warnings: const [],
            ),
          );
          expect(await pending, isNull);
          expect(h.api.executes, isEmpty);
        } else {
          final r = await review(h), held = Completer<void>();
          var callback = true;
          h.api.onExecute = (_, current) async {
            await held.future;
            callback = current();
            return const CronTasksResult(CronTasksOutcome.completed, 'Late');
          };
          final pending = execute(h, r, route: () => route);
          await Future<void>.delayed(Duration.zero);
          switch (reason) {
            case 'background':
              background();
            case 'route':
              route = false;
              controller(h).abandonRoute();
            case 'disconnect':
              h.select(null);
            case 'inventory':
              h.container.invalidate(cronTasksInventoryProvider);
          }
          held.complete();
          await pending;
          expect(callback, isFalse);
          expect(state(h).status, CronTasksStatus.unknown);
          locked(h);
        }
      });
    }
  }
  for (final outcome in CronTasksOutcome.values) {
    test('typed result $outcome correct fence', () async {
      final h = CronHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      h.api.onExecute = (_, _) async =>
          CronTasksResult(outcome, 'PRIVATE_REMOTE_DETAILS');
      await execute(h, r);
      expect(state(h).message, isNot(contains('PRIVATE_REMOTE_DETAILS')));
      if (outcome == CronTasksOutcome.unknown) {
        locked(h);
      } else {
        unlocked(h);
      }
      expect(h.api.reads, 1);
    });
  }
  test('thrown execution unknown; no replay', () async {
    final h = CronHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    h.api.onExecute = (_, _) async => throw StateError('PRIVATE');
    await execute(h, r);
    expect(state(h).status, CronTasksStatus.unknown);
    locked(h);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    expect(state(h).message, isNot(contains('PRIVATE')));
  });
  test('global peer owner prevents SDK invocation', () async {
    final h = CronHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    final lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire();
    await execute(h, r);
    expect(h.api.executes, isEmpty);
    lock.release(owner!);
  });
  for (final wrong in [
    'same session',
    'other endpoint',
    'other host',
    'unready',
  ]) {
    test('recovery rejects $wrong', () async {
      final h = CronHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      h.api.onExecute = (_, _) async =>
          const CronTasksResult(CronTasksOutcome.unknown, 'Unknown');
      await execute(h, r);
      if (wrong != 'same session') {
        h.select(
          h.newSession(
            endpoint: wrong == 'other endpoint'
                ? 'wss://other.example/api/current'
                : h.session.endpoint,
          ),
        );
      }
      if (wrong == 'other host') {
        h.api.inventory = cronInventory(hostId: 'f' * 64);
      }
      if (wrong == 'unready') h.api.inventory = cronInventory(jobs: true);
      await controller(h).verifyReconnectedServer();
      expect(controller(h).canAcknowledge, isFalse);
      controller(h).acknowledgeAfterReconnect();
      locked(h);
    });
  }
  test('pending old future blocks recovery ACK until settled', () async {
    final h = CronHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h), held = Completer<CronTasksResult>();
    h.api.onExecute = (_, _) => held.future;
    final pending = execute(h, r);
    await Future<void>.delayed(Duration.zero);
    h.select(h.newSession());
    await controller(h).verifyReconnectedServer();
    expect(state(h).hostVerified, isTrue);
    expect(controller(h).canAcknowledge, isFalse);
    locked(h);
    held.complete(const CronTasksResult(CronTasksOutcome.completed, 'late'));
    await pending;
    expect(state(h).status, CronTasksStatus.unknown);
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    unlocked(h);
    expect(h.api.executes, hasLength(1));
  });
  test('refresh explicitly reads and consumes earlier review', () async {
    final h = CronHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    controller(h).refreshConfiguration();
    await h.load();
    expect(h.api.reads, 2);
    await execute(h, r);
    expect(h.api.executes, isEmpty);
  });
}
