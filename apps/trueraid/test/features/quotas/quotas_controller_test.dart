import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/quotas/quotas_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'quotas_fakes.dart';

const verified = QuotaResult(QuotaOutcome.verified, 'Fixture verified.');
const unknown = QuotaResult(QuotaOutcome.unknown, 'Inspect original fixture.');

void main() {
  test(
    'duplicate execution is excluded while shared operation lock is held',
    () async {
      final h = QuotaHarness();
      addTearDown(h.dispose);
      final review = await h.review();
      final pending = Completer<QuotaResult>();
      h.api.onExecute = () => pending.future;
      final operation = h.controller.execute(
        h.session,
        review,
        review.confirmation,
      );
      await h.controller.execute(h.session, review, review.confirmation);
      expect(h.api.executions, 1);
      expect(h.state.busy, true);
      expect(h.lock.acquire(), isNull);
      pending.complete(verified);
      await operation;
      expect(h.state.locked, false);
      expect(h.lock.acquire(), isNotNull);
    },
  );

  test('other management lock, changed session and incorrect exact confirmation prevent dispatch', () async {
    final h = QuotaHarness();
    addTearDown(h.dispose);
    final review = await h.review();
    final owner = h.lock.acquire()!;
    await h.controller.execute(h.session, review, review.confirmation);
    expect(h.api.executions, 0);
    h.lock.release(owner);
    await h.controller.execute(h.session, review, '${review.confirmation} ');
    expect(h.api.executions, 0);
    h.select(h.newSession());
    await h.controller.execute(h.session, review, review.confirmation);
    expect(h.api.executions, 0);
    final missing = h.newSession(endpoint: null);
    h.select(missing);
    await h.controller.execute(missing, review, review.confirmation);
    expect(h.api.executions, 0);
  });

  test(
    'unknown outcome retains lock and prevents replay or early acknowledgement',
    () async {
      final h = QuotaHarness();
      addTearDown(h.dispose);
      final review = await h.review();
      h.api.onExecute = () async => unknown;
      await h.controller.execute(h.session, review, review.confirmation);
      await h.controller.execute(h.session, review, review.confirmation);
      h.controller.acknowledgeAfterReconnect();
      expect(h.api.executions, 1);
      expect(h.state.unknown, true);
      expect(h.lock.acquire(), isNull);
    },
  );

  test(
    'unexpected execution errors remain unknown and withhold raw details',
    () async {
      final h = QuotaHarness();
      addTearDown(h.dispose);
      final review = await h.review();
      h.api.onExecute = () =>
          Future.error(StateError('private fixture traceback'));
      await h.controller.execute(h.session, review, review.confirmation);
      expect(h.state.unknown, true);
      expect(h.state.result!.message, isNot(contains('private')));
    },
  );

  test('connection switch preserves original dataset identity and server despite late success', () async {
    final h = QuotaHarness();
    addTearDown(h.dispose);
    final review = await h.review();
    final pending = Completer<QuotaResult>();
    h.api.onExecute = () => pending.future;
    final operation = h.controller.execute(
      h.session,
      review,
      review.confirmation,
    );
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    pending.complete(verified);
    await operation;
    expect(h.state.unknown, true);
    expect(h.state.connectionCurrent, false);
    expect(h.state.server, quotaEndpoint);
    expect(h.state.target, 'tank/shared');
    expect(h.state.identity, 'User alice (UID 1000)');
    expect(h.lock.acquire(), isNotNull);
  });

  test('only explicit inspection acknowledgement after reconnect to original endpoint clears warning', () async {
    final h = QuotaHarness();
    addTearDown(h.dispose);
    final review = await h.review();
    h.api.onExecute = () async => unknown;
    await h.controller.execute(h.session, review, review.confirmation);
    for (final session in [
      null,
      h.newSession(endpoint: 'wss://other.example/api/current'),
      h.session,
    ]) {
      h.select(session);
      h.controller.acknowledgeAfterReconnect();
      expect(h.state.unknown, true);
    }
    h.select(h.newSession());
    expect(h.controller.canAcknowledge, true);
    h.controller.acknowledgeAfterReconnect();
    expect(h.state.locked, false);
    expect(h.state.result, isNull);
    expect(h.api.executions, 1);
  });

  test('refresh rebinds inventory to fresh issued dataset handle with same identity', () async {
    final h = QuotaHarness();
    addTearDown(h.dispose);
    final first = await h.inventory();
    h.container.invalidate(quotaDatasetsProvider);
    final after = await h.container.read(
      quotaInventoryProvider(first.dataset).future,
    );
    expect(after.dataset.id, first.dataset.id);
    expect(after.dataset.guid, first.dataset.guid);
    expect(identical(after.dataset, first.dataset), false);
    expect(h.api.issuedDatasets.contains(h.api.loadedDatasets.last), true);
    expect(h.api.datasetReads, 2);
  });

  test(
    'dataset replacement with changed GUID never silently substitutes a target',
    () async {
      final h = QuotaHarness();
      addTearDown(h.dispose);
      final first = await h.inventory();
      h.api.guid = '999';
      h.container.invalidate(quotaDatasetsProvider);
      await expectLater(
        h.container.read(quotaInventoryProvider(first.dataset).future),
        throwsA(
          isA<QuotaException>().having(
            (e) => e.reason,
            'reason',
            QuotaExceptionReason.stale,
          ),
        ),
      );
      expect(h.api.inventoryReads, 1);
    },
  );

  test(
    'new authenticated session reloads datasets even with a reused repository',
    () async {
      final h = QuotaHarness();
      addTearDown(h.dispose);
      final before = await h.inventory();
      h.select(h.newSession());
      final after = await h.container.read(
        quotaInventoryProvider(before.dataset).future,
      );
      expect(identical(before.dataset, after.dataset), false);
      expect(h.api.datasetReads, 2);
    },
  );
}
