import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/snapshot_schedules/snapshot_schedules_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'snapshot_schedules_fakes.dart';

void main() {
  Future<void> execute(SchedulesHarness h, [SnapshotScheduleReview? reviewed]) {
    final review = reviewed ?? scheduleReview();
    return h.container
        .read(snapshotSchedulesControllerProvider.notifier)
        .execute(
          expectedSession: h.session,
          review: review,
          confirmation: review.target,
        );
  }

  test(
    'review dispatch is one-shot and holds shared lock until verified',
    () async {
      final h = SchedulesHarness();
      addTearDown(h.dispose);
      final pending = Completer<SnapshotScheduleResult>();
      h.api.onExecute = () => pending.future;
      final review = scheduleReview();
      final running = execute(h, review);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      await execute(h, review);
      expect(h.api.writes, [same(review)]);
      pending.complete(
        const SnapshotScheduleResult(
          SnapshotScheduleOutcome.verified,
          'Verified',
        ),
      );
      await running;
      await execute(h, review);
      expect(h.api.writes.length, 1);
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );
  test('exact target, endpoint and current session are mandatory', () async {
    final h = SchedulesHarness();
    addTearDown(h.dispose);
    final controller = h.container.read(
      snapshotSchedulesControllerProvider.notifier,
    );
    final review = scheduleReview();
    await controller.execute(
      expectedSession: h.session,
      review: review,
      confirmation: '${review.target} ',
    );
    h.select(h.newSession(endpoint: null));
    await controller.execute(
      expectedSession: h.active!,
      review: review,
      confirmation: review.target,
    );
    await execute(h, review);
    expect(h.api.writes, isEmpty);
  });
  test('another feature lock blocks schedule dispatch', () async {
    final h = SchedulesHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    await execute(h);
    expect(h.api.writes, isEmpty);
    lock.release(owner);
    await execute(h);
    expect(h.api.writes.length, 1);
  });
  test(
    'known pre-dispatch rejection releases lock and no replay occurs',
    () async {
      final h = SchedulesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(
        const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.stale,
        ),
      );
      final review = scheduleReview();
      await execute(h, review);
      await execute(h, review);
      expect(h.api.writes.length, 1);
      expect(
        h.container.read(snapshotSchedulesControllerProvider).result!.outcome,
        SnapshotScheduleOutcome.rejected,
      );
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );
  test(
    'unknown write retains lock, redacts remote details and blocks replay',
    () async {
      final h = SchedulesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () =>
          Future.error(StateError('private secret traceback'));
      await execute(h);
      await execute(h);
      final state = h.container.read(snapshotSchedulesControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.result!.message, isNot(contains('secret')));
      expect(h.api.writes.length, 1);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test(
    'run accepted stays accepted, never promotes queued work to completion',
    () async {
      final h = SchedulesHarness();
      addTearDown(h.dispose);
      await execute(h, scheduleReview(action: SnapshotScheduleAction.run));
      expect(
        h.container.read(snapshotSchedulesControllerProvider).result!.outcome,
        SnapshotScheduleOutcome.accepted,
      );
      expect(
        h.container.read(snapshotSchedulesControllerProvider).locked,
        isFalse,
      );
      expect(h.api.writes.length, 1);
    },
  );
  test(
    'late result after session switch retains only original uncertain origin',
    () async {
      final h = SchedulesHarness();
      addTearDown(h.dispose);
      final pending = Completer<SnapshotScheduleResult>();
      h.api.onExecute = () => pending.future;
      final running = execute(h);
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      pending.complete(
        const SnapshotScheduleResult(
          SnapshotScheduleOutcome.verified,
          'Original private result',
        ),
      );
      await running;
      final state = h.container.read(snapshotSchedulesControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.connectionCurrent, isFalse);
      expect(state.server, h.session.endpoint);
      expect(state.target, 'Task 4: tank/media');
      expect(state.result!.message, isNot(contains('Original private result')));
    },
  );
  test(
    'only explicit fresh same-origin acknowledgement releases unknown state',
    () async {
      final h = SchedulesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => const SnapshotScheduleResult(
        SnapshotScheduleOutcome.unknown,
        'Unverified',
      );
      await execute(h);
      final controller = h.container.read(
        snapshotSchedulesControllerProvider.notifier,
      );
      controller.acknowledgeAfterReconnect();
      expect(
        h.container.read(snapshotSchedulesControllerProvider).unknown,
        isTrue,
      );
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      controller.acknowledgeAfterReconnect();
      expect(
        h.container.read(snapshotSchedulesControllerProvider).unknown,
        isTrue,
      );
      h.select(h.newSession());
      controller.acknowledgeAfterReconnect();
      expect(
        h.container.read(snapshotSchedulesControllerProvider).locked,
        isFalse,
      );
      expect(
        h.container.read(snapshotSchedulesControllerProvider).recoveryMessage,
        contains('remains unverified'),
      );
    },
  );
  test('new session reusing repository invalidates read inventory; failures do not retry automatically', () async {
    final h = SchedulesHarness();
    addTearDown(h.dispose);
    final subscription = h.container.listen(
      snapshotSchedulesInventoryProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    await h.container.read(snapshotSchedulesInventoryProvider.future);
    expect(h.api.reads, 1);
    h.select(h.newSession());
    await h.container.pump();
    await h.container.read(snapshotSchedulesInventoryProvider.future);
    expect(h.api.reads, 2);
    h.api.onLoad = () => Future.error(StateError('read failed'));
    h.container.invalidate(snapshotSchedulesInventoryProvider);
    await expectLater(
      h.container.read(snapshotSchedulesInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 3);
  });
}
