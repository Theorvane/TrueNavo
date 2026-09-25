import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/time_settings/time_settings_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'time_settings_fakes.dart';

TimeSettingsController controller(TimeHarness h) =>
    h.container.read(timeSettingsControllerProvider.notifier);
TimeSettingsState state(TimeHarness h) =>
    h.container.read(timeSettingsControllerProvider);
Future<TimeSettingsReview> review(
  TimeHarness h,
  TimeSettingsAction action, {
  bool burst = false,
}) async => (await controller(h).review(
  expectedSession: h.session,
  request: timeRequest(h.api.inventory, action, burst: burst),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  TimeHarness h,
  TimeSettingsReview review, {
  String? target,
  String? omit,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: target ?? review.target,
  serviceImpactAccepted: omit != 'impact',
  probeAccepted: omit != 'probe',
  scheduleImpactAccepted: omit != 'schedule',
  remainingSourcesAccepted: omit != 'remaining',
  controlledBurstAccepted: omit != 'burst',
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

void expectLocked(TimeHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(TimeHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in TimeSettingsAction.values) {
    test(
      '${action.name} review only reads; explicit confirmed write verifies configuration not synchronization',
      () async {
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action);
        expect(r.target, contains(timeHost));
        expect(h.api.executes, isEmpty);
        expect(h.api.mutations, 0);
        expect(h.api.reads, 1);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expect(state(h).status, TimeSettingsStatus.completed);
        expect(state(h).message, contains('does not prove'));
        expectUnlocked(h);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
      },
    );
    for (final omit in [
      'impact',
      if (action == TimeSettingsAction.timezone) 'schedule',
      if (action == TimeSettingsAction.deleteNtp) 'remaining',
      if (action == TimeSettingsAction.createNtp ||
          action == TimeSettingsAction.updateNtp)
        'probe',
    ]) {
      test('${action.name} missing $omit consent blocks execution', () async {
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        await execute(h, await review(h, action), omit: omit);
        expect(h.api.executes, isEmpty);
        expectUnlocked(h);
      });
    }
    test(
      '${action.name} wrong target and forged review cannot dispatch',
      () async {
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action);
        await execute(h, r, target: '${r.target} ');
        await execute(
          h,
          TimeSettingsReview(
            request: r.request,
            endpoint: r.endpoint,
            warnings: const [],
          ),
        );
        expect(h.api.executes, isEmpty);
      },
    );
    test('${action.name} missing capability blocks review', () async {
      final h = TimeHarness(
        fake: TimeFake(
          caps: TimeSettingsCapabilities(
            connected: true,
            versionSupported: true,
            available: true,
            canChangeTimezone: action != TimeSettingsAction.timezone,
            canCreateNtp: action != TimeSettingsAction.createNtp,
            canUpdateNtp: action != TimeSettingsAction.updateNtp,
            canDeleteNtp: action != TimeSettingsAction.deleteNtp,
          ),
        ),
      );
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: timeRequest(h.api.inventory, action),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final action in [
    TimeSettingsAction.createNtp,
    TimeSettingsAction.updateNtp,
  ]) {
    test(
      '${action.name} burst requires independent controlled-server consent',
      () async {
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action, burst: true);
        await execute(h, r, omit: 'burst');
        expect(h.api.executes, isEmpty);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
      },
    );
  }
  for (final entry in <String, TimeSettingsInventory>{
    'HA': timeInventory(ha: true),
    'admin': timeInventory(admin: false),
    'jobs': timeInventory(jobs: true),
    'boot': timeInventory(healthy: false),
    'state': timeInventory(state: 'BOOTING'),
    'nextboot': timeInventory(nextChanged: true),
  }.entries) {
    test(
      '${entry.key} blocks all writes but inventory stays available',
      () async {
        final h = TimeHarness(fake: TimeFake(inventory: entry.value));
        addTearDown(h.dispose);
        await h.load();
        for (final action in TimeSettingsAction.values) {
          expect(
            await controller(h).review(
              expectedSession: h.session,
              request: timeRequest(h.api.inventory, action),
              isRouteCurrent: () => true,
            ),
            isNull,
          );
        }
        expect(h.api.reviews, isEmpty);
      },
    );
  }
  for (final rollback in ['unknown', 'zero', 'positive']) {
    test(
      'GUI rollback $rollback blocks timezone but not separate NTP edit',
      () async {
        final h = TimeHarness(
          fake: TimeFake(
            inventory: timeInventory(
              rollbackKnown: rollback != 'unknown',
              rollback: rollback == 'zero'
                  ? 0
                  : rollback == 'positive'
                  ? 30
                  : null,
            ),
          ),
        );
        addTearDown(h.dispose);
        await h.load();
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: timeRequest(h.api.inventory, TimeSettingsAction.timezone),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(
          await review(h, TimeSettingsAction.createNtp),
          isA<TimeSettingsReview>(),
        );
        expect(h.api.executes, isEmpty);
      },
    );
  }
  test('last configured source cannot be deleted', () async {
    final h = TimeHarness(
      fake: TimeFake(inventory: timeInventory(servers: [timeServers.first])),
    );
    addTearDown(h.dispose);
    await h.load();
    expect(
      await controller(h).review(
        expectedSession: h.session,
        request: timeRequest(h.api.inventory, TimeSettingsAction.deleteNtp),
        isRouteCurrent: () => true,
      ),
      isNull,
    );
    expect(h.api.reviews, isEmpty);
  });
  for (final settings in [
    const NtpServerSettings(address: 'https://secret@example.com'),
    const NtpServerSettings(address: '2001:db8::1'),
    const NtpServerSettings(address: 'clock-one.example'),
    const NtpServerSettings(address: 'new.example', minPoll: 3),
    const NtpServerSettings(address: 'new.example', minPoll: 10, maxPoll: 10),
    const NtpServerSettings(address: 'new.example', maxPoll: 18),
  ]) {
    test(
      'unsupported new settings ${settings.address} ${settings.minPoll}/${settings.maxPoll} cannot reach review',
      () async {
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: timeRequest(
              h.api.inventory,
              TimeSettingsAction.createNtp,
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
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      'review late response after $cause cannot issue authorization',
      () async {
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        final pending = Completer<TimeSettingsReview>();
        h.api.onReview = (_) => pending.future;
        var route = true;
        final future = controller(h).review(
          expectedSession: h.session,
          request: timeRequest(h.api.inventory, TimeSettingsAction.createNtp),
          isRouteCurrent: () => route,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: timeRequest(h.api.inventory, TimeSettingsAction.createNtp),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = timeInventory();
          h.container.invalidate(timeSettingsInventoryProvider);
        }
        pending.complete(
          TimeSettingsReview(
            request: h.api.reviews.single,
            endpoint: timeEndpoint,
            warnings: const [],
          ),
        );
        expect(await future, isNull);
        expect(h.api.executes, isEmpty);
      },
    );
    test('issued review after $cause cannot execute', () async {
      final h = TimeHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h, TimeSettingsAction.createNtp);
      if (cause == 'session') {
        h.select(h.newSession());
        h.select(h.session);
      }
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'inventory') {
        h.api.inventory = timeInventory();
        h.container.invalidate(timeSettingsInventoryProvider);
        await h.load();
      }
      await execute(h, r);
      expect(h.api.executes, isEmpty);
    });
    test(
      'held execute final check after $cause prevents fake dispatch and retains lock',
      () async {
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, TimeSettingsAction.createNtp),
            pending = Completer<void>();
        var route = true;
        h.api.onExecute = (_, current) async {
          await pending.future;
          if (current()) h.api.mutations++;
          return const TimeSettingsResult(
            TimeSettingsOutcome.rejected,
            'stale',
          );
        };
        final future = execute(h, r, route: () => route);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = timeInventory();
          h.container.invalidate(timeSettingsInventoryProvider);
        }
        pending.complete();
        await future;
        expect(h.api.mutations, 0);
        expect(state(h).status, TimeSettingsStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final kind in ['request', 'endpoint', 'error']) {
    test('$kind malformed review hides raw details', () async {
      final h = TimeHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onReview = (request) async {
        if (kind == 'error') throw StateError('PRIVATE-TIME');
        return TimeSettingsReview(
          request: kind == 'request'
              ? timeRequest(h.api.inventory, request.action)
              : request,
          endpoint: kind == 'endpoint'
              ? 'wss://other.example/api/current'
              : timeEndpoint,
          warnings: const [],
        );
      };
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: timeRequest(h.api.inventory, TimeSettingsAction.createNtp),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(state(h).message, isNot(contains('PRIVATE-TIME')));
    });
  }
  test('global owner prevents dispatch, duplicate in-flight review is consumed once', () async {
    final h = TimeHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h, TimeSettingsAction.createNtp),
        lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire()!;
    await execute(h, r);
    expect(h.api.executes, isEmpty);
    lock.release(owner);
    final pending = Completer<TimeSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, r);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    pending.complete(
      const TimeSettingsResult(TimeSettingsOutcome.rejected, 'rejected'),
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
        final h = TimeHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, TimeSettingsAction.createNtp);
        h.api.onExecute = (_, _) async {
          if (kind == 'exception') throw StateError('PRIVATE-TIME');
          if (kind == 'typedexception') {
            throw const TimeSettingsException(TimeSettingsExceptionReason.busy);
          }
          return const TimeSettingsResult(
            TimeSettingsOutcome.unknown,
            'PRIVATE-TIME',
          );
        };
        await execute(h, r);
        expect(state(h).status, TimeSettingsStatus.unknown);
        expect(state(h).message, isNot(contains('PRIVATE-TIME')));
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
      final h = TimeHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (_, _) async =>
          const TimeSettingsResult(TimeSettingsOutcome.unknown, 'unknown');
      await execute(h, await review(h, TimeSettingsAction.createNtp));
      h.select(
        h.newSession(
          endpoint: cause == 'endpoint'
              ? 'wss://other.example/api/current'
              : timeEndpoint,
        ),
      );
      if (cause == 'endpoint') {
        expect(controller(h).canVerifyReconnectedServer, isFalse);
        expectLocked(h);
        return;
      }
      final pending = Completer<TimeSettingsInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'failure') {
        pending.completeError(StateError('PRIVATE-TIME'));
      } else {
        pending.complete(
          timeInventory(
            hostId: cause == 'differenthost' ? 'f' * 64 : timeHost,
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
    final h = TimeHarness();
    addTearDown(h.dispose);
    await h.load();
    final pending = Completer<TimeSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, await review(h, TimeSettingsAction.createNtp));
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
      const TimeSettingsResult(TimeSettingsOutcome.completed, 'late'),
    );
    await future;
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expectUnlocked(h);
    expect(state(h).message, contains('remains unverified'));
    expect(h.api.executes, hasLength(1));
  });
}
