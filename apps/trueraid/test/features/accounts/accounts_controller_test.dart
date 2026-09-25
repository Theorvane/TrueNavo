import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/accounts/accounts_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'accounts_fakes.dart';

void main() {
  Future<void> change(AccountsHarness h) => h.container
      .read(accountsControllerProvider.notifier)
      .perform(
        h.session,
        'demo',
        (api) => api.updateAccountUser(
          h.api.inventory.users[1],
          AccountUserUpdate(fullName: 'New name'),
        ),
      );
  test(
    'shares server lock and blocks duplicate commands until verified',
    () async {
      final h = AccountsHarness();
      addTearDown(h.dispose);
      final done = Completer<AccountsOperationResult>();
      h.api.onWrite = () => done.future;
      final pending = change(h);
      final lock = h.container.read(serverOperationLockProvider);
      expect(lock.acquire(), isNull);
      await change(h);
      expect(h.api.writes.length, 1);
      done.complete(
        const AccountsOperationResult(AccountsOperationOutcome.verified),
      );
      await pending;
      expect(h.container.read(accountsControllerProvider).locked, isFalse);
      expect(lock.acquire(), isNotNull);
    },
  );
  test('other feature ownership blocks account dispatch', () async {
    final h = AccountsHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    await change(h);
    expect(h.api.writes, isEmpty);
    expect(
      h.container.read(accountsControllerProvider).message,
      contains('Another server operation'),
    );
    lock.release(owner);
    await change(h);
    expect(h.api.writes.length, 1);
  });
  test('known input rejection releases lock without retrying or invalidating review', () async {
    final h = AccountsHarness();
    addTearDown(h.dispose);
    final subscription = h.container.listen(
      accountsInventoryProvider,
      (_, _) {},
    );
    addTearDown(subscription.close);
    await h.container.read(accountsInventoryProvider.future);
    h.api.onWrite = () => Future.error(
      const AccountsException(AccountsExceptionReason.invalidInput),
    );
    await change(h);
    expect(h.api.reads, 1);
    expect(h.api.writes.length, 1);
    expect(h.container.read(accountsControllerProvider).locked, isFalse);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });
  test('unknown result retains lock and never replays mutation', () async {
    final h = AccountsHarness();
    addTearDown(h.dispose);
    h.api.onWrite = () async =>
        const AccountsOperationResult(AccountsOperationOutcome.unknown);
    await change(h);
    await change(h);
    expect(h.api.writes.length, 1);
    expect(h.container.read(accountsControllerProvider).unknown, isTrue);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    h.container
        .read(accountsControllerProvider.notifier)
        .acknowledgeAfterReconnect();
    expect(h.container.read(accountsControllerProvider).unknown, isTrue);
  });
  test(
    'unexpected errors reveal no remote secret and remain unknown',
    () async {
      final h = AccountsHarness();
      addTearDown(h.dispose);
      h.api.onWrite = () =>
          Future.error(StateError('private password or server traceback'));
      await change(h);
      final state = h.container.read(accountsControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.result!.userMessage, isNot(contains('password')));
    },
  );
  test(
    'connection switch preserves operation origin and ignores late completion',
    () async {
      final h = AccountsHarness();
      addTearDown(h.dispose);
      final done = Completer<AccountsOperationResult>();
      h.api.onWrite = () => done.future;
      final pending = change(h);
      h.select(h.newSession(endpoint: 'https://other.example.test'));
      done.complete(
        const AccountsOperationResult(AccountsOperationOutcome.verified),
      );
      await pending;
      final state = h.container.read(accountsControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.target, 'demo');
      expect(state.server, h.session.endpoint);
      expect(state.connectionCurrent, isFalse);
    },
  );
  test(
    'disconnect cannot acknowledge unknown but real reconnect can',
    () async {
      final h = AccountsHarness();
      addTearDown(h.dispose);
      h.api.onWrite = () async =>
          const AccountsOperationResult(AccountsOperationOutcome.unknown);
      await change(h);
      final controller = h.container.read(accountsControllerProvider.notifier);
      h.select(null);
      controller.acknowledgeAfterReconnect();
      expect(h.container.read(accountsControllerProvider).unknown, isTrue);
      h.select(h.newSession(endpoint: null));
      controller.acknowledgeAfterReconnect();
      expect(h.container.read(accountsControllerProvider).unknown, isTrue);
      h.select(h.newSession());
      controller.acknowledgeAfterReconnect();
      expect(h.container.read(accountsControllerProvider).locked, isFalse);
    },
  );
}
