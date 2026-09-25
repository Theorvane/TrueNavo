import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/zvols/zvols_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'zvols_fakes.dart';

void main() {
  Future<void> execute(ZvolsHarness h, [ZvolReview? review]) {
    final target = review ?? zvolReview();
    return h.container
        .read(zvolsControllerProvider.notifier)
        .execute(h.session, target, target.target);
  }

  test(
    'session and inventory providers use only the active fake repository',
    () async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);

      expect(h.container.read(zvolsSessionProvider), same(h.api));
      expect(
        await h.container.read(zvolsInventoryProvider.future),
        same(h.api.inventory),
      );
      expect(h.api.reads, 1);
      expect(h.api.writes, isEmpty);
    },
  );

  test(
    'missing Zvol API rejects inventory and never dispatches a review',
    () async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);
      final container = ProviderContainer(
        overrides: [
          dashboardActiveSessionProvider.overrideWithValue(h.session),
          zvolsSessionProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(zvolsInventoryProvider.future),
        throwsA(
          isA<ZvolException>().having(
            (error) => error.reason,
            'reason',
            ZvolExceptionReason.notAuthenticated,
          ),
        ),
      );
      final review = zvolReview();
      await container
          .read(zvolsControllerProvider.notifier)
          .execute(h.session, review, review.target);

      expect(h.api.writes, isEmpty);
      expect(container.read(zvolsControllerProvider).locked, isFalse);
    },
  );

  test(
    'exact reviewed operation dispatches once and holds shared lock while busy',
    () async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);
      final done = Completer<ZvolResult>();
      h.api.onExecute = () => done.future;
      final review = zvolReview();
      final running = execute(h, review);
      final lock = h.container.read(serverOperationLockProvider);
      final busy = h.container.read(zvolsControllerProvider);

      expect(busy.busy, isTrue);
      expect(busy.locked, isTrue);
      expect(busy.target, review.target);
      expect(busy.server, h.session.endpoint);
      expect(lock.acquire(), isNull);
      await execute(h, review);
      expect(h.api.writes, [same(review)]);
      expect(h.api.confirmations, [review.target]);

      const result = ZvolResult(ZvolOutcome.verified, 'Readback verified.');
      done.complete(result);
      await running;
      final state = h.container.read(zvolsControllerProvider);
      expect(state.result, same(result));
      expect(state.busy, isFalse);
      expect(state.locked, isFalse);
      final owner = lock.acquire();
      expect(owner, isNotNull);
      lock.release(owner!);
      await h.container.pump();
      expect(h.api.writes.length, 1);
    },
  );

  test('confirmation is exact and never trimmed or case folded', () async {
    final h = ZvolsHarness();
    addTearDown(h.dispose);
    final review = zvolReview();
    final controller = h.container.read(zvolsControllerProvider.notifier);

    for (final confirmation in [
      '',
      ' ${review.target}',
      '${review.target} ',
      review.target.toUpperCase(),
      zvolParent.id,
    ]) {
      await controller.execute(h.session, review, confirmation);
    }
    expect(h.api.writes, isEmpty);
    expect(h.api.confirmations, isEmpty);
    expect(h.container.read(zvolsControllerProvider).result, isNull);

    await execute(h, review);
    expect(h.api.writes, [same(review)]);
    expect(h.api.confirmations, [review.target]);
  });

  test(
    'missing endpoint and nonidentical same-origin session never dispatch',
    () async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);
      final controller = h.container.read(zvolsControllerProvider.notifier);
      final review = zvolReview();
      final withoutEndpoint = h.newSession(endpoint: null);
      h.select(withoutEndpoint);
      await controller.execute(withoutEndpoint, review, review.target);

      h.select(h.session);
      final stale = h.newSession();
      await controller.execute(stale, review, review.target);
      h.select(null);
      await execute(h, review);

      expect(h.api.writes, isEmpty);
      expect(h.container.read(zvolsControllerProvider).locked, isFalse);
    },
  );

  test('a stale original session cannot send its review to a newly selected server', () async {
    final h = ZvolsHarness();
    addTearDown(h.dispose);
    h.container.read(zvolsControllerProvider);
    final other = ZvolsFake();
    h.select(
      h.newSession(endpoint: 'wss://other.example/api/current', fake: other),
    );

    await execute(h);

    expect(h.container.read(zvolsSessionProvider), same(other));
    expect(h.api.writes, isEmpty);
    expect(other.writes, isEmpty);
  });

  test(
    'another workflow lock rejects Zvol dispatch without releasing that owner',
    () async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);
      final lock = h.container.read(serverOperationLockProvider);
      final owner = lock.acquire()!;

      await execute(h);

      expect(h.api.writes, isEmpty);
      expect(
        h.container.read(zvolsControllerProvider).result?.outcome,
        ZvolOutcome.rejected,
      );
      expect(lock.acquire(), isNull);
      lock.release(owner);
      await execute(h);
      expect(h.api.writes.length, 1);
      final nextOwner = lock.acquire();
      expect(nextOwner, isNotNull);
      lock.release(nextOwner!);
    },
  );

  test('an explicit SDK rejection releases the shared lock without automatic retry', () async {
    final h = ZvolsHarness();
    addTearDown(h.dispose);
    const rejected = ZvolResult(ZvolOutcome.rejected, 'The review is stale.');
    h.api.onExecute = () async => rejected;

    await execute(h);
    await h.container.pump();

    final state = h.container.read(zvolsControllerProvider);
    expect(state.result, same(rejected));
    expect(state.locked, isFalse);
    expect(h.api.writes.length, 1);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire();
    expect(owner, isNotNull);
    lock.release(owner!);
  });

  for (final reason in ZvolExceptionReason.values) {
    test(
      'known pre-dispatch $reason uses safe message and releases the lock',
      () async {
        final h = ZvolsHarness();
        addTearDown(h.dispose);
        final error = ZvolException(reason);
        h.api.onExecute = () => Future.error(error);

        await execute(h);
        await h.container.pump();

        final state = h.container.read(zvolsControllerProvider);
        expect(state.result?.outcome, ZvolOutcome.rejected);
        expect(state.result?.message, error.userMessage);
        expect(state.locked, isFalse);
        expect(h.api.writes.length, 1);
        final lock = h.container.read(serverOperationLockProvider);
        final owner = lock.acquire();
        expect(owner, isNotNull);
        lock.release(owner!);
      },
    );
  }

  test(
    'unknown outcome retains original target and shared lock and never retries',
    () async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);
      const unknown = ZvolResult(ZvolOutcome.unknown, 'Inspect this storage.');
      h.api.onExecute = () async => unknown;
      final review = zvolReview();

      await execute(h, review);
      await execute(h, review);
      await h.container.pump();
      h.container
          .read(zvolsControllerProvider.notifier)
          .acknowledgeAfterReconnect();

      final state = h.container.read(zvolsControllerProvider);
      expect(state.result, same(unknown));
      expect(state.target, review.target);
      expect(state.server, h.session.endpoint);
      expect(state.connectionCurrent, isTrue);
      expect(state.busy, isFalse);
      expect(state.unknown, isTrue);
      expect(state.locked, isTrue);
      expect(h.api.writes, [same(review)]);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );

  test('unexpected exception withholds remote details and locks instead of replaying', () async {
    final h = ZvolsHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () => Future.error(
      StateError('remote secret password=do-not-display /mnt/private'),
    );

    await execute(h);
    await execute(h);
    await h.container.pump();

    final state = h.container.read(zvolsControllerProvider);
    expect(state.result?.outcome, ZvolOutcome.unknown);
    expect(state.result?.message, isNot(contains('secret')));
    expect(state.result?.message, isNot(contains('password')));
    expect(state.result?.message, isNot(contains('/mnt/private')));
    expect(state.result?.message, contains('original server'));
    expect(h.api.writes.length, 1);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });

  test('unknown acknowledgement requires a fresh same-origin session and explicit action', () async {
    final h = ZvolsHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () async => const ZvolResult(
      ZvolOutcome.unknown,
      'Original storage requires inspection.',
    );
    await execute(h);
    final controller = h.container.read(zvolsControllerProvider.notifier);

    controller.acknowledgeAfterReconnect();
    expect(h.container.read(zvolsControllerProvider).unknown, isTrue);
    h.select(null);
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(zvolsControllerProvider).unknown, isTrue);
    final other = ZvolsFake();
    h.select(
      h.newSession(endpoint: 'wss://other.example/api/current', fake: other),
    );
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(zvolsControllerProvider).unknown, isTrue);
    expect(
      h.container.read(zvolsControllerProvider).server,
      h.session.endpoint,
    );

    h.select(h.session);
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(zvolsControllerProvider).unknown, isTrue);
    h.select(h.newSession());
    expect(h.container.read(zvolsControllerProvider).unknown, isTrue);
    controller.acknowledgeAfterReconnect();

    final state = h.container.read(zvolsControllerProvider);
    expect(state.locked, isFalse);
    expect(state.result, isNull);
    expect(state.target, isNull);
    expect(state.server, isNull);
    expect(h.api.writes.length, 1);
    expect(other.writes, isEmpty);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire();
    expect(owner, isNotNull);
    lock.release(owner!);
  });

  for (final outcome in [ZvolOutcome.verified, ZvolOutcome.rejected]) {
    test(
      'session switch retains origin and ignores a late $outcome result',
      () async {
        final h = ZvolsHarness();
        addTearDown(h.dispose);
        final done = Completer<ZvolResult>();
        h.api.onExecute = () => done.future;
        final review = zvolReview();
        final running = execute(h, review);
        final other = ZvolsFake();
        final selected = h.newSession(
          endpoint: 'wss://other.example/api/current',
          fake: other,
        );
        h.select(selected);
        final switched = h.container.read(zvolsControllerProvider);

        expect(switched.unknown, isTrue);
        expect(switched.connectionCurrent, isFalse);
        expect(switched.busy, isFalse);
        expect(switched.target, review.target);
        expect(switched.server, h.session.endpoint);
        final lock = h.container.read(serverOperationLockProvider);
        final otherOwner = lock.acquire();
        expect(otherOwner, isNotNull);
        lock.release(otherOwner!);

        done.complete(ZvolResult(outcome, 'Late original result.'));
        await running;
        expect(h.container.read(zvolsControllerProvider), same(switched));
        await h.container
            .read(zvolsControllerProvider.notifier)
            .execute(selected, review, review.target);
        expect(h.api.writes, [same(review)]);
        expect(other.writes, isEmpty);
      },
    );
  }

  test('disconnect during dispatch preserves origin and ignores late exception details', () async {
    final h = ZvolsHarness();
    addTearDown(h.dispose);
    final done = Completer<ZvolResult>();
    h.api.onExecute = () => done.future;
    final running = execute(h);
    h.select(null);
    final disconnected = h.container.read(zvolsControllerProvider);

    done.completeError(StateError('late remote credentials'));
    await running;

    expect(h.container.read(zvolsControllerProvider), same(disconnected));
    expect(disconnected.unknown, isTrue);
    expect(disconnected.connectionCurrent, isFalse);
    expect(disconnected.server, h.session.endpoint);
    expect(disconnected.result?.message, isNot(contains('credentials')));
    expect(h.api.writes.length, 1);
  });

  test(
    'switching after a terminal result clears old-origin display state',
    () async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);
      await execute(h);
      expect(h.container.read(zvolsControllerProvider).target, isNotNull);

      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));

      final state = h.container.read(zvolsControllerProvider);
      expect(state.result, isNull);
      expect(state.target, isNull);
      expect(state.server, isNull);
      expect(state.locked, isFalse);
      expect(h.api.writes.length, 1);
    },
  );

  test('disposing a busy controller releases only its lock and ignores late completion', () async {
    final h = ZvolsHarness();
    final done = Completer<ZvolResult>();
    h.api.onExecute = () => done.future;
    final running = execute(h);
    final lock = h.container.read(serverOperationLockProvider);
    expect(lock.acquire(), isNull);

    h.dispose();
    final nextOwner = lock.acquire();
    expect(nextOwner, isNotNull);
    done.complete(const ZvolResult(ZvolOutcome.verified, 'Late completion.'));
    await running;

    expect(lock.acquire(), isNull);
    lock.release(nextOwner!);
    expect(h.api.writes.length, 1);
  });

  test('disposing an uncertain controller releases its local lock without another write', () async {
    final h = ZvolsHarness();
    h.api.onExecute = () async =>
        const ZvolResult(ZvolOutcome.unknown, 'Inspection required.');
    await execute(h);
    final lock = h.container.read(serverOperationLockProvider);
    expect(lock.acquire(), isNull);

    h.dispose();

    final nextOwner = lock.acquire();
    expect(nextOwner, isNotNull);
    lock.release(nextOwner!);
    expect(h.api.writes.length, 1);
  });

  testWidgets(
    'inventory failures wait for explicit refresh without automatic retry',
    (tester) async {
      final h = ZvolsHarness();
      addTearDown(h.dispose);
      h.api.onLoad = () =>
          Future.error(const ZvolException(ZvolExceptionReason.unavailable));
      final subscription = h.container.listen(
        zvolsInventoryProvider,
        (_, _) {},
      );
      addTearDown(subscription.close);
      await expectLater(
        h.container.read(zvolsInventoryProvider.future),
        throwsA(isA<ZvolException>()),
      );

      await tester.pump(const Duration(seconds: 30));
      expect(h.api.reads, 1);
      expect(h.api.writes, isEmpty);

      h.api.onLoad = () async => h.api.inventory;
      h.container.invalidate(zvolsInventoryProvider);
      expect(
        await h.container.read(zvolsInventoryProvider.future),
        same(h.api.inventory),
      );
      expect(h.api.reads, 2);
      expect(h.api.writes, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}
