import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/system_power_preview.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/system_power/system_power_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'system_power_fakes.dart';

SystemPowerController controller(PowerHarness h) =>
    h.container.read(systemPowerControllerProvider.notifier);
SystemPowerState state(PowerHarness h) =>
    h.container.read(systemPowerControllerProvider);
Future<void> run(
  PowerHarness h,
  SystemPowerReview review, {
  String? confirmation,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: confirmation ?? review.target,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in SystemPowerAction.values) {
    test('$action rejection is single-use and releases global lock', () async {
      final h = PowerHarness();
      addTearDown(h.dispose);
      await h.load();
      final review = powerReview(h.api.inventory, action: action);
      await run(h, review);
      await run(h, review);
      expect(h.api.writes, hasLength(1));
      expect(state(h).locked, isFalse);
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    });
    test(
      '$action acceptance holds lock without completion or automatic reads',
      () async {
        final h = PowerHarness(
          fake: PowerFake()
            ..onExecute = (_) async => const SystemPowerResult(
              SystemPowerOutcome.accepted,
              'Queued',
              jobId: 80,
            ),
        );
        addTearDown(h.dispose);
        await h.load();
        await run(h, powerReview(h.api.inventory, action: action));
        expect(state(h).accepted, isTrue);
        expect(state(h).locked, isTrue);
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(h.api.reads, 1);
        expect(h.api.writes, hasLength(1));
        await run(h, powerReview(h.api.inventory));
        expect(h.api.writes, hasLength(1));
        expect(controller(h).canAcknowledge, isFalse);
      },
    );
  }
  for (final id in <int?>[null, 0, -1]) {
    test('accepted job identity $id becomes unknown and fenced', () async {
      final h = PowerHarness(
        fake: PowerFake()
          ..onExecute = (_) async => SystemPowerResult(
            SystemPowerOutcome.accepted,
            'Queued',
            jobId: id,
          ),
      );
      addTearDown(h.dispose);
      await h.load();
      await run(h, powerReview(h.api.inventory));
      expect(state(h).unknown, isTrue);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    });
  }
  test('duplicate in-flight submit sends only once', () async {
    final pending = Completer<SystemPowerResult>();
    final h = PowerHarness(
      fake: PowerFake()..onExecute = (_) => pending.future,
    );
    addTearDown(h.dispose);
    await h.load();
    final review = powerReview(h.api.inventory);
    final first = run(h, review);
    await run(h, review);
    expect(state(h).busy, isTrue);
    expect(h.api.writes, hasLength(1));
    pending.complete(
      const SystemPowerResult(SystemPowerOutcome.unknown, 'Unknown'),
    );
    await first;
    expect(state(h).locked, isTrue);
  });
  test(
    'external global lock prevents dispatch without consuming review',
    () async {
      final h = PowerHarness();
      addTearDown(h.dispose);
      await h.load();
      final lock = h.container.read(serverOperationLockProvider),
          review = powerReview(h.api.inventory);
      final owner = lock.acquire()!;
      await run(h, review);
      expect(h.api.writes, isEmpty);
      lock.release(owner);
      await run(h, review);
      expect(h.api.writes, hasLength(1));
    },
  );
  for (final guard in [
    'confirmation',
    'endpoint',
    'inventory',
    'session',
    'reason',
    'capability',
    'ha',
    'background',
  ]) {
    test('$guard guard sends zero mutations', () async {
      final h = PowerHarness(
        fake: PowerFake(inventory: powerInventory(ha: guard == 'ha')),
      );
      addTearDown(h.dispose);
      await h.load();
      var review = powerReview(h.api.inventory);
      if (guard == 'endpoint') {
        review = SystemPowerReview(
          request: review.request,
          endpoint: 'wss://other.example/api/current',
          warnings: [],
        );
      }
      if (guard == 'inventory') review = powerReview(powerInventory());
      if (guard == 'session') h.select(h.newSession());
      if (guard == 'reason') {
        review = SystemPowerReview(
          request: powerRequest(h.api.inventory, reason: ''),
          endpoint: powerEndpoint,
          warnings: [],
        );
      }
      if (guard == 'capability') {
        h.api.caps = const SystemPowerCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
          canShutdown: true,
        );
      }
      if (guard == 'background') {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      try {
        await run(
          h,
          review,
          confirmation: guard == 'confirmation' ? '${review.target} ' : null,
        );
        expect(h.api.writes, isEmpty);
      } finally {
        if (guard == 'background') {
          WidgetsBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      }
    });
  }
  for (final typed in [true, false]) {
    test(
      'typed=$typed execution failure is redacted and appropriately fenced',
      () async {
        final h = PowerHarness(
          fake: PowerFake()
            ..onExecute = (_) async {
              if (typed) {
                throw const SystemPowerException(
                  SystemPowerExceptionReason.staleReview,
                );
              }
              throw StateError('PRIVATE-POWER-FIXTURE');
            },
        );
        addTearDown(h.dispose);
        await h.load();
        await run(h, powerReview(h.api.inventory));
        expect(state(h).unknown, !typed);
        expect(
          state(h).result!.message,
          isNot(contains('PRIVATE-POWER-FIXTURE')),
        );
      },
    );
  }
  for (final prior in [
    SystemPowerOutcome.accepted,
    SystemPowerOutcome.unknown,
  ]) {
    test(
      '$prior requires fresh original-endpoint reconnect and explicit inspection acknowledgement',
      () async {
        final h = PowerHarness(
          fake: PowerFake()
            ..onExecute = (_) async =>
                SystemPowerResult(prior, 'Unresolved', jobId: 80),
        );
        addTearDown(h.dispose);
        await h.load();
        await run(h, powerReview(h.api.inventory));
        final lock = h.container.read(serverOperationLockProvider);
        for (final next in [
          null,
          h.session,
          h.newSession(endpoint: 'wss://other.example/api/current'),
        ]) {
          h.select(next);
          expect(state(h).unknown, isTrue);
          expect(controller(h).canAcknowledge, isFalse);
          controller(h).acknowledgeAfterReconnect();
          expect(state(h).locked, isTrue);
          expect(lock.acquire(), isNull);
        }
        h.select(h.newSession());
        expect(controller(h).canAcknowledge, isFalse);
        expect(lock.acquire(), isNull);
        await controller(h).verifyReconnectedServer();
        expect(controller(h).canAcknowledge, isTrue);
        controller(h).acknowledgeAfterReconnect();
        expect(state(h).locked, isFalse);
        expect(lock.acquire(), isNotNull);
        expect(h.api.writes, hasLength(1));
        expect(state(h).result!.message, contains('not marked successful'));
      },
    );
  }
  test(
    'late accepted response after session replacement stays unknown and fenced',
    () async {
      final pending = Completer<SystemPowerResult>();
      final h = PowerHarness(
        fake: PowerFake()..onExecute = (_) => pending.future,
      );
      addTearDown(h.dispose);
      await h.load();
      final future = run(h, powerReview(h.api.inventory));
      h.select(h.newSession());
      pending.complete(
        const SystemPowerResult(
          SystemPowerOutcome.accepted,
          'LATE-ACCEPTANCE',
          jobId: 80,
        ),
      );
      await future;
      expect(state(h).unknown, isTrue);
      expect(state(h).connectionCurrent, isFalse);
      expect(state(h).result!.message, isNot(contains('LATE-ACCEPTANCE')));
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test('dispose ignores late response without follow-up calls', () async {
    final pending = Completer<SystemPowerResult>();
    final h = PowerHarness(
      fake: PowerFake()..onExecute = (_) => pending.future,
    );
    await h.load();
    final future = run(h, powerReview(h.api.inventory));
    h.dispose();
    pending.complete(
      const SystemPowerResult(SystemPowerOutcome.accepted, 'Late', jobId: 80),
    );
    await future;
    expect(h.api.writes, hasLength(1));
    expect(h.api.reads, 1);
  });
  for (final mismatch in ['host', 'endpoint', 'error']) {
    test(
      'explicit reconnect verification $mismatch cannot unlock writes',
      () async {
        final h = PowerHarness(
          fake: PowerFake()
            ..onExecute = (_) async => const SystemPowerResult(
              SystemPowerOutcome.accepted,
              'Queued',
              jobId: 80,
            ),
        );
        addTearDown(h.dispose);
        await h.load();
        await run(h, powerReview(h.api.inventory));
        h.select(h.newSession());
        expect(h.api.reads, 1);
        h.api.onLoad = () async {
          if (mismatch == 'error') throw StateError('PRIVATE-POWER-FIXTURE');
          return powerInventory(
            hostId: mismatch == 'host'
                ? 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
                : powerHost,
            endpoint: mismatch == 'endpoint'
                ? 'wss://other.example/api/current'
                : powerEndpoint,
          );
        };
        await controller(h).verifyReconnectedServer();
        expect(h.api.reads, 2);
        expect(controller(h).canAcknowledge, isFalse);
        expect(
          state(h).verificationMessage,
          isNot(contains('PRIVATE-POWER-FIXTURE')),
        );
        controller(h).acknowledgeAfterReconnect();
        expect(state(h).locked, isTrue);
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        expect(h.api.writes, hasLength(1));
      },
    );
  }
  test(
    'duplicate verification performs one read and no automatic retry',
    () async {
      final h = PowerHarness(
        fake: PowerFake()
          ..onExecute = (_) async =>
              const SystemPowerResult(SystemPowerOutcome.unknown, 'Unverified'),
      );
      addTearDown(h.dispose);
      await h.load();
      await run(h, powerReview(h.api.inventory));
      h.select(h.newSession());
      final pending = Completer<SystemPowerInventory>();
      h.api.onLoad = () => pending.future;
      final first = controller(h).verifyReconnectedServer();
      await controller(h).verifyReconnectedServer();
      expect(state(h).verifying, isTrue);
      expect(h.api.reads, 2);
      pending.complete(h.api.inventory);
      await first;
      expect(controller(h).canAcknowledge, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.api.reads, 2);
    },
  );
  for (final cause in ['session', 'background', 'dispose']) {
    test('late reconnected identity after $cause is not accepted', () async {
      final h = PowerHarness(
        fake: PowerFake()
          ..onExecute = (_) async =>
              const SystemPowerResult(SystemPowerOutcome.unknown, 'Unverified'),
      );
      if (cause != 'dispose') addTearDown(h.dispose);
      await h.load();
      await run(h, powerReview(h.api.inventory));
      h.select(h.newSession());
      final pending = Completer<SystemPowerInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'background') {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      if (cause == 'dispose') h.dispose();
      pending.complete(h.api.inventory);
      await future;
      if (cause != 'dispose') {
        expect(controller(h).canAcknowledge, isFalse);
        expect(state(h).verifying, isFalse);
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      }
      expect(h.api.reads, 2);
      expect(h.api.writes, hasLength(1));
    });
  }
  for (final cause in ['session', 'background']) {
    test('completed host verification expires on $cause', () async {
      final h = PowerHarness(
        fake: PowerFake()
          ..onExecute = (_) async =>
              const SystemPowerResult(SystemPowerOutcome.unknown, 'Unverified'),
      );
      addTearDown(h.dispose);
      await h.load();
      await run(h, powerReview(h.api.inventory));
      h.select(h.newSession());
      await controller(h).verifyReconnectedServer();
      expect(controller(h).canAcknowledge, isTrue);
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'background') {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      expect(controller(h).canAcknowledge, isFalse);
      expect(h.api.reads, 2);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    });
  }
  for (final action in SystemPowerAction.values) {
    test('connector-free preview $action always rejects execution', () async {
      final preview = _Preview(),
          inventory = await _Preview().loadSystemPower();
      final review = await preview.reviewSystemPower(
        powerRequest(inventory, action: action),
      );
      final result = await preview.executeSystemPower(review, review.target);
      expect(result.outcome, SystemPowerOutcome.rejected);
      expect(result.jobId, isNull);
      expect(review.warnings.join(' '), contains('SAMPLE ONLY'));
    });
  }
}

class _Preview with SystemPowerPreviewAdapter {}
