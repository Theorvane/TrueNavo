import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/notification_providers/notification_providers_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'notification_providers_fakes.dart';

NotificationProvidersController controller(ProvidersHarness h) =>
    h.container.read(notificationProvidersControllerProvider.notifier);
NotificationProvidersState state(ProvidersHarness h) =>
    h.container.read(notificationProvidersControllerProvider);
Future<NotificationProvidersReview> review(
  ProvidersHarness h,
  NotificationProvidersAction action,
) async => (await controller(h).review(
  expectedSession: h.session,
  request: providersRequest(h.api.inventory, action),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  ProvidersHarness h,
  NotificationProvidersReview review, {
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
  unencryptedDisclosureAccepted: omit != 'unencrypted',
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

void expectLocked(ProvidersHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(ProvidersHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in NotificationProvidersAction.values) {
    test(
      '${action.name} needs review and exact confirmation; no test or automatic read',
      () async {
        final h = ProvidersHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action);
        expect(r.target, contains(providersHost));
        expect(h.api.executes, isEmpty);
        expect(h.api.mutations, 0);
        expect(h.api.reads, 1);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expect(state(h).status, NotificationProvidersStatus.completed);
        expect(state(h).message, contains('does not prove'));
        expectUnlocked(h);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
      },
    );
    for (final omit in [
      'impact',
      if (action == NotificationProvidersAction.enable) 'delivery',
      if (action == NotificationProvidersAction.disable ||
          action == NotificationProvidersAction.delete)
        'recall',
    ]) {
      test('${action.name} missing $omit consent blocks execution', () async {
        final h = ProvidersHarness();
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
        final h = ProvidersHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action);
        await execute(h, r, target: '${r.target} ');
        await execute(
          h,
          NotificationProvidersReview(
            request: r.request,
            endpoint: r.endpoint,
            warnings: const [],
            destinationSummary: 'Synthetic destination',
            publicFields: const {},
            unencrypted: false,
          ),
        );
        expect(h.api.executes, isEmpty);
      },
    );
    test('${action.name} missing capability blocks review', () async {
      final h = ProvidersHarness(
        fake: ProvidersFake(
          caps: NotificationProvidersCapabilities(
            connected: true,
            versionSupported: true,
            available: true,
            canCreate: action != NotificationProvidersAction.create,
            canDelete: action != NotificationProvidersAction.delete,
            canUpdate:
                action == NotificationProvidersAction.create ||
                action == NotificationProvidersAction.delete,
          ),
        ),
      );
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: providersRequest(h.api.inventory, action),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final entry in <String, NotificationProvidersInventory>{
    'HA': providersInventory(ha: true),
    'admin': providersInventory(admin: false),
    'jobs': providersInventory(jobs: true),
    'boot': providersInventory(healthy: false),
    'state': providersInventory(state: 'BOOTING'),
    'nextboot': providersInventory(nextChanged: true),
  }.entries) {
    test(
      '${entry.key} blocks writes but configuration remains readable',
      () async {
        final h = ProvidersHarness(fake: ProvidersFake(inventory: entry.value));
        addTearDown(h.dispose);
        await h.load();
        for (final action in NotificationProvidersAction.values) {
          expect(
            await controller(h).review(
              expectedSession: h.session,
              request: providersRequest(h.api.inventory, action),
              isRouteCurrent: () => true,
            ),
            isNull,
          );
        }
        expect(h.api.reviews, isEmpty);
      },
    );
  }
  for (final action in [
    NotificationProvidersAction.replace,
    NotificationProvidersAction.delete,
  ]) {
    test(
      '${action.name} cannot implicitly disable an enabled service',
      () async {
        final h = ProvidersHarness();
        addTearDown(h.dispose);
        await h.load();
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: providersRequest(
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
    NotificationProvidersAction.replace,
    NotificationProvidersAction.enable,
    NotificationProvidersAction.disable,
    NotificationProvidersAction.delete,
  ]) {
    test('${action.name} never mutates a non-Mail provider', () async {
      final h = ProvidersHarness();
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: providersRequest(
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
        final h = ProvidersHarness();
        addTearDown(h.dispose);
        await h.load();
        final pending = Completer<NotificationProvidersReview>();
        h.api.onReview = (_) => pending.future;
        var route = true;
        final future = controller(h).review(
          expectedSession: h.session,
          request: providersRequest(
            h.api.inventory,
            NotificationProvidersAction.create,
          ),
          isRouteCurrent: () => route,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: providersRequest(
              h.api.inventory,
              NotificationProvidersAction.create,
            ),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = providersInventory();
          h.container.invalidate(notificationProvidersInventoryProvider);
        }
        pending.complete(
          NotificationProvidersReview(
            request: h.api.reviews.single,
            endpoint: providersEndpoint,
            warnings: const [],
            destinationSummary: 'Synthetic destination',
            publicFields: const {},
            unencrypted: false,
          ),
        );
        expect(await future, isNull);
        expect(h.api.executes, isEmpty);
      },
    );
    test('issued review after $cause cannot execute', () async {
      final h = ProvidersHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h, NotificationProvidersAction.create);
      if (cause == 'session') {
        h.select(h.newSession());
        h.select(h.session);
      }
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'inventory') {
        h.api.inventory = providersInventory();
        h.container.invalidate(notificationProvidersInventoryProvider);
        await h.load();
      }
      await execute(h, r);
      expect(h.api.executes, isEmpty);
    });
    test(
      'held execute final check after $cause prevents fake dispatch and retains lock',
      () async {
        final h = ProvidersHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, NotificationProvidersAction.create),
            pending = Completer<void>();
        var route = true;
        h.api.onExecute = (_, current) async {
          await pending.future;
          if (current()) h.api.mutations++;
          return const NotificationProvidersResult(
            NotificationProvidersOutcome.rejected,
            'stale',
          );
        };
        final future = execute(h, r, route: () => route);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = providersInventory();
          h.container.invalidate(notificationProvidersInventoryProvider);
        }
        pending.complete();
        await future;
        expect(h.api.mutations, 0);
        expect(state(h).status, NotificationProvidersStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final kind in ['request', 'endpoint', 'error']) {
    test('$kind malformed review hides raw details', () async {
      final h = ProvidersHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onReview = (request) async {
        if (kind == 'error') throw StateError('PRIVATE-ALERT');
        return NotificationProvidersReview(
          request: kind == 'request'
              ? providersRequest(h.api.inventory, request.action)
              : request,
          endpoint: kind == 'endpoint'
              ? 'wss://other.example/api/current'
              : providersEndpoint,
          warnings: const [],
          destinationSummary: 'Synthetic destination',
          publicFields: const {},
          unencrypted: false,
        );
      };
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: providersRequest(
            h.api.inventory,
            NotificationProvidersAction.create,
          ),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(state(h).message, isNot(contains('PRIVATE-ALERT')));
    });
  }
  test('global owner prevents dispatch, duplicate in-flight review is consumed once', () async {
    final h = ProvidersHarness();
    addTearDown(h.dispose);
    await h.load();
    final blockedReview = await review(h, NotificationProvidersAction.create),
        lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire()!;
    await execute(h, blockedReview);
    expect(blockedReview.request.credentials!.isDisposed, isTrue);
    expect(h.api.executes, isEmpty);
    lock.release(owner);
    controller(h).refreshConfiguration();
    await h.load();
    final r = await review(h, NotificationProvidersAction.create);
    final pending = Completer<NotificationProvidersResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, r);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    pending.complete(
      const NotificationProvidersResult(
        NotificationProvidersOutcome.rejected,
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
        final h = ProvidersHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, NotificationProvidersAction.create);
        h.api.onExecute = (_, _) async {
          if (kind == 'exception') throw StateError('PRIVATE-ALERT');
          if (kind == 'typedexception') {
            throw const NotificationProvidersException(
              NotificationProvidersExceptionReason.busy,
            );
          }
          return const NotificationProvidersResult(
            NotificationProvidersOutcome.unknown,
            'PRIVATE-ALERT',
          );
        };
        await execute(h, r);
        expect(state(h).status, NotificationProvidersStatus.unknown);
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
      final h = ProvidersHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (_, _) async => const NotificationProvidersResult(
        NotificationProvidersOutcome.unknown,
        'unknown',
      );
      await execute(h, await review(h, NotificationProvidersAction.create));
      h.select(
        h.newSession(
          endpoint: cause == 'endpoint'
              ? 'wss://other.example/api/current'
              : providersEndpoint,
        ),
      );
      if (cause == 'endpoint') {
        expect(controller(h).canVerifyReconnectedServer, isFalse);
        expectLocked(h);
        return;
      }
      final pending = Completer<NotificationProvidersInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'failure') {
        pending.completeError(StateError('PRIVATE-ALERT'));
      } else {
        pending.complete(
          providersInventory(
            hostId: cause == 'differenthost' ? 'f' * 64 : providersHost,
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
    final h = ProvidersHarness();
    addTearDown(h.dispose);
    await h.load();
    final pending = Completer<NotificationProvidersResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(
      h,
      await review(h, NotificationProvidersAction.create),
    );
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
      const NotificationProvidersResult(
        NotificationProvidersOutcome.completed,
        'late',
      ),
    );
    await future;
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expectUnlocked(h);
    expect(state(h).message, contains('remains unverified'));
    expect(h.api.executes, hasLength(1));
  });
  for (final provider in NotificationProviderType.values) {
    test(
      '${provider.name} rejected confirmation zeroes owned capsule immediately',
      () async {
        final h = ProvidersHarness();
        addTearDown(h.dispose);
        await h.load();
        final request = providersRequest(
          h.api.inventory,
          NotificationProvidersAction.create,
          provider: provider,
        );
        final r = (await controller(h).review(
          expectedSession: h.session,
          request: request,
          isRouteCurrent: () => true,
        ))!;
        await execute(h, r, omit: 'impact');
        expect(request.credentials!.isDisposed, isTrue);
        expect(h.api.executes, isEmpty);
        expect(state(h).status, NotificationProvidersStatus.rejected);
      },
    );
  }
  for (final provider in [
    NotificationProviderType.influxDb,
    NotificationProviderType.snmpTrap,
  ]) {
    test(
      '${provider.name} enable requires separate plaintext disclosure consent',
      () async {
        final h = ProvidersHarness(
          fake: ProvidersFake(
            inventory: providersInventory(
              services: [
                NotificationProviderSnapshot(
                  id: 1,
                  name: 'Plaintext',
                  type: provider.wireName,
                  level: AlertDeliveryLevel.warning,
                  enabled: false,
                ),
              ],
            ),
          ),
        );
        addTearDown(h.dispose);
        await h.load();
        await execute(
          h,
          await review(h, NotificationProvidersAction.enable),
          omit: 'unencrypted',
        );
        expect(h.api.executes, isEmpty);
      },
    );
  }
}
