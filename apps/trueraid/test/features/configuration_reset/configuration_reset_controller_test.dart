import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/configuration_reset/configuration_reset_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'configuration_reset_fakes.dart';

ConfigurationResetController controller(ResetHarness h) =>
    h.container.read(configurationResetControllerProvider.notifier);
ConfigurationResetState state(ResetHarness h) =>
    h.container.read(configurationResetControllerProvider);
Future<ConfigurationResetReview> review(ResetHarness h) async =>
    (await controller(h).review(
      expectedSession: h.session,
      inventory: h.api.inventory,
      isRouteCurrent: () => true,
    ))!;
Future<void> execute(
  ResetHarness h,
  ConfigurationResetReview review, {
  String? target,
  int? omittedConsent,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: target ?? review.target,
  consoleAccessAccepted: omittedConsent != 0,
  independentBackupAccepted: omittedConsent != 1,
  dataAndKeyRecoveryAccepted: omittedConsent != 2,
  configurationLossAccepted: omittedConsent != 3,
  rebootAndPartialFailureAccepted: omittedConsent != 4,
  pendingRestoreCheckedAccepted: omittedConsent != 5,
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

void expectLocked(ResetHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(ResetHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'readiness and review are read only, with full exact public target',
    () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      expect(r.target, 'RESET $resetHost');
      expect(h.api.reads, 1);
      expect(h.api.executes, isEmpty);
      expect(h.api.mutations, 0);
      expect(controller(h).isReviewCurrent(r), isTrue);
    },
  );
  for (var omitted = 0; omitted < 6; omitted++) {
    test('missing recovery consent $omitted blocks SDK execution', () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      await execute(h, r, omittedConsent: omitted);
      expect(h.api.executes, isEmpty);
      expect(h.api.mutations, 0);
      expectUnlocked(h);
    });
  }
  for (final target in [
    '',
    'RESET sample',
    'reset $resetHost',
    'RESET $resetHost ',
    ' RESET $resetHost',
  ]) {
    test('exact confirmation rejects [$target]', () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      await execute(h, await review(h), target: target);
      expect(h.api.executes, isEmpty);
    });
  }
  for (final entry in <String, ConfigurationResetInventory>{
    'HA': resetInventory(ha: true),
    'privileges': resetInventory(admin: false),
    'jobs': resetInventory(jobs: true),
    'boot': resetInventory(healthy: false),
    'state': resetInventory(state: 'BOOTING'),
    'nextboot': resetInventory(nextChanged: true),
  }.entries) {
    test('${entry.key} blocks review', () async {
      final h = ResetHarness(fake: ResetFake(inventory: entry.value));
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          inventory: h.api.inventory,
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
      expect(h.api.executes, isEmpty);
    });
  }
  test('unsupported capabilities and absent session block review', () async {
    final h = ResetHarness(
      fake: ResetFake(
        caps: const ConfigurationResetCapabilities.disconnected(),
      ),
    );
    addTearDown(h.dispose);
    await h.load();
    expect(
      await controller(h).review(
        expectedSession: h.session,
        inventory: h.api.inventory,
        isRouteCurrent: () => true,
      ),
      isNull,
    );
    h.select(null);
    expect(
      await controller(h).review(
        expectedSession: h.session,
        inventory: h.api.inventory,
        isRouteCurrent: () => true,
      ),
      isNull,
    );
    expect(h.api.reviews, isEmpty);
  });
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      'review late response after $cause does not issue authorization',
      () async {
        final h = ResetHarness();
        addTearDown(h.dispose);
        await h.load();
        final pending = Completer<ConfigurationResetReview>();
        h.api.onReview = (_) => pending.future;
        var route = true;
        final future = controller(h).review(
          expectedSession: h.session,
          inventory: h.api.inventory,
          isRouteCurrent: () => route,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            inventory: h.api.inventory,
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = resetInventory();
          h.container.invalidate(configurationResetInventoryProvider);
        }
        pending.complete(
          ConfigurationResetReview(
            request: h.api.reviews.single,
            endpoint: resetEndpoint,
            warnings: const [],
          ),
        );
        expect(await future, isNull);
        expect(h.api.executes, isEmpty);
        expect(h.api.reviews, hasLength(1));
      },
    );
    test('issued review expires after $cause', () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      var route = true;
      if (cause == 'session') {
        h.select(h.newSession());
        h.select(h.session);
      }
      if (cause == 'background') background();
      if (cause == 'route') {
        route = false;
        controller(h).abandonRoute();
      }
      if (cause == 'inventory') {
        h.api.inventory = resetInventory();
        h.container.invalidate(configurationResetInventoryProvider);
        await h.load();
      }
      await execute(h, r, route: () => route);
      expect(h.api.executes, isEmpty);
    });
    test(
      'SDK preflight after $cause cannot dispatch and retains unresolved fence',
      () async {
        final h = ResetHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h), pending = Completer<void>();
        var route = true;
        h.api.onExecute = (_, current) async {
          await pending.future;
          if (current()) h.api.mutations++;
          return const ConfigurationResetResult(
            ConfigurationResetOutcome.rejected,
            'stale',
          );
        };
        final future = execute(h, r, route: () => route);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = resetInventory();
          h.container.invalidate(configurationResetInventoryProvider);
        }
        pending.complete();
        await future;
        expect(h.api.mutations, 0);
        expect(state(h).status, ConfigurationResetStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final mismatch in ['request', 'endpoint', 'exception']) {
    test(
      'mismatched or failed $mismatch review exposes no remote error',
      () async {
        final h = ResetHarness();
        addTearDown(h.dispose);
        await h.load();
        h.api.onReview = (request) async {
          if (mismatch == 'exception') throw StateError('PRIVATE-RESET');
          return ConfigurationResetReview(
            request: mismatch == 'request'
                ? ConfigurationResetRequest(inventory: h.api.inventory)
                : request,
            endpoint: mismatch == 'endpoint'
                ? 'wss://other.example/api/current'
                : resetEndpoint,
            warnings: const [],
          );
        };
        expect(
          await controller(h).review(
            expectedSession: h.session,
            inventory: h.api.inventory,
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(state(h).message, isNot(contains('PRIVATE-RESET')));
        expect(h.api.executes, isEmpty);
      },
    );
  }
  test('forged review never dispatches', () async {
    final h = ResetHarness();
    addTearDown(h.dispose);
    await h.load();
    await execute(
      h,
      ConfigurationResetReview(
        request: ConfigurationResetRequest(inventory: h.api.inventory),
        endpoint: resetEndpoint,
        warnings: const [],
      ),
    );
    expect(h.api.executes, isEmpty);
  });
  test('shared operation lock prevents dispatch', () async {
    final h = ResetHarness();
    addTearDown(h.dispose);
    await h.load();
    final lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire()!;
    await execute(h, await review(h));
    expect(h.api.executes, isEmpty);
    expect(state(h).message, contains('Another operation'));
    lock.release(owner);
  });
  test(
    'duplicate in-flight and consumed review never repeat dispatch',
    () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h),
          pending = Completer<ConfigurationResetResult>();
      h.api.onExecute = (_, _) => pending.future;
      final future = execute(h, r);
      await execute(h, r);
      expect(h.api.executes, hasLength(1));
      pending.complete(
        const ConfigurationResetResult(
          ConfigurationResetOutcome.rejected,
          'rejected',
        ),
      );
      await future;
      await execute(h, r);
      expect(h.api.executes, hasLength(1));
      expectUnlocked(h);
    },
  );
  for (final outcome in [
    'accepted',
    'unknown',
    'nojob',
    'badjob',
    'hugejob',
    'exception',
    'typedexception',
  ]) {
    test(
      '$outcome never claims completion, polls, retries or releases write fence',
      () async {
        final h = ResetHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h);
        h.api.onExecute = (_, _) async {
          if (outcome == 'exception') throw StateError('PRIVATE-RESET');
          if (outcome == 'typedexception') {
            throw const ConfigurationResetException(
              ConfigurationResetExceptionReason.busy,
            );
          }
          return ConfigurationResetResult(
            outcome == 'unknown'
                ? ConfigurationResetOutcome.unknown
                : ConfigurationResetOutcome.accepted,
            'PRIVATE-RESET',
            jobId: outcome == 'nojob'
                ? null
                : outcome == 'badjob'
                ? -1
                : outcome == 'hugejob'
                ? 9007199254740992
                : 41,
          );
        };
        await execute(h, r);
        expect(
          state(h).status,
          outcome == 'accepted'
              ? ConfigurationResetStatus.accepted
              : ConfigurationResetStatus.unknown,
        );
        expect(state(h).message, isNot(contains('PRIVATE-RESET')));
        expectLocked(h);
        await execute(h, r);
        await controller(h).verifyReconnectedServer();
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
        expect(controller(h).canAcknowledge, isFalse);
        controller(h).abandonRoute();
        await Future<void>.delayed(Duration.zero);
        expectLocked(h);
      },
    );
  }
  test(
    'explicit rejection releases shared fence without trusting raw message',
    () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      await execute(h, await review(h));
      expect(state(h).status, ConfigurationResetStatus.rejected);
      expectUnlocked(h);
    },
  );
  for (final changed in [false, true]) {
    test(
      'explicit same-host recovery ${changed ? 'changed address needs extra consent' : 'same address'} only releases after inspection',
      () async {
        final h = ResetHarness();
        addTearDown(h.dispose);
        await h.load();
        h.api.onExecute = (_, _) async => const ConfigurationResetResult(
          ConfigurationResetOutcome.accepted,
          'accepted',
          jobId: 41,
        );
        await execute(h, await review(h));
        final endpoint = changed
            ? 'wss://recovered.example/api/current'
            : resetEndpoint;
        h.api.inventory = resetInventory(endpoint: endpoint);
        h.select(h.newSession(endpoint: endpoint));
        expect(h.api.reads, 1);
        expect(controller(h).canVerifyReconnectedServer, isTrue);
        expect(controller(h).canAcknowledge, isFalse);
        controller(h).acknowledgeAfterReconnect();
        expectLocked(h);
        await controller(h).verifyReconnectedServer();
        expect(h.api.reads, 2);
        expect(state(h).hostVerified, isTrue);
        expect(controller(h).canAcknowledge, !changed);
        if (changed) {
          controller(h).acknowledgeAfterReconnect();
          expectLocked(h);
          controller(h).acknowledgeChangedAddress(true);
        }
        controller(h).acknowledgeAfterReconnect();
        expectUnlocked(h);
        expect(state(h).message, contains('remains unverified'));
        expect(h.api.executes, hasLength(1));
      },
    );
  }
  for (final cause in [
    'differenthost',
    'endpointmismatch',
    'unready',
    'failure',
    'background',
    'session',
    'route',
  ]) {
    test('recovery $cause cannot release unresolved fence', () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (_, _) async => const ConfigurationResetResult(
        ConfigurationResetOutcome.unknown,
        'unknown',
      );
      await execute(h, await review(h));
      h.select(h.newSession());
      final pending = Completer<ConfigurationResetInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'background') background();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'failure') {
        pending.completeError(StateError('PRIVATE-RESET'));
      } else {
        pending.complete(
          resetInventory(
            hostId: cause == 'differenthost' ? 'f' * 64 : resetHost,
            endpoint: cause == 'endpointmismatch'
                ? 'wss://other.example/api/current'
                : resetEndpoint,
            state: cause == 'unready' ? 'BOOTING' : 'READY',
          ),
        );
      }
      await future;
      expect(state(h).hostVerified, isFalse);
      expect(controller(h).canAcknowledge, isFalse);
      expect(state(h).verificationMessage, isNot(contains('PRIVATE-RESET')));
      expectLocked(h);
    });
  }
  test(
    'late accepted response with replaced inventory remains unknown and fenced',
    () async {
      final h = ResetHarness();
      addTearDown(h.dispose);
      await h.load();
      final pending = Completer<ConfigurationResetResult>();
      h.api.onExecute = (_, _) => pending.future;
      final future = execute(h, await review(h));
      h.api.inventory = resetInventory();
      h.container.invalidate(configurationResetInventoryProvider);
      pending.complete(
        const ConfigurationResetResult(
          ConfigurationResetOutcome.accepted,
          'Synthetic acceptance',
          jobId: 41,
        ),
      );
      await future;
      expect(state(h).status, ConfigurationResetStatus.unknown);
      expect(state(h).jobId, isNull);
      expectLocked(h);
    },
  );
  test('old pending invocation prevents recovery acknowledgment after reconnect verification', () async {
    final h = ResetHarness();
    addTearDown(h.dispose);
    await h.load();
    final pending = Completer<ConfigurationResetResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, await review(h));
    h.select(h.newSession());
    await controller(h).verifyReconnectedServer();
    expect(state(h).hostVerified, isTrue);
    expect(controller(h).canAcknowledge, isFalse);
    controller(h).acknowledgeAfterReconnect();
    expectLocked(h);
    pending.complete(
      const ConfigurationResetResult(
        ConfigurationResetOutcome.accepted,
        'late',
        jobId: 41,
      ),
    );
    await future;
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expectUnlocked(h);
  });
}
