import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/system_updates/system_updates_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'system_updates_fakes.dart';

void main() {
  Future<void> execute(UpdatesHarness h, [SystemUpdateReview? reviewed]) {
    final review = reviewed ?? updatesReview(inventory: h.api.inventory);
    return h.container
        .read(systemUpdatesControllerProvider.notifier)
        .execute(
          expectedSession: h.session,
          review: review,
          confirmation: review.target,
        );
  }

  test(
    'page inventory is local-only and errors never automatically retry',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      await h.container.read(systemUpdatesInventoryProvider.future);
      expect(h.api.reads, 1);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
      expect(h.api.polls, isEmpty);
      h.api.onLoad = () => Future.error(StateError('remote secret'));
      h.container.invalidate(systemUpdatesInventoryProvider);
      await expectLater(
        h.container.read(systemUpdatesInventoryProvider.future),
        throwsStateError,
      );
      await h.container.pump();
      expect(h.api.reads, 2);
    },
  );
  test('check result refreshes only the SDK cached catalog', () async {
    final h = UpdatesHarness(
      fake: UpdatesFake(inventory: updatesInventory(checked: false)),
    );
    addTearDown(h.dispose);
    await h.container.read(systemUpdatesInventoryProvider.future);
    final checked = updatesInventory();
    h.api.onExecute = () async => SystemUpdateResult(
      SystemUpdateOutcome.checked,
      'Checked',
      inventory: checked,
    );
    await execute(
      h,
      updatesReview(
        inventory: h.api.inventory,
        action: SystemUpdateAction.check,
      ),
    );
    expect(
      await h.container.read(systemUpdatesInventoryProvider.future),
      same(checked),
    );
    expect(h.api.writes.length, 1);
    expect(h.api.reads, 2);
    expect(h.api.polls, isEmpty);
    expect(h.container.read(systemUpdatesControllerProvider).locked, isFalse);
  });
  test(
    'source check reboot requirement retains the same verification fence',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => const SystemUpdateResult(
        SystemUpdateOutcome.checked,
        'Server requires reboot',
        rebootRequired: true,
      );
      await execute(h, updatesReview(action: SystemUpdateAction.check));
      final controller = h.container.read(
        systemUpdatesControllerProvider.notifier,
      );
      expect(h.container.read(systemUpdatesControllerProvider).locked, isTrue);
      expect(controller.canPoll, isFalse);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      h.select(h.newSession());
      expect(controller.canAcknowledge, isTrue);
      controller.acknowledgeAfterReconnect();
      expect(h.container.read(systemUpdatesControllerProvider).locked, isFalse);
      expect(h.api.writes.length, 1);
      expect(h.api.polls, isEmpty);
    },
  );
  test('exact target and exact authenticated endpoint are mandatory', () async {
    final h = UpdatesHarness();
    addTearDown(h.dispose);
    final controller = h.container.read(
      systemUpdatesControllerProvider.notifier,
    );
    final review = updatesReview();
    await controller.execute(
      expectedSession: h.session,
      review: review,
      confirmation: '${review.target} ',
    );
    await execute(
      h,
      updatesReview(endpoint: 'wss://other.example/api/current'),
    );
    h.select(null);
    await execute(h);
    expect(h.api.writes, isEmpty);
  });
  test(
    'another shared operation blocks dispatch without consuming review',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      final lock = h.container.read(serverOperationLockProvider),
          review = updatesReview();
      final owner = lock.acquire()!;
      await execute(h, review);
      expect(h.api.writes, isEmpty);
      lock.release(owner);
      await execute(h, review);
      expect(h.api.writes.length, 1);
    },
  );
  test(
    'dispatch and review are one-shot, with a persistent pending job lock',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      final completer = Completer<SystemUpdateResult>();
      h.api.onExecute = () => completer.future;
      final review = updatesReview(), running = execute(h, updatesReview());
      await execute(h, review);
      expect(h.api.writes.length, 1);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      completer.complete(
        SystemUpdateResult(
          SystemUpdateOutcome.pending,
          'Queued',
          job: updatesJob(),
          percent: 0,
        ),
      );
      await running;
      await execute(h, review);
      expect(h.api.writes.length, 1);
      expect(h.api.polls, isEmpty);
      expect(
        h.container.read(systemUpdatesControllerProvider.notifier).canPoll,
        isTrue,
      );
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  for (final terminal in [
    SystemUpdateOutcome.succeeded,
    SystemUpdateOutcome.failed,
  ]) {
    test(
      'manual pending job poll releases only verified $terminal terminal',
      () async {
        final h = UpdatesHarness();
        addTearDown(h.dispose);
        h.api.onExecute = () async => SystemUpdateResult(
          SystemUpdateOutcome.pending,
          'Queued',
          job: updatesJob(),
        );
        await execute(h);
        final controller = h.container.read(
          systemUpdatesControllerProvider.notifier,
        );
        await controller.poll();
        expect(h.api.polls.length, 1);
        expect(
          h.container.read(systemUpdatesControllerProvider).pending,
          isTrue,
        );
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        h.api.onPoll = () async =>
            SystemUpdateResult(terminal, 'Verified terminal');
        await controller.poll();
        await controller.poll();
        expect(h.api.polls.length, 2);
        expect(h.api.writes.length, 1);
        expect(
          h.container.read(serverOperationLockProvider).acquire(),
          isNotNull,
        );
      },
    );
  }
  test('poll errors and missing responses retain the same owned manually pollable job', () async {
    final h = UpdatesHarness();
    addTearDown(h.dispose);
    final job = updatesJob();
    h.api.onExecute = () async =>
        SystemUpdateResult(SystemUpdateOutcome.pending, 'Queued', job: job);
    await execute(h);
    final controller = h.container.read(
      systemUpdatesControllerProvider.notifier,
    );
    h.api.onPoll = () => Future.error(StateError('secret'));
    await controller.poll();
    var state = h.container.read(systemUpdatesControllerProvider);
    expect(state.unknown, isTrue);
    expect(state.result!.job, same(job));
    expect(state.result!.message, isNot(contains('secret')));
    expect(controller.canPoll, isTrue);
    h.api.onPoll = () async =>
        const SystemUpdateResult(SystemUpdateOutcome.unknown, 'Missing job');
    await controller.poll();
    state = h.container.read(systemUpdatesControllerProvider);
    expect(state.result!.job, same(job));
    expect(controller.canPoll, isTrue);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test('a concurrent poll cannot submit a second status request', () async {
    final h = UpdatesHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () async => SystemUpdateResult(
      SystemUpdateOutcome.pending,
      'Queued',
      job: updatesJob(),
    );
    await execute(h);
    final completer = Completer<SystemUpdateResult>();
    h.api.onPoll = () => completer.future;
    final controller = h.container.read(
          systemUpdatesControllerProvider.notifier,
        ),
        running = h.container
            .read(systemUpdatesControllerProvider.notifier)
            .poll();
    await controller.poll();
    expect(h.api.polls.length, 1);
    completer.complete(
      const SystemUpdateResult(SystemUpdateOutcome.succeeded, 'Done'),
    );
    await running;
  });
  test('install success requiring reboot retains fence and offers no further job poll', () async {
    final h = UpdatesHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () async => SystemUpdateResult(
      SystemUpdateOutcome.pending,
      'Installing',
      job: updatesJob(action: SystemUpdateAction.install),
    );
    await execute(h, updatesReview(action: SystemUpdateAction.install));
    h.api.onPoll = () async => const SystemUpdateResult(
      SystemUpdateOutcome.succeeded,
      'Installed',
      rebootRequired: true,
    );
    final controller = h.container.read(
      systemUpdatesControllerProvider.notifier,
    );
    await controller.poll();
    expect(h.container.read(systemUpdatesControllerProvider).locked, isTrue);
    expect(controller.canPoll, isFalse);
    expect(controller.canAcknowledge, isFalse);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test(
    'typed preflight rejection releases fence but cannot replay that review',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(
        const SystemUpdatesException(SystemUpdatesExceptionReason.staleReview),
      );
      final review = updatesReview();
      await execute(h, review);
      await execute(h, review);
      expect(h.api.writes.length, 1);
      expect(
        h.container.read(systemUpdatesControllerProvider).result!.outcome,
        SystemUpdateOutcome.rejected,
      );
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );
  test(
    'untyped dispatch uncertainty survives refresh and cannot replay',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(StateError('secret traceback'));
      await execute(h);
      await execute(h);
      h.container.invalidate(systemUpdatesInventoryProvider);
      await h.container.pump();
      final state = h.container.read(systemUpdatesControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.result!.message, isNot(contains('secret')));
      expect(h.api.writes.length, 1);
      expect(h.api.reads, 0);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test('late execution result after disconnect cannot overwrite original uncertainty', () async {
    final h = UpdatesHarness();
    addTearDown(h.dispose);
    final completer = Completer<SystemUpdateResult>();
    h.api.onExecute = () => completer.future;
    final running = execute(h);
    h.select(null);
    completer.complete(
      const SystemUpdateResult(
        SystemUpdateOutcome.succeeded,
        'Private old completion',
      ),
    );
    await running;
    final state = h.container.read(systemUpdatesControllerProvider);
    expect(state.unknown, isTrue);
    expect(state.connectionCurrent, isFalse);
    expect(state.server, updatesEndpoint);
    expect(state.target, 'DOWNLOAD 25.10.2');
    expect(state.result!.message, isNot(contains('Private')));
  });
  test(
    'transient disconnect never revives polling on the same session object',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => SystemUpdateResult(
        SystemUpdateOutcome.pending,
        'Queued',
        job: updatesJob(),
      );
      await execute(h);
      final controller = h.container.read(
        systemUpdatesControllerProvider.notifier,
      );
      h.select(null);
      h.select(h.session);
      await controller.poll();
      expect(h.api.polls, isEmpty);
      expect(controller.canPoll, isFalse);
      expect(controller.canAcknowledge, isFalse);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test('only fresh same-origin explicit acknowledgment clears an uncertain operation', () async {
    final h = UpdatesHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () async =>
        const SystemUpdateResult(SystemUpdateOutcome.unknown, 'Uncertain');
    await execute(h);
    final controller = h.container.read(
      systemUpdatesControllerProvider.notifier,
    );
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(systemUpdatesControllerProvider).locked, isTrue);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(systemUpdatesControllerProvider).locked, isTrue);
    h.select(h.newSession());
    expect(controller.canAcknowledge, isTrue);
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(systemUpdatesControllerProvider).locked, isFalse);
    expect(h.api.writes.length, 1);
    expect(h.api.polls, isEmpty);
  });
  test(
    'late poll result after session change is ignored without replay',
    () async {
      final h = UpdatesHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async => SystemUpdateResult(
        SystemUpdateOutcome.pending,
        'Queued',
        job: updatesJob(),
      );
      await execute(h);
      final completer = Completer<SystemUpdateResult>();
      h.api.onPoll = () => completer.future;
      final running = h.container
          .read(systemUpdatesControllerProvider.notifier)
          .poll();
      h.select(h.newSession());
      completer.complete(
        const SystemUpdateResult(SystemUpdateOutcome.succeeded, 'Late'),
      );
      await running;
      expect(h.container.read(systemUpdatesControllerProvider).unknown, isTrue);
      expect(h.api.writes.length, 1);
      expect(h.api.polls.length, 1);
    },
  );
}
