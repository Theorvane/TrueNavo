import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/init_shutdown_tasks/init_shutdown_tasks_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'init_shutdown_tasks_fakes.dart';

InitShutdownTasksController controller(InitHarness h) =>
    h.container.read(initShutdownTasksControllerProvider.notifier);
InitShutdownTasksState state(InitHarness h) =>
    h.container.read(initShutdownTasksControllerProvider);
Future<InitShutdownTasksReview> review(
  InitHarness h, {
  InitShutdownTasksAction action = InitShutdownTasksAction.create,
  InitShutdownTasksRequest? request,
}) async => (await controller(h).review(
  expectedSession: h.session,
  request: request ?? initRequest(h.api.inventory, action),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  InitHarness h,
  InitShutdownTasksReview review, {
  String? target,
  String? omit,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: target ?? review.target,
  configurationImpactAccepted: omit != 'impact',
  rootExecutionAccepted: omit != 'root',
  independentlyInspectedCommand: omit != 'body',
  waitBudgetRiskAccepted: omit != 'budget',
  noCancellationAccepted: omit != 'cancel',
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

void expectLocked(InitHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(InitHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in InitShutdownTasksAction.values) {
    test(
      '${action.name} executes once, disposes body and hides stale inventory',
      () async {
        final h = InitHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action: action);
        expect(h.api.executes, isEmpty);
        expect(h.api.reads, 1);
        await execute(h, r);
        expect(state(h).status, InitShutdownTasksStatus.completed);
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expect(r.request.command?.isDisposed, isNot(false));
        expect(state(h).message, isNot(contains(initBody)));
        expectUnlocked(h);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
      },
    );
    for (final omit in [
      'impact',
      if (action == InitShutdownTasksAction.enable) ...[
        'root',
        'body',
        'budget',
      ],
      if (action == InitShutdownTasksAction.disable ||
          action == InitShutdownTasksAction.delete)
        'cancel',
    ]) {
      test(
        '${action.name} missing $omit rejected and owned body destroyed',
        () async {
          final h = InitHarness();
          addTearDown(h.dispose);
          await h.load();
          final r = await review(h, action: action);
          await execute(h, r, omit: omit);
          await execute(h, r);
          expect(h.api.executes, isEmpty);
          expect(r.request.command?.isDisposed, isNot(false));
          expectUnlocked(h);
        },
      );
    }
    test(
      '${action.name} early wrong confirmation destroys owned body',
      () async {
        final h = InitHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action: action);
        await execute(h, r, target: '${r.target} ');
        expect(r.request.command?.isDisposed, isNot(false));
        expect(h.api.executes, isEmpty);
      },
    );
  }
  for (final entry in <String, InitShutdownTasksInventory>{
    'HA': initInventory(ha: true),
    'admin': initInventory(admin: false),
    'jobs': initInventory(jobs: true),
    'boot': initInventory(healthy: false),
    'nextboot': initInventory(nextChanged: true),
    'state': initInventory(state: 'BOOTING'),
  }.entries) {
    test(
      '${entry.key} headers readable but request command disposed',
      () async {
        final h = InitHarness(fake: InitFake(inventory: entry.value));
        addTearDown(h.dispose);
        await h.load();
        final request = initRequest(
          h.api.inventory,
          InitShutdownTasksAction.create,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: request,
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(request.command!.isDisposed, true);
        expect(h.api.reviews, isEmpty);
      },
    );
  }
  for (final action in InitShutdownTasksAction.values.where(
    (a) => a != InitShutdownTasksAction.create,
  )) {
    test('${action.name} SCRIPT protected', () async {
      final h = InitHarness();
      addTearDown(h.dispose);
      await h.load();
      final request = initRequest(
        h.api.inventory,
        action,
        task: h.api.inventory.tasks.last,
      );
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: request,
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
      request.command?.dispose();
    });
  }
  test(
    'nonhex opaque reference is rejected without exposing supplied body',
    () async {
      final h = InitHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onReview = (request) async => InitShutdownTasksReview(
        request: request,
        endpoint: initEndpoint,
        warnings: const [],
        commandReference: initBody,
      );
      final request = initRequest(
        h.api.inventory,
        InitShutdownTasksAction.create,
      );
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: request,
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(request.command!.isDisposed, true);
      expect(state(h).message, isNot(contains(initBody)));
    },
  );
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      'review late response after $cause cannot issue authorization',
      () async {
        final h = InitHarness();
        addTearDown(h.dispose);
        await h.load();
        final pending = Completer<InitShutdownTasksReview>();
        h.api.onReview = (_) => pending.future;
        var route = true;
        final future = controller(h).review(
          expectedSession: h.session,
          request: initRequest(h.api.inventory, InitShutdownTasksAction.create),
          isRouteCurrent: () => route,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: initRequest(
              h.api.inventory,
              InitShutdownTasksAction.create,
            ),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = initInventory();
          h.container.invalidate(initShutdownTasksInventoryProvider);
        }
        pending.complete(
          InitShutdownTasksReview(
            request: h.api.reviews.single,
            endpoint: initEndpoint,
            warnings: const [],
            commandReference: 'f' * 64,
          ),
        );
        expect(await future, isNull);
        expect(h.api.executes, isEmpty);
      },
    );
    test('issued review after $cause cannot execute', () async {
      final h = InitHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      if (cause == 'session') {
        h.select(h.newSession());
        h.select(h.session);
      }
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'inventory') {
        h.api.inventory = initInventory();
        h.container.invalidate(initShutdownTasksInventoryProvider);
        await h.load();
      }
      await execute(h, r);
      expect(h.api.executes, isEmpty);
    });
    test(
      'held execute final check after $cause prevents fake dispatch and retains lock',
      () async {
        final h = InitHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h), pending = Completer<void>();
        var route = true;
        h.api.onExecute = (_, current) async {
          await pending.future;
          if (current()) h.api.mutations++;
          return const InitShutdownTasksResult(
            InitShutdownTasksOutcome.rejected,
            'stale',
          );
        };
        final future = execute(h, r, route: () => route);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = initInventory();
          h.container.invalidate(initShutdownTasksInventoryProvider);
        }
        pending.complete();
        await future;
        expect(h.api.mutations, 0);
        expect(state(h).status, InitShutdownTasksStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final kind in ['request', 'endpoint', 'error']) {
    test('$kind malformed review hides raw details', () async {
      final h = InitHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onReview = (request) async {
        if (kind == 'error') throw StateError('PRIVATE-INIT');
        return InitShutdownTasksReview(
          request: kind == 'request'
              ? initRequest(h.api.inventory, InitShutdownTasksAction.create)
              : request,
          endpoint: kind == 'endpoint'
              ? 'wss://other.example/api/current'
              : initEndpoint,
          warnings: const [],
          commandReference: 'f' * 64,
        );
      };
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: initRequest(h.api.inventory, InitShutdownTasksAction.create),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(state(h).message, isNot(contains('PRIVATE-INIT')));
    });
  }
  test('global owner prevents dispatch, duplicate in-flight review is consumed once', () async {
    final h = InitHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h),
        lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire()!;
    await execute(h, r);
    expect(h.api.executes, isEmpty);
    lock.release(owner);
    controller(h).refreshConfiguration();
    await h.load();
    final next = await review(h);
    final pending = Completer<InitShutdownTasksResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, next);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    pending.complete(
      const InitShutdownTasksResult(
        InitShutdownTasksOutcome.rejected,
        'rejected',
      ),
    );
    await future;
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    expectUnlocked(h);
  });
  for (final kind in ['unknown', 'exception', 'typedexception']) {
    test(
      '$kind is terminal with no automatic read/retry and route-persistent lock',
      () async {
        final h = InitHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h);
        h.api.onExecute = (_, _) async {
          if (kind == 'exception') throw StateError('PRIVATE-INIT');
          if (kind == 'typedexception') {
            throw const InitShutdownTasksException(
              InitShutdownTasksExceptionReason.busy,
            );
          }
          return const InitShutdownTasksResult(
            InitShutdownTasksOutcome.unknown,
            'PRIVATE-INIT',
          );
        };
        await execute(h, r);
        expect(state(h).status, InitShutdownTasksStatus.unknown);
        expect(state(h).message, isNot(contains('PRIVATE-INIT')));
        await execute(h, r);
        await controller(h).verifyReconnectedServer();
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
        controller(h).abandonRoute();
        await Future<void>.delayed(Duration.zero);
        expectLocked(h);
      },
    );
  }
  for (final cause in [
    'differenthost',
    'unready',
    'endpoint',
    'background',
    'route',
    'session',
    'failure',
  ]) {
    test('recovery $cause never releases unverified write fence', () async {
      final h = InitHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (_, _) async => const InitShutdownTasksResult(
        InitShutdownTasksOutcome.unknown,
        'unknown',
      );
      await execute(h, await review(h));
      h.select(
        h.newSession(
          endpoint: cause == 'endpoint'
              ? 'wss://other.example/api/current'
              : initEndpoint,
        ),
      );
      if (cause == 'endpoint') {
        expect(controller(h).canVerifyReconnectedServer, isFalse);
        expectLocked(h);
        return;
      }
      final pending = Completer<InitShutdownTasksInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'failure') {
        pending.completeError(StateError('PRIVATE-INIT'));
      } else {
        pending.complete(
          initInventory(
            hostId: cause == 'differenthost' ? 'f' * 64 : initHost,
            state: cause == 'unready' ? 'BOOTING' : 'READY',
          ),
        );
      }
      await future;
      expect(state(h).hostVerified, isFalse);
      expect(controller(h).canAcknowledge, isFalse);
      expectLocked(h);
    });
  }
  test('recovery is explicit same-host read plus independent ACK after old invocation settles', () async {
    final h = InitHarness();
    addTearDown(h.dispose);
    await h.load();
    final pending = Completer<InitShutdownTasksResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, await review(h));
    h.select(h.newSession());
    expect(h.api.reads, 1);
    controller(h).acknowledgeAfterReconnect();
    expectLocked(h);
    await controller(h).verifyReconnectedServer();
    expect(h.api.reads, 2);
    expect(state(h).hostVerified, isTrue);
    expect(controller(h).canAcknowledge, isFalse);
    controller(h).acknowledgeAfterReconnect();
    expectLocked(h);
    pending.complete(
      const InitShutdownTasksResult(InitShutdownTasksOutcome.completed, 'late'),
    );
    await future;
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expectUnlocked(h);
    expect(state(h).message, contains('remains unverified'));
    expect(h.api.executes, hasLength(1));
  });
}
