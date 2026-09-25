import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/dev/pool_maintenance_preview.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/pool_maintenance/pool_maintenance_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'pool_maintenance_fakes.dart';

PoolMaintenanceController controller(PmHarness h) =>
    h.container.read(poolMaintenanceControllerProvider.notifier);
PoolMaintenanceState state(PmHarness h) =>
    h.container.read(poolMaintenanceControllerProvider);
Future<void> run(
  PmHarness h,
  PoolMaintenanceReview review, {
  String? confirmation,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: confirmation ?? review.target,
);

void main() {
  test(
    'successful operation is single-use and releases the shared lock',
    () async {
      final h = PmHarness();
      addTearDown(h.dispose);
      final review = pmReview(h.api.inventory);
      await run(h, review);
      await run(h, review);
      expect(h.api.writes, hasLength(1));
      expect(state(h).locked, isFalse);
      final lock = h.container.read(serverOperationLockProvider);
      final owner = lock.acquire();
      expect(owner, isNotNull);
      lock.release(owner!);
    },
  );
  test(
    'accepted START retains shared lock and does not poll or mark completion',
    () async {
      final h = PmHarness(
        fake: PmFake()
          ..onExecute = (_) async => PoolMaintenanceResult(
            PoolMaintenanceOutcome.accepted,
            'Queued',
            job: pmJob(),
          ),
      );
      addTearDown(h.dispose);
      await run(h, pmReview(h.api.inventory));
      expect(state(h).pendingJob, isTrue);
      expect(state(h).busy, isFalse);
      expect(state(h).result!.outcome, PoolMaintenanceOutcome.accepted);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(h.api.checks, isEmpty);
      expect(h.api.writes, hasLength(1));
      await run(h, pmReview(h.api.inventory, pool: 1));
      expect(h.api.writes, hasLength(1));
    },
  );
  test('accepted job permits only same-pool STOP with own lock and transfers handle', () async {
    final h = PmHarness();
    addTearDown(h.dispose);
    h.api.onExecute = (r) async => PoolMaintenanceResult(
      PoolMaintenanceOutcome.accepted,
      'Queued',
      job: pmJob(
        id: r.action == PoolMaintenanceAction.startScrub ? 80 : 81,
        action: r.action,
      ),
    );
    await run(h, pmReview(h.api.inventory));
    h.api.inventory = pmInventory(active: true);
    expect(controller(h).canStop(h.api.inventory.pools.first), isTrue);
    expect(controller(h).canStop(h.api.inventory.pools.last), isFalse);
    await run(
      h,
      pmReview(
        h.api.inventory,
        action: PoolMaintenanceAction.stopScrub,
        pool: 1,
      ),
    );
    expect(h.api.writes, hasLength(1));
    await run(
      h,
      pmReview(h.api.inventory, action: PoolMaintenanceAction.stopScrub),
    );
    expect(h.api.writes, hasLength(2));
    expect(state(h).job!.id, 81);
    expect(controller(h).canStop(h.api.inventory.pools.first), isFalse);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test('rejected STOP retains original accepted job and fence', () async {
    final h = PmHarness();
    addTearDown(h.dispose);
    h.api.onExecute = (r) async => r.action == PoolMaintenanceAction.startScrub
        ? PoolMaintenanceResult(
            PoolMaintenanceOutcome.accepted,
            'Queued',
            job: pmJob(),
          )
        : const PoolMaintenanceResult(
            PoolMaintenanceOutcome.rejected,
            'Nothing sent',
          );
    await run(h, pmReview(h.api.inventory));
    h.api.inventory = pmInventory(active: true);
    await run(
      h,
      pmReview(h.api.inventory, action: PoolMaintenanceAction.stopScrub),
    );
    expect(state(h).job!.id, 80);
    expect(state(h).pendingJob, isTrue);
    expect(controller(h).canCheck, isTrue);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test(
    'explicit check keeps accepted fence and terminal proof releases it',
    () async {
      final h = PmHarness(
        fake: PmFake()
          ..onExecute = (_) async => PoolMaintenanceResult(
            PoolMaintenanceOutcome.accepted,
            'Queued',
            job: pmJob(),
          ),
      );
      addTearDown(h.dispose);
      await run(h, pmReview(h.api.inventory));
      h.api.onCheck = (job) async => PoolMaintenanceResult(
        PoolMaintenanceOutcome.accepted,
        'Running',
        job: job,
      );
      await controller(h).checkJob();
      expect(h.api.checks, hasLength(1));
      expect(state(h).pendingJob, isTrue);
      h.api.onCheck = (_) async => const PoolMaintenanceResult(
        PoolMaintenanceOutcome.succeeded,
        'Terminal observed',
      );
      await controller(h).checkJob();
      expect(h.api.checks, hasLength(2));
      expect(state(h).locked, isFalse);
      expect(state(h).job, isNull);
      expect(h.api.writes, hasLength(1));
    },
  );
  test('duplicate explicit checks while pending send one read only', () async {
    final check = Completer<PoolMaintenanceResult>();
    final h = PmHarness(
      fake: PmFake()
        ..onExecute = (_) async => PoolMaintenanceResult(
          PoolMaintenanceOutcome.accepted,
          'Queued',
          job: pmJob(),
        ),
    );
    h.api.onCheck = (_) => check.future;
    addTearDown(h.dispose);
    await run(h, pmReview(h.api.inventory));
    final pending = controller(h).checkJob();
    await controller(h).checkJob();
    expect(h.api.checks, hasLength(1));
    expect(state(h).busy, isTrue);
    check.complete(
      PoolMaintenanceResult(
        PoolMaintenanceOutcome.accepted,
        'Still running',
        job: pmJob(),
      ),
    );
    await pending;
  });
  for (final kind in ['missing', 'wrong-pool', 'wrong-action']) {
    test(
      'accepted $kind job identity becomes unknown and cannot unlock',
      () async {
        final h = PmHarness(
          fake: PmFake()
            ..onExecute = (_) async => PoolMaintenanceResult(
              PoolMaintenanceOutcome.accepted,
              'Queued',
              job: kind == 'missing'
                  ? null
                  : pmJob(
                      poolId: kind == 'wrong-pool' ? 2 : 1,
                      action: kind == 'wrong-action'
                          ? PoolMaintenanceAction.stopScrub
                          : PoolMaintenanceAction.startScrub,
                    ),
            ),
        );
        addTearDown(h.dispose);
        await run(h, pmReview(h.api.inventory));
        expect(state(h).unknown, isTrue);
        expect(controller(h).canCheck, isFalse);
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      },
    );
  }
  test(
    'check identity mismatch is unknown and not automatically checked again',
    () async {
      final h = PmHarness(
        fake: PmFake()
          ..onExecute = (_) async => PoolMaintenanceResult(
            PoolMaintenanceOutcome.accepted,
            'Queued',
            job: pmJob(),
          ),
      );
      h.api.onCheck = (_) async => PoolMaintenanceResult(
        PoolMaintenanceOutcome.accepted,
        'Wrong job',
        job: pmJob(id: 99),
      );
      addTearDown(h.dispose);
      await run(h, pmReview(h.api.inventory));
      await controller(h).checkJob();
      await controller(h).checkJob();
      expect(state(h).unknown, isTrue);
      expect(h.api.checks, hasLength(1));
    },
  );
  test('check errors are fixed and keep unknown fence', () async {
    final h = PmHarness(
      fake: PmFake()
        ..onExecute = (_) async => PoolMaintenanceResult(
          PoolMaintenanceOutcome.accepted,
          'Queued',
          job: pmJob(),
        ),
    );
    h.api.onCheck = (_) async => throw StateError('PRIVATE-SYNTHETIC-DETAIL');
    addTearDown(h.dispose);
    await run(h, pmReview(h.api.inventory));
    await controller(h).checkJob();
    expect(state(h).unknown, isTrue);
    expect(
      state(h).result!.message,
      isNot(contains('PRIVATE-SYNTHETIC-DETAIL')),
    );
  });
  test('pending execution duplicate is blocked', () async {
    final pending = Completer<PoolMaintenanceResult>();
    final h = PmHarness(fake: PmFake()..onExecute = (_) => pending.future);
    addTearDown(h.dispose);
    final review = pmReview(h.api.inventory);
    final running = run(h, review);
    await run(h, review);
    expect(h.api.writes, hasLength(1));
    expect(state(h).busy, isTrue);
    pending.complete(
      const PoolMaintenanceResult(PoolMaintenanceOutcome.unknown, 'Unknown'),
    );
    await running;
    await run(h, pmReview(h.api.inventory));
    expect(h.api.writes, hasLength(1));
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test('external shared lock rejects without consuming review', () async {
    final h = PmHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    final review = pmReview(h.api.inventory);
    await run(h, review);
    expect(h.api.writes, isEmpty);
    lock.release(owner);
    await run(h, review);
    expect(h.api.writes, hasLength(1));
  });
  test('wrong exact confirmation and endpoint send no mutation', () async {
    final h = PmHarness();
    addTearDown(h.dispose);
    final review = pmReview(h.api.inventory);
    await run(h, review, confirmation: '${review.target} ');
    await run(
      h,
      PoolMaintenanceReview(
        request: review.request,
        endpoint: 'wss://other.example/api/current',
        warnings: [],
      ),
    );
    expect(h.api.writes, isEmpty);
  });
  for (final typed in [true, false]) {
    test('execute typed=$typed error is redacted with correct fence', () async {
      final h = PmHarness(
        fake: PmFake()
          ..onExecute = (_) async {
            if (typed) {
              throw const PoolMaintenanceException(
                PoolMaintenanceExceptionReason.staleReview,
              );
            }
            throw StateError('PRIVATE-SYNTHETIC-DETAIL');
          },
      );
      addTearDown(h.dispose);
      await run(h, pmReview(h.api.inventory));
      expect(state(h).unknown, !typed);
      expect(
        state(h).result!.message,
        isNot(contains('PRIVATE-SYNTHETIC-DETAIL')),
      );
    });
  }
  for (final checking in [false, true]) {
    test(
      'late ${checking ? 'job check' : 'execute'} after session change is ignored',
      () async {
        final result = Completer<PoolMaintenanceResult>();
        final h = PmHarness();
        addTearDown(h.dispose);
        Future<void> pending;
        if (checking) {
          h.api.onExecute = (_) async => PoolMaintenanceResult(
            PoolMaintenanceOutcome.accepted,
            'Queued',
            job: pmJob(),
          );
          await run(h, pmReview(h.api.inventory));
          h.api.onCheck = (_) => result.future;
          pending = controller(h).checkJob();
        } else {
          h.api.onExecute = (_) => result.future;
          pending = run(h, pmReview(h.api.inventory));
        }
        h.select(h.newSession());
        result.complete(
          const PoolMaintenanceResult(
            PoolMaintenanceOutcome.succeeded,
            'LATE RESULT',
          ),
        );
        await pending;
        expect(state(h).unknown, isTrue);
        expect(state(h).connectionCurrent, isFalse);
        expect(state(h).result!.message, isNot(contains('LATE RESULT')));
      },
    );
  }
  test('accepted session change requires explicit fresh same-origin acknowledgement', () async {
    final h = PmHarness(
      fake: PmFake()
        ..onExecute = (_) async => PoolMaintenanceResult(
          PoolMaintenanceOutcome.accepted,
          'Queued',
          job: pmJob(),
        ),
    );
    addTearDown(h.dispose);
    await run(h, pmReview(h.api.inventory));
    h.select(null);
    expect(controller(h).canAcknowledge, isFalse);
    h.select(h.session);
    expect(controller(h).canAcknowledge, isFalse);
    expect(state(h).unknown, isTrue);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    expect(controller(h).canAcknowledge, isFalse);
    h.select(h.newSession());
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expect(state(h).locked, isFalse);
    expect(h.api.writes, hasLength(1));
    expect(h.api.checks, isEmpty);
  });
  test('disposed controller ignores late results', () async {
    final result = Completer<PoolMaintenanceResult>();
    final h = PmHarness(fake: PmFake()..onExecute = (_) => result.future);
    final pending = run(h, pmReview(h.api.inventory));
    h.dispose();
    result.complete(
      const PoolMaintenanceResult(PoolMaintenanceOutcome.succeeded, 'Late'),
    );
    await pending;
    expect(h.api.writes, hasLength(1));
  });
  test('preview rejects manual/schedule writes and owned job lookup without transport', () async {
    final preview = _Preview();
    final inventory = await preview.loadPoolMaintenance();
    for (final action in [
      PoolMaintenanceAction.startScrub,
      PoolMaintenanceAction.createSchedule,
    ]) {
      final request = PoolMaintenanceRequest(
        inventory: inventory,
        action: action,
        pool: inventory.pools.last,
        settings: action == PoolMaintenanceAction.createSchedule
            ? const PoolScrubScheduleSettings(enabled: false)
            : null,
      );
      final review = await preview.reviewPoolMaintenance(request);
      expect(
        (await preview.executePoolMaintenance(review, review.target)).outcome,
        PoolMaintenanceOutcome.rejected,
      );
    }
    expect(
      (await preview.checkPoolMaintenanceJob(pmJob())).outcome,
      PoolMaintenanceOutcome.rejected,
    );
  });
}

class _Preview with PoolMaintenancePreviewAdapter {}
