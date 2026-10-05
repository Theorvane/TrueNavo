import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/api_keys/api_keys_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'api_keys_fakes.dart';

void main() {
  Future<ApiKeyOneTimeSecret?> execute(
    ApiKeysHarness h, [
    ApiKeyReview? review,
  ]) {
    final issued = review ?? keyReview(h.api.inventory);
    return h.container
        .read(apiKeysControllerProvider.notifier)
        .execute(
          expectedSession: h.session,
          review: issued,
          confirmation: issued.target,
        );
  }

  test(
    'successful secret bypasses provider state and can be consumed once',
    () async {
      final h = ApiKeysHarness();
      addTearDown(h.dispose);
      final secret = ApiKeyOneTimeSecret(syntheticApiKey);
      h.api.onExecute = () async =>
          ApiKeyResult(ApiKeyOutcome.succeeded, 'Confirmed', secret: secret);
      final seen = <ApiKeysState>[];
      final subscription = h.container.listen(
        apiKeysControllerProvider,
        (_, next) => seen.add(next),
      );
      addTearDown(subscription.close);
      final returned = await execute(h);
      expect(returned, same(secret));
      expect(seen.every((s) => s.result?.secret == null), isTrue);
      expect(
        h.container.read(apiKeysControllerProvider).result!.secret,
        isNull,
      );
      expect(returned.toString(), isNot(contains(syntheticApiKey)));
      expect(returned!.take(), syntheticApiKey);
      expect(returned.take(), isNull);
    },
  );

  test('one-shot request holds cross-workspace lock until confirmed', () async {
    final h = ApiKeysHarness();
    addTearDown(h.dispose);
    final pending = Completer<ApiKeyResult>();
    h.api.onExecute = () => pending.future;
    final review = keyReview(h.api.inventory),
        running = execute(h, keyReview(h.api.inventory));
    expect(h.container.read(apiKeysControllerProvider).busy, isTrue);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    await execute(h, review);
    expect(h.api.writes.length, 1);
    final used = h.api.writes.single;
    pending.complete(const ApiKeyResult(ApiKeyOutcome.succeeded, 'Confirmed'));
    await running;
    await execute(h, used);
    expect(h.api.writes.length, 1);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });

  test('wrong confirmation and stale session dispatch nothing', () async {
    final h = ApiKeysHarness();
    addTearDown(h.dispose);
    final c = h.container.read(apiKeysControllerProvider.notifier),
        review = keyReview(h.api.inventory);
    await c.execute(
      expectedSession: h.session,
      review: review,
      confirmation: '${review.target} ',
    );
    h.select(h.newSession());
    await execute(h, review);
    expect(h.api.writes, isEmpty);
  });

  test('another workspace lock rejects without consuming the review', () async {
    final h = ApiKeysHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider),
        review = keyReview(h.api.inventory);
    final owner = lock.acquire()!;
    await execute(h, review);
    expect(h.api.writes, isEmpty);
    lock.release(owner);
    await execute(h, review);
    expect(h.api.writes.length, 1);
  });

  test(
    'typed preflight failure is safe and cannot replay the issued review',
    () async {
      final h = ApiKeysHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(
        const ApiKeysException(ApiKeysExceptionReason.staleReview),
      );
      final review = keyReview(h.api.inventory);
      await execute(h, review);
      await execute(h, review);
      expect(h.api.writes.length, 1);
      expect(
        h.container.read(apiKeysControllerProvider).result!.outcome,
        ApiKeyOutcome.rejected,
      );
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );

  test(
    'untyped errors become unknown without exposing details or replay',
    () async {
      final h = ApiKeysHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () => Future.error(StateError(syntheticApiKey));
      await execute(h);
      await execute(h);
      final state = h.container.read(apiKeysControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.result!.message, isNot(contains(syntheticApiKey)));
      expect(h.api.writes.length, 1);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );

  for (final outcome in [ApiKeyOutcome.rejected, ApiKeyOutcome.unknown]) {
    test('$outcome cannot deliver or retain a secret', () async {
      final h = ApiKeysHarness();
      addTearDown(h.dispose);
      final secret = ApiKeyOneTimeSecret(syntheticApiKey);
      h.api.onExecute = () async =>
          ApiKeyResult(outcome, 'Fixed message', secret: secret);
      expect(await execute(h), isNull);
      expect(secret.take(), isNull);
      expect(
        h.container.read(apiKeysControllerProvider).result!.secret,
        isNull,
      );
    });
  }

  test(
    'inventory invalidation does not unlock or replay an unknown change',
    () async {
      final h = ApiKeysHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async =>
          const ApiKeyResult(ApiKeyOutcome.unknown, 'Unverified');
      await execute(h);
      h.container.invalidate(apiKeysInventoryProvider);
      await h.container.pump();
      expect(h.container.read(apiKeysControllerProvider).unknown, isTrue);
      expect(h.api.writes.length, 1);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );

  for (final restore in [false, true]) {
    test(
      'late secret after disconnect is discarded; restore=$restore cannot revive it',
      () async {
        final h = ApiKeysHarness();
        addTearDown(h.dispose);
        final pending = Completer<ApiKeyResult>(),
            secret = ApiKeyOneTimeSecret(syntheticApiKey);
        h.api.onExecute = () => pending.future;
        final running = execute(h);
        h.select(null);
        if (restore) h.select(h.session);
        pending.complete(
          ApiKeyResult(
            ApiKeyOutcome.succeeded,
            'Late private result',
            secret: secret,
          ),
        );
        expect(await running, isNull);
        expect(secret.take(), isNull);
        final state = h.container.read(apiKeysControllerProvider);
        expect(state.unknown, isTrue);
        expect(state.connectionCurrent, restore);
        expect(state.result!.message, isNot(contains('Late private result')));
        expect(
          h.container.read(apiKeysControllerProvider.notifier).canAcknowledge,
          isFalse,
        );
        if (restore) {
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNull,
          );
        }
      },
    );
  }

  test('disposal before completion discards late secret', () async {
    final h = ApiKeysHarness();
    final pending = Completer<ApiKeyResult>(),
        secret = ApiKeyOneTimeSecret(syntheticApiKey);
    h.api.onExecute = () => pending.future;
    final running = execute(h);
    h.dispose();
    pending.complete(
      ApiKeyResult(ApiKeyOutcome.succeeded, 'Late', secret: secret),
    );
    expect(await running, isNull);
    expect(secret.take(), isNull);
  });

  test(
    'fresh same-origin reconnect requires explicit acknowledgement',
    () async {
      final h = ApiKeysHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async =>
          const ApiKeyResult(ApiKeyOutcome.unknown, 'Unverified');
      await execute(h);
      final c = h.container.read(apiKeysControllerProvider.notifier);
      c.acknowledgeAfterReconnect();
      expect(h.container.read(apiKeysControllerProvider).unknown, isTrue);
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      c.acknowledgeAfterReconnect();
      expect(h.container.read(apiKeysControllerProvider).unknown, isTrue);
      h.select(h.newSession());
      expect(c.canAcknowledge, isTrue);
      c.acknowledgeAfterReconnect();
      expect(h.container.read(apiKeysControllerProvider).locked, isFalse);
      expect(
        h.container.read(apiKeysControllerProvider).recoveryMessage,
        contains('remains unverified'),
      );
      expect(h.api.writes.length, 1);
    },
  );

  test('read failure is not automatically retried', () async {
    final h = ApiKeysHarness();
    addTearDown(h.dispose);
    h.api.onLoad = () => Future.error(StateError(syntheticApiKey));
    await expectLater(
      h.container.read(apiKeysInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
  });
}
