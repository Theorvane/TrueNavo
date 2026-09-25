import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/replication/replication_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'replication_fakes.dart';

void main() {
  Future<void> execute(ReplicationHarness h, [ReplicationReview? issued]) {
    final review = issued ?? replicationReview(inventory: h.api.inventory);
    return h.container
        .read(replicationControllerProvider.notifier)
        .execute(
          expectedSession: h.session,
          review: review,
          confirmation: review.target,
        );
  }

  test('inventory is read only and never automatically retries', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    await h.container.read(replicationInventoryProvider.future);
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
    expect(h.api.polls, isEmpty);
    h.api.onLoad = () => Future.error(StateError('remote secret'));
    h.container.invalidate(replicationInventoryProvider);
    await expectLater(
      h.container.read(replicationInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 2);
  });
  test('exact confirmation and exact endpoint reject mismatches', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    final controller = h.container.read(replicationControllerProvider.notifier),
        review = replicationReview();
    await controller.execute(
      expectedSession: h.session,
      review: review,
      confirmation: '${review.target} ',
    );
    await execute(
      h,
      replicationReview(endpoint: 'wss://other.example/api/current'),
    );
    h.select(null);
    await execute(h);
    expect(h.api.writes, isEmpty);
  });
  test('shared operation lock blocks without consuming review', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider),
        review = replicationReview();
    final owner = lock.acquire()!;
    await execute(h, review);
    expect(h.api.writes, isEmpty);
    lock.release(owner);
    await execute(h, review);
    expect(h.api.writes.length, 1);
  });
  test('double tap is one dispatch and pending outcome keeps lock', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    final reply = Completer<ReplicationResult>();
    h.api.onExecute = () => reply.future;
    final review = replicationReview(), running = execute(h);
    await execute(h, review);
    expect(h.api.writes.length, 1);
    reply.complete(
      const ReplicationResult(
        ReplicationOutcome.pending,
        'Queued',
        job: replicationJob,
      ),
    );
    await running;
    await execute(h, review);
    expect(h.api.writes.length, 1);
    expect(h.api.polls, isEmpty);
    expect(
      h.container.read(replicationControllerProvider.notifier).canPoll,
      isTrue,
    );
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test('a consumed review cannot be replayed after terminal success', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    final review = replicationReview();
    await execute(h, review);
    await execute(h, review);
    expect(h.api.writes.length, 1);
  });
  for (final terminal in [
    ReplicationOutcome.succeeded,
    ReplicationOutcome.failed,
    ReplicationOutcome.rejected,
  ]) {
    test('verified $terminal releases shared lock', () async {
      final h = ReplicationHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => const ReplicationResult(
        ReplicationOutcome.pending,
        'Queued',
        job: replicationJob,
      );
      await execute(h);
      final controller = h.container.read(
        replicationControllerProvider.notifier,
      );
      await controller.poll();
      expect(h.api.polls.length, 1);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      h.api.onPoll = () async =>
          ReplicationResult(terminal, 'Verified terminal');
      await controller.poll();
      await controller.poll();
      expect(h.api.polls.length, 2);
      expect(h.api.writes.length, 1);
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    });
  }
  test(
    'poll errors and missing job result preserve exact owned handle',
    () async {
      final h = ReplicationHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => const ReplicationResult(
        ReplicationOutcome.pending,
        'Queued',
        job: replicationJob,
      );
      await execute(h);
      final controller = h.container.read(
        replicationControllerProvider.notifier,
      );
      h.api.onPoll = () => Future.error(StateError('remote secret'));
      await controller.poll();
      expect(
        h.container.read(replicationControllerProvider).result!.job,
        same(replicationJob),
      );
      expect(
        h.container.read(replicationControllerProvider).result!.message,
        isNot(contains('secret')),
      );
      h.api.onPoll = () async =>
          const ReplicationResult(ReplicationOutcome.unknown, 'Missing result');
      await controller.poll();
      expect(
        h.container.read(replicationControllerProvider).result!.job,
        same(replicationJob),
      );
      expect(controller.canPoll, isTrue);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test('manual concurrent polls are not duplicated', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () async => const ReplicationResult(
      ReplicationOutcome.pending,
      'Queued',
      job: replicationJob,
    );
    await execute(h);
    final reply = Completer<ReplicationResult>();
    h.api.onPoll = () => reply.future;
    final controller = h.container.read(replicationControllerProvider.notifier),
        running = h.container
            .read(replicationControllerProvider.notifier)
            .poll();
    await controller.poll();
    expect(h.api.polls.length, 1);
    reply.complete(
      const ReplicationResult(ReplicationOutcome.succeeded, 'Done'),
    );
    await running;
  });
  test(
    'untyped execute failure is unknown and holds fence without raw detail',
    () async {
      final h = ReplicationHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(StateError('password secret'));
      await execute(h);
      final state = h.container.read(replicationControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.result!.message, isNot(contains('secret')));
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      expect(
        h.container.read(replicationControllerProvider.notifier).canPoll,
        isFalse,
      );
    },
  );
  test('typed pre-dispatch safety rejection releases fence', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () => Future.error(
      const ReplicationException(ReplicationExceptionReason.staleReview),
    );
    await execute(h);
    expect(h.container.read(replicationControllerProvider).locked, isFalse);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });
  test('connection change fences late result and gates acknowledgment to same endpoint fresh session', () async {
    final h = ReplicationHarness();
    addTearDown(h.dispose);
    final reply = Completer<ReplicationResult>();
    h.api.onExecute = () => reply.future;
    final running = execute(h);
    final controller = h.container.read(replicationControllerProvider.notifier);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    reply.complete(
      const ReplicationResult(ReplicationOutcome.succeeded, 'Late success'),
    );
    await running;
    expect(h.container.read(replicationControllerProvider).unknown, isTrue);
    expect(controller.canAcknowledge, isFalse);
    expect(controller.canPoll, isFalse);
    h.select(h.newSession());
    expect(controller.canAcknowledge, isTrue);
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(replicationControllerProvider).locked, isFalse);
    expect(h.api.writes.length, 1);
    expect(h.api.polls, isEmpty);
  });
  test(
    'returning to identical old session cannot revive job polling',
    () async {
      final h = ReplicationHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => const ReplicationResult(
        ReplicationOutcome.pending,
        'Queued',
        job: replicationJob,
      );
      await execute(h);
      h.select(null);
      h.select(h.session);
      final controller = h.container.read(
        replicationControllerProvider.notifier,
      );
      expect(controller.canPoll, isFalse);
      expect(controller.canAcknowledge, isFalse);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test(
    'late poll result after reconnect cannot change unknown state',
    () async {
      final h = ReplicationHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => const ReplicationResult(
        ReplicationOutcome.pending,
        'Queued',
        job: replicationJob,
      );
      await execute(h);
      final reply = Completer<ReplicationResult>();
      h.api.onPoll = () => reply.future;
      final running = h.container
          .read(replicationControllerProvider.notifier)
          .poll();
      h.select(h.newSession());
      reply.complete(
        const ReplicationResult(ReplicationOutcome.succeeded, 'Late'),
      );
      await running;
      expect(h.container.read(replicationControllerProvider).unknown, isTrue);
    },
  );
}
