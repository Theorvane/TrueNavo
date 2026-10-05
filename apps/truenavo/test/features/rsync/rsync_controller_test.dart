import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/sample/rsync_preview.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/rsync/rsync_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'rsync_fakes.dart';

RsyncController controller(RsHarness h) =>
    h.container.read(rsyncControllerProvider.notifier);
RsyncState state(RsHarness h) => h.container.read(rsyncControllerProvider);
Future<void> run(RsHarness h, RsyncReview review, {String? confirmation}) =>
    controller(h).execute(
      expectedSession: h.session,
      review: review,
      confirmation: confirmation ?? review.target,
    );

void main() {
  test(
    'successful operation is single-use and releases the shared lock',
    () async {
      final h = RsHarness();
      addTearDown(h.dispose);
      final review = rsReview(h.api.inventory);
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
  test('accepted transfer retains shared lock and does not poll or mark completion', () async {
    final h = RsHarness(
      fake: RsFake()
        ..onExecute = (_) async =>
            RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob()),
    );
    addTearDown(h.dispose);
    await run(h, rsReview(h.api.inventory));
    expect(state(h).pendingJob, isTrue);
    expect(state(h).busy, isFalse);
    expect(state(h).result!.outcome, RsyncOutcome.accepted);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.api.checks, isEmpty);
    expect(h.api.writes, hasLength(1));
    await run(h, rsReview(h.api.inventory, action: RsyncAction.disable));
    expect(h.api.writes, hasLength(1));
  });
  test(
    'explicit check keeps accepted fence and terminal proof releases it',
    () async {
      final h = RsHarness(
        fake: RsFake()
          ..onExecute = (_) async =>
              RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob()),
      );
      addTearDown(h.dispose);
      await run(h, rsReview(h.api.inventory));
      h.api.onCheck = (job) async =>
          RsyncResult(RsyncOutcome.accepted, 'Running', job: job);
      await controller(h).checkJob();
      expect(h.api.checks, hasLength(1));
      expect(state(h).pendingJob, isTrue);
      h.api.onCheck = (_) async =>
          const RsyncResult(RsyncOutcome.succeeded, 'Terminal observed');
      await controller(h).checkJob();
      expect(h.api.checks, hasLength(2));
      expect(state(h).locked, isFalse);
      expect(state(h).job, isNull);
      expect(h.api.writes, hasLength(1));
    },
  );
  test('duplicate explicit checks while pending send one read only', () async {
    final check = Completer<RsyncResult>();
    final h = RsHarness(
      fake: RsFake()
        ..onExecute = (_) async =>
            RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob()),
    );
    h.api.onCheck = (_) => check.future;
    addTearDown(h.dispose);
    await run(h, rsReview(h.api.inventory));
    final pending = controller(h).checkJob();
    await controller(h).checkJob();
    expect(h.api.checks, hasLength(1));
    expect(state(h).busy, isTrue);
    check.complete(
      RsyncResult(RsyncOutcome.accepted, 'Still running', job: rsJob()),
    );
    await pending;
  });
  for (final kind in [
    'missing',
    'task',
    'path',
    'connection',
    'remote',
    'endpoint',
  ]) {
    test('accepted $kind mismatch remains fenced', () async {
      final h = RsHarness();
      addTearDown(h.dispose);
      h.api.onExecute = (_) async => RsyncResult(
        RsyncOutcome.accepted,
        'Queued',
        job: kind == 'missing'
            ? null
            : rsJob(
                taskId: kind == 'task' ? 12 : 11,
                path: kind == 'path' ? '/mnt/other/media' : '/mnt/tank/media',
                connectionId: kind == 'connection' ? 99 : 21,
                remotePath: kind == 'remote' ? '/srv/other' : '/srv/backup',
                endpoint: kind == 'endpoint'
                    ? 'wss://other.example/api/current'
                    : rsEndpoint,
              ),
      );
      await run(h, rsReview(h.api.inventory));
      expect(state(h).unknown, isTrue);
      expect(controller(h).canCheck, isFalse);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    });
  }
  test(
    'check identity mismatch is unknown and not automatically checked again',
    () async {
      final h = RsHarness(
        fake: RsFake()
          ..onExecute = (_) async =>
              RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob()),
      );
      h.api.onCheck = (_) async =>
          RsyncResult(RsyncOutcome.accepted, 'Wrong job', job: rsJob(id: 99));
      addTearDown(h.dispose);
      await run(h, rsReview(h.api.inventory));
      await controller(h).checkJob();
      await controller(h).checkJob();
      expect(state(h).unknown, isTrue);
      expect(h.api.checks, hasLength(1));
    },
  );
  test('check errors are fixed and keep unknown fence', () async {
    final h = RsHarness(
      fake: RsFake()
        ..onExecute = (_) async =>
            RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob()),
    );
    h.api.onCheck = (_) async => throw StateError('PRIVATE-SYNTHETIC-DETAIL');
    addTearDown(h.dispose);
    await run(h, rsReview(h.api.inventory));
    await controller(h).checkJob();
    expect(state(h).unknown, isTrue);
    expect(
      state(h).result!.message,
      isNot(contains('PRIVATE-SYNTHETIC-DETAIL')),
    );
  });
  test('pending execution duplicate is blocked', () async {
    final pending = Completer<RsyncResult>();
    final h = RsHarness(fake: RsFake()..onExecute = (_) => pending.future);
    addTearDown(h.dispose);
    final review = rsReview(h.api.inventory);
    final running = run(h, review);
    await run(h, review);
    expect(h.api.writes, hasLength(1));
    expect(state(h).busy, isTrue);
    pending.complete(const RsyncResult(RsyncOutcome.unknown, 'Unknown'));
    await running;
    await run(h, rsReview(h.api.inventory));
    expect(h.api.writes, hasLength(1));
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test('external shared lock rejects without consuming review', () async {
    final h = RsHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    final review = rsReview(h.api.inventory);
    await run(h, review);
    expect(h.api.writes, isEmpty);
    lock.release(owner);
    await run(h, review);
    expect(h.api.writes, hasLength(1));
  });
  test('wrong exact confirmation and endpoint send no mutation', () async {
    final h = RsHarness();
    addTearDown(h.dispose);
    final review = rsReview(h.api.inventory);
    await run(h, review, confirmation: '${review.target} ');
    await run(
      h,
      RsyncReview(
        request: review.request,
        endpoint: 'wss://other.example/api/current',
        warnings: [],
      ),
    );
    expect(h.api.writes, isEmpty);
  });
  for (final typed in [true, false]) {
    test('execute typed=$typed error is redacted with correct fence', () async {
      final h = RsHarness(
        fake: RsFake()
          ..onExecute = (_) async {
            if (typed) {
              throw const RsyncException(RsyncExceptionReason.staleReview);
            }
            throw StateError('PRIVATE-SYNTHETIC-DETAIL');
          },
      );
      addTearDown(h.dispose);
      await run(h, rsReview(h.api.inventory));
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
        final result = Completer<RsyncResult>();
        final h = RsHarness();
        addTearDown(h.dispose);
        Future<void> pending;
        if (checking) {
          h.api.onExecute = (_) async =>
              RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob());
          await run(h, rsReview(h.api.inventory));
          h.api.onCheck = (_) => result.future;
          pending = controller(h).checkJob();
        } else {
          h.api.onExecute = (_) => result.future;
          pending = run(h, rsReview(h.api.inventory));
        }
        h.select(h.newSession());
        result.complete(
          const RsyncResult(RsyncOutcome.succeeded, 'LATE RESULT'),
        );
        await pending;
        expect(state(h).unknown, isTrue);
        expect(state(h).connectionCurrent, isFalse);
        expect(state(h).result!.message, isNot(contains('LATE RESULT')));
      },
    );
  }
  test('accepted session change requires explicit fresh same-origin acknowledgement', () async {
    final h = RsHarness(
      fake: RsFake()
        ..onExecute = (_) async =>
            RsyncResult(RsyncOutcome.accepted, 'Queued', job: rsJob()),
    );
    addTearDown(h.dispose);
    await run(h, rsReview(h.api.inventory));
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
    final result = Completer<RsyncResult>();
    final h = RsHarness(fake: RsFake()..onExecute = (_) => result.future);
    final pending = run(h, rsReview(h.api.inventory));
    h.dispose();
    result.complete(const RsyncResult(RsyncOutcome.succeeded, 'Late'));
    await pending;
    expect(h.api.writes, hasLength(1));
  });
  test(
    'preview rejects every configuration/transfer/check without transport',
    () async {
      final preview = _Preview();
      final inventory = await preview.loadRsync();
      for (final action in RsyncAction.values) {
        final task = action == RsyncAction.disable
            ? inventory.tasks[1]
            : inventory.tasks.first;
        final request = RsyncRequest(
          inventory: inventory,
          action: action,
          task: action == RsyncAction.create ? null : task,
          settings: action == RsyncAction.create || action == RsyncAction.update
              ? const RsyncSettings(
                  path: '/mnt/tank/media',
                  user: 'backup',
                  connectionId: 21,
                  remotePath: '/srv/changed',
                  description: 'Changed',
                )
              : null,
        );
        final review = await preview.reviewRsync(request);
        expect(
          (await preview.executeRsync(review, review.target)).outcome,
          RsyncOutcome.rejected,
        );
      }
      expect(
        (await preview.checkRsyncJob(rsJob())).outcome,
        RsyncOutcome.rejected,
      );
    },
  );
}

class _Preview with RsyncPreviewAdapter {}
