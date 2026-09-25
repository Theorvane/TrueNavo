import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/alert_settings/alert_settings_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'alert_settings_fakes.dart';

AlertSettingsController controller(AlertHarness h) =>
    h.container.read(alertSettingsControllerProvider.notifier);
AlertSettingsState state(AlertHarness h) =>
    h.container.read(alertSettingsControllerProvider);
Future<AlertSettingsReview> review(
  AlertHarness h,
  AlertSettingsAction action,
) async => (await controller(h).review(
  expectedSession: h.session,
  request: alertRequest(h.api.inventory, action),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  AlertHarness h,
  AlertSettingsReview review, {
  String? target,
  String? omit,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: target ?? review.target,
  configurationImpactAccepted: omit != 'impact',
  externalDeliveryAccepted: omit != 'delivery',
  noRecallAccepted: omit != 'recall',
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

void expectLocked(AlertHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(AlertHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in AlertSettingsAction.values) {
    test(
      '${action.name} needs review and exact confirmation; no test or automatic read',
      () async {
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action);
        expect(r.target, contains(alertHost));
        expect(h.api.executes, isEmpty);
        expect(h.api.mutations, 0);
        expect(h.api.reads, 1);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expect(state(h).status, AlertSettingsStatus.completed);
        expect(state(h).message, contains('does not prove'));
        expectUnlocked(h);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
      },
    );
    for (final omit in [
      'impact',
      if (action == AlertSettingsAction.enableEmail) 'delivery',
      if (action == AlertSettingsAction.disableEmail ||
          action == AlertSettingsAction.deleteEmail)
        'recall',
    ]) {
      test('${action.name} missing $omit consent blocks execution', () async {
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        await execute(h, await review(h, action), omit: omit);
        expect(h.api.executes, isEmpty);
        expectUnlocked(h);
      });
    }
    test(
      '${action.name} wrong target or forged review cannot dispatch',
      () async {
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action);
        await execute(h, r, target: '${r.target} ');
        await execute(
          h,
          AlertSettingsReview(
            request: r.request,
            endpoint: r.endpoint,
            warnings: const [],
          ),
        );
        expect(h.api.executes, isEmpty);
      },
    );
    test('${action.name} missing capability blocks review', () async {
      final h = AlertHarness(
        fake: AlertFake(
          caps: AlertSettingsCapabilities(
            connected: true,
            versionSupported: true,
            available: true,
            canCreate: action != AlertSettingsAction.createEmail,
            canDelete: action != AlertSettingsAction.deleteEmail,
            canUpdate:
                action == AlertSettingsAction.createEmail ||
                action == AlertSettingsAction.deleteEmail,
          ),
        ),
      );
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: alertRequest(h.api.inventory, action),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final entry in <String, AlertSettingsInventory>{
    'HA': alertInventory(ha: true),
    'admin': alertInventory(admin: false),
    'jobs': alertInventory(jobs: true),
    'boot': alertInventory(healthy: false),
    'state': alertInventory(state: 'BOOTING'),
    'nextboot': alertInventory(nextChanged: true),
  }.entries) {
    test(
      '${entry.key} blocks writes but configuration remains readable',
      () async {
        final h = AlertHarness(fake: AlertFake(inventory: entry.value));
        addTearDown(h.dispose);
        await h.load();
        for (final action in AlertSettingsAction.values) {
          expect(
            await controller(h).review(
              expectedSession: h.session,
              request: alertRequest(h.api.inventory, action),
              isRouteCurrent: () => true,
            ),
            isNull,
          );
        }
        expect(h.api.reviews, isEmpty);
      },
    );
  }
  for (final settings in [
    const EmailAlertServiceSettings(name: '', recipient: 'one@example.test'),
    const EmailAlertServiceSettings(
      name: ' New ',
      recipient: 'one@example.test',
    ),
    const EmailAlertServiceSettings(name: 'New', recipient: ''),
    const EmailAlertServiceSettings(
      name: 'New',
      recipient: 'one@example.test,two@example.test',
    ),
    const EmailAlertServiceSettings(
      name: 'New',
      recipient: 'Name <one@example.test>',
    ),
    const EmailAlertServiceSettings(
      name: 'Storage warnings',
      recipient: 'one@example.test',
    ),
  ]) {
    test(
      'invalid create ${settings.name}/${settings.recipient} never reaches SDK review',
      () async {
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: alertRequest(
              h.api.inventory,
              AlertSettingsAction.createEmail,
              settings: settings,
            ),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(h.api.reviews, isEmpty);
      },
    );
  }
  for (final action in [
    AlertSettingsAction.editEmail,
    AlertSettingsAction.deleteEmail,
  ]) {
    test(
      '${action.name} cannot implicitly disable an enabled service',
      () async {
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: alertRequest(
              h.api.inventory,
              action,
              service: h.api.inventory.services[1],
            ),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(h.api.reviews, isEmpty);
      },
    );
  }
  for (final action in [
    AlertSettingsAction.editEmail,
    AlertSettingsAction.enableEmail,
    AlertSettingsAction.disableEmail,
    AlertSettingsAction.deleteEmail,
  ]) {
    test('${action.name} never mutates a non-Mail provider', () async {
      final h = AlertHarness();
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: alertRequest(
            h.api.inventory,
            action,
            service: h.api.inventory.services[2],
          ),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      'review late response after $cause cannot issue authorization',
      () async {
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        final pending = Completer<AlertSettingsReview>();
        h.api.onReview = (_) => pending.future;
        var route = true;
        final future = controller(h).review(
          expectedSession: h.session,
          request: alertRequest(
            h.api.inventory,
            AlertSettingsAction.createEmail,
          ),
          isRouteCurrent: () => route,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: alertRequest(
              h.api.inventory,
              AlertSettingsAction.createEmail,
            ),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = alertInventory();
          h.container.invalidate(alertSettingsInventoryProvider);
        }
        pending.complete(
          AlertSettingsReview(
            request: h.api.reviews.single,
            endpoint: alertEndpoint,
            warnings: const [],
          ),
        );
        expect(await future, isNull);
        expect(h.api.executes, isEmpty);
      },
    );
    test('issued review after $cause cannot execute', () async {
      final h = AlertHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h, AlertSettingsAction.createEmail);
      if (cause == 'session') {
        h.select(h.newSession());
        h.select(h.session);
      }
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'inventory') {
        h.api.inventory = alertInventory();
        h.container.invalidate(alertSettingsInventoryProvider);
        await h.load();
      }
      await execute(h, r);
      expect(h.api.executes, isEmpty);
    });
    test(
      'held execute final check after $cause prevents fake dispatch and retains lock',
      () async {
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, AlertSettingsAction.createEmail),
            pending = Completer<void>();
        var route = true;
        h.api.onExecute = (_, current) async {
          await pending.future;
          if (current()) h.api.mutations++;
          return const AlertSettingsResult(
            AlertSettingsOutcome.rejected,
            'stale',
          );
        };
        final future = execute(h, r, route: () => route);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = alertInventory();
          h.container.invalidate(alertSettingsInventoryProvider);
        }
        pending.complete();
        await future;
        expect(h.api.mutations, 0);
        expect(state(h).status, AlertSettingsStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final kind in ['request', 'endpoint', 'error']) {
    test('$kind malformed review hides raw details', () async {
      final h = AlertHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onReview = (request) async {
        if (kind == 'error') throw StateError('PRIVATE-ALERT');
        return AlertSettingsReview(
          request: kind == 'request'
              ? alertRequest(h.api.inventory, request.action)
              : request,
          endpoint: kind == 'endpoint'
              ? 'wss://other.example/api/current'
              : alertEndpoint,
          warnings: const [],
        );
      };
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: alertRequest(
            h.api.inventory,
            AlertSettingsAction.createEmail,
          ),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(state(h).message, isNot(contains('PRIVATE-ALERT')));
    });
  }
  test('global owner prevents dispatch, duplicate in-flight review is consumed once', () async {
    final h = AlertHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h, AlertSettingsAction.createEmail),
        lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire()!;
    await execute(h, r);
    expect(h.api.executes, isEmpty);
    lock.release(owner);
    final pending = Completer<AlertSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, r);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    pending.complete(
      const AlertSettingsResult(AlertSettingsOutcome.rejected, 'rejected'),
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
        final h = AlertHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, AlertSettingsAction.createEmail);
        h.api.onExecute = (_, _) async {
          if (kind == 'exception') throw StateError('PRIVATE-ALERT');
          if (kind == 'typedexception') {
            throw const AlertSettingsException(
              AlertSettingsExceptionReason.busy,
            );
          }
          return const AlertSettingsResult(
            AlertSettingsOutcome.unknown,
            'PRIVATE-ALERT',
          );
        };
        await execute(h, r);
        expect(state(h).status, AlertSettingsStatus.unknown);
        expect(state(h).message, isNot(contains('PRIVATE-ALERT')));
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
      final h = AlertHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (_, _) async =>
          const AlertSettingsResult(AlertSettingsOutcome.unknown, 'unknown');
      await execute(h, await review(h, AlertSettingsAction.createEmail));
      h.select(
        h.newSession(
          endpoint: cause == 'endpoint'
              ? 'wss://other.example/api/current'
              : alertEndpoint,
        ),
      );
      if (cause == 'endpoint') {
        expect(controller(h).canVerifyReconnectedServer, isFalse);
        expectLocked(h);
        return;
      }
      final pending = Completer<AlertSettingsInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'failure') {
        pending.completeError(StateError('PRIVATE-ALERT'));
      } else {
        pending.complete(
          alertInventory(
            hostId: cause == 'differenthost' ? 'f' * 64 : alertHost,
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
    final h = AlertHarness();
    addTearDown(h.dispose);
    await h.load();
    final pending = Completer<AlertSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, await review(h, AlertSettingsAction.createEmail));
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
      const AlertSettingsResult(AlertSettingsOutcome.completed, 'late'),
    );
    await future;
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expectUnlocked(h);
    expect(state(h).message, contains('remains unverified'));
    expect(h.api.executes, hasLength(1));
  });
}
