import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nfs_shares/nfs_shares_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'nfs_shares_fakes.dart';

void main() {
  Future<void> execute(NfsHarness h, [NfsShareReview? reviewed]) {
    final r = reviewed ?? nfsReview();
    return h.container
        .read(nfsSharesControllerProvider.notifier)
        .execute(expectedSession: h.session, review: r, confirmation: r.target);
  }

  test(
    'one-shot review holds shared lock through independently verified result',
    () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      final pending = Completer<NfsShareResult>();
      h.api.onExecute = () => pending.future;
      final r = nfsReview();
      final running = execute(h, r);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      await execute(h, r);
      expect(h.api.writes, hasLength(1));
      pending.complete(
        const NfsShareResult(NfsShareOutcome.verified, 'Verified'),
      );
      await running;
      await execute(h, r);
      expect(h.api.writes, hasLength(1));
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );
  test('wrong exact target, endpoint and stale session cannot write', () async {
    final h = NfsHarness();
    addTearDown(h.dispose);
    final c = h.container.read(nfsSharesControllerProvider.notifier);
    final r = nfsReview();
    await c.execute(
      expectedSession: h.session,
      review: r,
      confirmation: '${r.target} ',
    );
    h.select(h.newSession(endpoint: null));
    await c.execute(
      expectedSession: h.active!,
      review: r,
      confirmation: r.target,
    );
    await execute(h, r);
    expect(h.api.writes, isEmpty);
  });
  test('another feature owns the guard until release', () async {
    final h = NfsHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    await execute(h);
    expect(h.api.writes, isEmpty);
    lock.release(owner);
    await execute(h);
    expect(h.api.writes, hasLength(1));
  });
  test(
    'typed preflight rejection releases guard and consumes app review',
    () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(
        const NfsSharesException(NfsSharesExceptionReason.stale),
      );
      final r = nfsReview();
      await execute(h, r);
      await execute(h, r);
      expect(h.api.writes, hasLength(1));
      expect(
        h.container.read(nfsSharesControllerProvider).result!.outcome,
        NfsShareOutcome.rejected,
      );
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );
  test(
    'unexpected errors redact details, retain unknown and never replay',
    () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () =>
          Future.error(StateError('private secret traceback'));
      await execute(h);
      await execute(h);
      final state = h.container.read(nfsSharesControllerProvider);
      expect(state.unknown, true);
      expect(state.result!.message, isNot(contains('secret')));
      expect(h.api.writes, hasLength(1));
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test(
    'late completion after session switch preserves unknown original server',
    () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      final p = Completer<NfsShareResult>();
      h.api.onExecute = () => p.future;
      final running = execute(h);
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      p.complete(
        const NfsShareResult(NfsShareOutcome.verified, 'Private old success'),
      );
      await running;
      final state = h.container.read(nfsSharesControllerProvider);
      expect(state.unknown, true);
      expect(state.connectionCurrent, false);
      expect(state.server, h.session.endpoint);
      expect(state.target, 'NFS #4: /mnt/tank/media');
      expect(state.result!.message, isNot(contains('Private')));
      await execute(h);
      expect(h.api.writes, hasLength(1));
    },
  );
  test('only fresh same-endpoint reconnect acknowledgement clears uncertainty without replay', () async {
    final h = NfsHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () async =>
        const NfsShareResult(NfsShareOutcome.unknown, 'Unverified');
    await execute(h);
    final c = h.container.read(nfsSharesControllerProvider.notifier);
    expect(c.canAcknowledge, false);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    expect(c.canAcknowledge, false);
    h.select(h.newSession());
    expect(c.canAcknowledge, true);
    c.acknowledgeAfterReconnect();
    expect(h.container.read(nfsSharesControllerProvider).locked, false);
    expect(
      h.container.read(nfsSharesControllerProvider).recoveryMessage,
      contains('remains unverified'),
    );
    expect(h.api.writes, hasLength(1));
  });
  test('failed inventory does not retry automatically', () async {
    final h = NfsHarness();
    addTearDown(h.dispose);
    h.api.onLoad = () => Future.error(StateError('remote'));
    await expectLater(
      h.container.read(nfsSharesInventoryProvider.future),
      throwsStateError,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(h.api.reads, 1);
    h.container.invalidate(nfsSharesInventoryProvider);
    await expectLater(
      h.container.read(nfsSharesInventoryProvider.future),
      throwsStateError,
    );
    expect(h.api.reads, 2);
  });
  test(
    'session swap removes previously issued inventory while replacement loads',
    () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      await h.container.read(nfsSharesInventoryProvider.future);
      final p = Completer<NfsShareInventory>();
      final other = NfsFake()..onLoad = () => p.future;
      h.select(h.newSession(fake: other));
      final current = h.container.read(nfsSharesInventoryProvider);
      expect(current.isLoading, true);
      expect(current.asData, isNull);
      p.complete(other.inventory);
      await h.container.read(nfsSharesInventoryProvider.future);
    },
  );
}
