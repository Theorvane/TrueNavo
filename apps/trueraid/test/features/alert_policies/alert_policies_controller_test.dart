import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/alert_policies/alert_policies_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'alert_policies_fakes.dart';

AlertPoliciesController controller(PoliciesHarness h) =>
    h.container.read(alertPoliciesControllerProvider.notifier);
AlertPoliciesState state(PoliciesHarness h) =>
    h.container.read(alertPoliciesControllerProvider);
Future<AlertPoliciesReview> review(
  PoliciesHarness h, {
  bool reset = false,
  bool never = false,
  bool support = false,
}) async => (await controller(h).review(
  expectedSession: h.session,
  request: policiesRequest(
    h.api.inventory,
    reset: reset,
    never: never,
    support: support,
  ),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  PoliciesHarness h,
  AlertPoliciesReview r, {
  String? omit,
  String? target,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: r,
  confirmation: target ?? r.target,
  configurationImpactAccepted: omit != 'impact',
  visibilityImpactAccepted: omit != 'visibility',
  supportDisclosureAccepted: omit != 'support',
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

void locked(PoliciesHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void unlocked(PoliciesHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['configure', 'reset', 'never', 'support']) {
    test('$mode reviewed one-use config only', () async {
      final h = PoliciesHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(
        h,
        reset: mode == 'reset',
        never: mode == 'never',
        support: mode == 'support',
      );
      expect(h.api.executes, isEmpty);
      await execute(h, r);
      expect(h.api.mutations, 1);
      expect(state(h).status, AlertPoliciesStatus.completed);
      expect(state(h).message, contains('not established'));
      expect(h.api.reads, 1);
      unlocked(h);
      await execute(h, r);
      expect(h.api.executes, hasLength(1));
    });
    for (final omit in [
      'impact',
      if (mode == 'never') 'visibility',
      if (mode == 'reset' || mode == 'support') 'support',
    ]) {
      test('$mode requires $omit consent', () async {
        final h = PoliciesHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(
          h,
          reset: mode == 'reset',
          never: mode == 'never',
          support: mode == 'support',
        );
        await execute(h, r, omit: omit);
        expect(h.api.executes, isEmpty);
        unlocked(h);
      });
    }
    test('$mode wrong target and forged review block', () async {
      final h = PoliciesHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(
        h,
        reset: mode == 'reset',
        never: mode == 'never',
        support: mode == 'support',
      );
      await execute(h, r, target: '${r.target} ');
      await execute(
        h,
        AlertPoliciesReview(
          request: r.request,
          endpoint: r.endpoint,
          warnings: const [],
        ),
      );
      expect(h.api.executes, isEmpty);
    });
  }
  for (final value in [
    policiesInventory(admin: false),
    policiesInventory(ha: true),
    policiesInventory(jobs: true),
    policiesInventory(healthy: false),
  ]) {
    test('readiness blocks ${value.readinessBlockedReason}', () async {
      final h = PoliciesHarness(fake: PoliciesFake(inventory: value));
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: policiesRequest(value),
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
        final h = PoliciesHarness();
        addTearDown(h.dispose);
        await h.load();
        var route = true;
        if (phase == 'review') {
          final held = Completer<AlertPoliciesReview>();
          h.api.onReview = (_) => held.future;
          final request = policiesRequest(h.api.inventory),
              pending = controller(h).review(
                expectedSession: h.session,
                request: policiesRequest(h.api.inventory),
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
              h.container.invalidate(alertPoliciesInventoryProvider);
          }
          held.complete(
            AlertPoliciesReview(
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
            return const AlertPoliciesResult(
              AlertPoliciesOutcome.completed,
              'Late',
            );
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
              h.container.invalidate(alertPoliciesInventoryProvider);
          }
          held.complete();
          await pending;
          expect(callback, isFalse);
          expect(state(h).status, AlertPoliciesStatus.unknown);
          locked(h);
        }
      });
    }
  }
  for (final outcome in AlertPoliciesOutcome.values) {
    test('typed result $outcome correct fence', () async {
      final h = PoliciesHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      h.api.onExecute = (_, _) async =>
          AlertPoliciesResult(outcome, 'PRIVATE_REMOTE_DETAILS');
      await execute(h, r);
      expect(state(h).message, isNot(contains('PRIVATE_REMOTE_DETAILS')));
      if (outcome == AlertPoliciesOutcome.unknown) {
        locked(h);
      } else {
        unlocked(h);
      }
      expect(h.api.reads, 1);
    });
  }
  test('thrown execution unknown; no replay', () async {
    final h = PoliciesHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    h.api.onExecute = (_, _) async => throw StateError('PRIVATE');
    await execute(h, r);
    expect(state(h).status, AlertPoliciesStatus.unknown);
    locked(h);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    expect(state(h).message, isNot(contains('PRIVATE')));
  });
  test('global peer owner prevents SDK invocation', () async {
    final h = PoliciesHarness();
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
      final h = PoliciesHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      h.api.onExecute = (_, _) async =>
          const AlertPoliciesResult(AlertPoliciesOutcome.unknown, 'Unknown');
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
        h.api.inventory = policiesInventory(hostId: 'f' * 64);
      }
      if (wrong == 'unready') h.api.inventory = policiesInventory(jobs: true);
      await controller(h).verifyReconnectedServer();
      expect(controller(h).canAcknowledge, isFalse);
      controller(h).acknowledgeAfterReconnect();
      locked(h);
    });
  }
  test('pending old future blocks recovery ACK until settled', () async {
    final h = PoliciesHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h), held = Completer<AlertPoliciesResult>();
    h.api.onExecute = (_, _) => held.future;
    final pending = execute(h, r);
    await Future<void>.delayed(Duration.zero);
    h.select(h.newSession());
    await controller(h).verifyReconnectedServer();
    expect(state(h).hostVerified, isTrue);
    expect(controller(h).canAcknowledge, isFalse);
    locked(h);
    held.complete(
      const AlertPoliciesResult(AlertPoliciesOutcome.completed, 'late'),
    );
    await pending;
    expect(state(h).status, AlertPoliciesStatus.unknown);
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    unlocked(h);
    expect(h.api.executes, hasLength(1));
  });
  test('refresh explicitly reads and consumes earlier review', () async {
    final h = PoliciesHarness();
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
