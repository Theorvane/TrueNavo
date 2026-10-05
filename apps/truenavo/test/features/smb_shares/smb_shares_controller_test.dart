import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/smb_shares/smb_shares_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'smb_shares_fakes.dart';

void main() {
  Future<void> execute(SmbHarness h, [SmbShareReview? reviewed]) {
    final review = reviewed ?? smbReview();
    return h.container
        .read(smbSharesControllerProvider.notifier)
        .execute(
          expectedSession: h.session,
          review: review,
          confirmation: review.target,
        );
  }

  test('dispatch is one-shot and holds shared lock until verified', () async {
    final h = SmbHarness();
    addTearDown(h.dispose);
    final pending = Completer<SmbShareResult>();
    h.api.onExecute = () => pending.future;
    final review = smbReview();
    final running = execute(h, review);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    await execute(h, review);
    expect(h.api.writes, [same(review)]);
    pending.complete(
      const SmbShareResult(SmbShareOutcome.verified, 'Verified'),
    );
    await running;
    await execute(h, review);
    expect(h.api.writes.length, 1);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });
  test('exact target, endpoint and current session are mandatory', () async {
    final h = SmbHarness();
    addTearDown(h.dispose);
    final controller = h.container.read(smbSharesControllerProvider.notifier);
    final review = smbReview();
    await controller.execute(
      expectedSession: h.session,
      review: review,
      confirmation: 'Team files ',
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
  test(
    'another native operation lock blocks dispatch without consuming review',
    () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      final lock = h.container.read(serverOperationLockProvider),
          review = smbReview();
      final owner = lock.acquire()!;
      await execute(h, review);
      expect(h.api.writes, isEmpty);
      lock.release(owner);
      await execute(h, review);
      expect(h.api.writes.length, 1);
    },
  );
  test(
    'typed pre-dispatch rejection releases lock and cannot replay review',
    () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(
        const SmbSharesException(SmbSharesExceptionReason.stale),
      );
      final review = smbReview();
      await execute(h, review);
      await execute(h, review);
      expect(h.api.writes.length, 1);
      expect(
        h.container.read(smbSharesControllerProvider).result!.outcome,
        SmbShareOutcome.rejected,
      );
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );
  test(
    'untyped failure keeps unknown lock, redacts details and blocks all replay',
    () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(StateError('secret traceback'));
      await execute(h);
      await execute(h);
      final state = h.container.read(smbSharesControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.result!.message, isNot(contains('secret')));
      expect(h.api.writes.length, 1);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test(
    'refresh does not clear unknown or trigger automatic write/read replay',
    () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async =>
          const SmbShareResult(SmbShareOutcome.unknown, 'Unverified');
      await execute(h);
      h.container.invalidate(smbSharesInventoryProvider);
      await h.container.pump();
      expect(h.container.read(smbSharesControllerProvider).unknown, isTrue);
      expect(h.api.writes.length, 1);
      expect(h.api.reads, 0);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test(
    'late result after disconnect preserves only original uncertain origin',
    () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      final pending = Completer<SmbShareResult>();
      h.api.onExecute = () => pending.future;
      final running = execute(h);
      h.select(null);
      pending.complete(
        const SmbShareResult(
          SmbShareOutcome.verified,
          'Original private result',
        ),
      );
      await running;
      final state = h.container.read(smbSharesControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.connectionCurrent, isFalse);
      expect(state.server, h.session.endpoint);
      expect(state.target, 'Team files');
      expect(state.result!.message, isNot(contains('Original private result')));
    },
  );
  test(
    'restoring exact original session cannot revive result and reacquires lock',
    () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      final pending = Completer<SmbShareResult>();
      h.api.onExecute = () => pending.future;
      final running = execute(h);
      h.select(null);
      h.select(h.session);
      pending.complete(const SmbShareResult(SmbShareOutcome.verified, 'Late'));
      await running;
      expect(h.container.read(smbSharesControllerProvider).unknown, isTrue);
      expect(
        h.container.read(smbSharesControllerProvider).connectionCurrent,
        isTrue,
      );
      expect(
        h.container.read(smbSharesControllerProvider.notifier).canAcknowledge,
        isFalse,
      );
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test(
    'only explicit fresh same-origin acknowledgement clears unknown lock',
    () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async =>
          const SmbShareResult(SmbShareOutcome.unknown, 'Unverified');
      await execute(h);
      final controller = h.container.read(smbSharesControllerProvider.notifier);
      controller.acknowledgeAfterReconnect();
      expect(h.container.read(smbSharesControllerProvider).unknown, isTrue);
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      controller.acknowledgeAfterReconnect();
      expect(h.container.read(smbSharesControllerProvider).unknown, isTrue);
      h.select(h.newSession());
      controller.acknowledgeAfterReconnect();
      expect(h.container.read(smbSharesControllerProvider).locked, isFalse);
      expect(
        h.container.read(smbSharesControllerProvider).recoveryMessage,
        contains('remains unverified'),
      );
      expect(h.api.writes.length, 1);
    },
  );
  test('new session with same repository reloads inventory and failures do not retry', () async {
    final h = SmbHarness();
    addTearDown(h.dispose);
    final subscription = h.container.listen(
      smbSharesInventoryProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    await h.container.read(smbSharesInventoryProvider.future);
    expect(h.api.reads, 1);
    h.select(h.newSession());
    await h.container.pump();
    await h.container.read(smbSharesInventoryProvider.future);
    expect(h.api.reads, 2);
    h.api.onLoad = () => Future.error(StateError('read failed'));
    h.container.invalidate(smbSharesInventoryProvider);
    await expectLater(
      h.container.read(smbSharesInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 3);
  });
}
