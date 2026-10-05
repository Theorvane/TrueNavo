import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/dev/ssh_credentials_preview.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/ssh_credentials/ssh_credentials_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'ssh_credentials_fakes.dart';

class _Preview with SshCredentialsPreviewAdapter {
  const _Preview();
}

void main() {
  Future<void> execute(
    SshHarness h, {
    SshCredentialReview? review,
    SshCredentialWriteOnlyInput? input,
  }) {
    final issued = review ?? sshReview(h.api.inventory);
    return h.container
        .read(sshCredentialsControllerProvider.notifier)
        .execute(
          expectedSession: h.session,
          review: issued,
          confirmation: issued.target,
          input: input,
        );
  }

  test('private input is ephemeral and successful state exposes public identity only', () async {
    final h = SshHarness();
    addTearDown(h.dispose);
    final input = sshInput();
    expect(input.validationError, isNull);
    await execute(
      h,
      review: sshReview(
        h.api.inventory,
        action: SshCredentialAction.importKeyPair,
      ),
      input: input,
    );
    expect(input.disposed, isTrue);
    final state = h.container.read(sshCredentialsControllerProvider);
    expect(state.result!.publicKey, sshPublic);
    expect(state.result!.message, isNot(contains(sshSyntheticPrivate)));
    expect(state.target, isNot(contains(sshSyntheticPrivate)));
  });
  test('unknown response holds shared lock and rejects automatic or explicit replay', () async {
    final h = SshHarness();
    addTearDown(h.dispose);
    h.api.onExecute = () async =>
        const SshCredentialResult(SshCredentialOutcome.unknown, 'Unverified');
    await execute(h);
    await execute(h);
    h.container.invalidate(sshCredentialsInventoryProvider);
    await h.container.pump();
    expect(h.api.writes.length, 1);
    expect(h.container.read(sshCredentialsControllerProvider).unknown, isTrue);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
  test(
    'one-shot review and global lock remain held until operation finishes',
    () async {
      final h = SshHarness();
      addTearDown(h.dispose);
      final pending = Completer<SshCredentialResult>();
      h.api.onExecute = () => pending.future;
      final review = sshReview(h.api.inventory), running = execute(h);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      await execute(h, review: review);
      expect(h.api.writes.length, 1);
      final used = h.api.writes.single;
      pending.complete(
        const SshCredentialResult(SshCredentialOutcome.succeeded, 'Confirmed'),
      );
      await running;
      await execute(h, review: used);
      expect(h.api.writes.length, 1);
      expect(
        h.container.read(serverOperationLockProvider).acquire(),
        isNotNull,
      );
    },
  );
  test(
    'shared lock rejects without consuming review but discards private input',
    () async {
      final h = SshHarness();
      addTearDown(h.dispose);
      final lock = h.container.read(serverOperationLockProvider),
          input = sshInput(),
          review = sshReview(h.api.inventory);
      final owner = lock.acquire()!;
      await execute(h, review: review, input: input);
      expect(input.disposed, isTrue);
      expect(h.api.writes, isEmpty);
      lock.release(owner);
      await execute(h, review: review);
      expect(h.api.writes.length, 1);
    },
  );
  test('wrong target or endpoint discards input and sends nothing', () async {
    final h = SshHarness();
    addTearDown(h.dispose);
    final input = sshInput(), review = sshReview(h.api.inventory);
    await h.container
        .read(sshCredentialsControllerProvider.notifier)
        .execute(
          expectedSession: h.session,
          review: review,
          confirmation: '${review.target} ',
          input: input,
        );
    expect(input.disposed, isTrue);
    expect(h.api.writes, isEmpty);
    final other = SshCredentialReview(
      request: review.request,
      endpoint: 'wss://other.example/api/current',
      warnings: [],
    );
    await execute(h, review: other);
    expect(h.api.writes, isEmpty);
  });
  for (final typed in [true, false]) {
    test(
      '${typed ? 'typed' : 'untyped'} error cannot expose private data',
      () async {
        final h = SshHarness();
        addTearDown(h.dispose);
        final input = sshInput();
        h.api.onExecute = () => Future.error(
          typed
              ? const SshCredentialsException(
                  SshCredentialsExceptionReason.staleReview,
                )
              : StateError(sshSyntheticPrivate),
        );
        await execute(h, input: input);
        expect(input.disposed, isTrue);
        final state = h.container.read(sshCredentialsControllerProvider);
        expect(state.unknown, !typed);
        expect(state.result!.message, isNot(contains(sshSyntheticPrivate)));
      },
    );
  }
  for (final restore in [false, true]) {
    test(
      'late completion is discarded after disconnect; restore=$restore',
      () async {
        final h = SshHarness();
        addTearDown(h.dispose);
        final pending = Completer<SshCredentialResult>(), input = sshInput();
        h.api.onExecute = () => pending.future;
        final running = execute(h, input: input);
        h.select(null);
        if (restore) h.select(h.session);
        pending.complete(
          const SshCredentialResult(
            SshCredentialOutcome.succeeded,
            'Late private context',
            publicKey: sshPublic,
          ),
        );
        await running;
        final state = h.container.read(sshCredentialsControllerProvider);
        expect(input.disposed, isTrue);
        expect(state.unknown, isTrue);
        expect(state.connectionCurrent, restore);
        expect(state.result!.publicKey, isNull);
        expect(state.result!.message, isNot(contains('Late private context')));
        expect(
          h.container
              .read(sshCredentialsControllerProvider.notifier)
              .canAcknowledge,
          isFalse,
        );
      },
    );
  }
  test(
    'only fresh same-server explicit acknowledgement clears unknown',
    () async {
      final h = SshHarness();
      addTearDown(h.dispose);
      h.api.onExecute = () async =>
          const SshCredentialResult(SshCredentialOutcome.unknown, 'Unverified');
      await execute(h);
      final c = h.container.read(sshCredentialsControllerProvider.notifier);
      c.acknowledgeAfterReconnect();
      expect(
        h.container.read(sshCredentialsControllerProvider).unknown,
        isTrue,
      );
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      c.acknowledgeAfterReconnect();
      expect(
        h.container.read(sshCredentialsControllerProvider).unknown,
        isTrue,
      );
      h.select(h.newSession());
      c.acknowledgeAfterReconnect();
      expect(
        h.container.read(sshCredentialsControllerProvider).locked,
        isFalse,
      );
      expect(h.api.writes.length, 1);
    },
  );
  test('controller disposal drops late result and clears input', () async {
    final h = SshHarness();
    final pending = Completer<SshCredentialResult>(), input = sshInput();
    h.api.onExecute = () => pending.future;
    final running = execute(h, input: input);
    h.dispose();
    pending.complete(
      const SshCredentialResult(SshCredentialOutcome.succeeded, 'Late'),
    );
    await running;
    expect(input.disposed, isTrue);
  });
  test('failed reads are not automatically retried', () async {
    final h = SshHarness();
    addTearDown(h.dispose);
    h.api.onLoad = () => Future.error(StateError('Synthetic detail'));
    await expectLater(
      h.container.read(sshCredentialsInventoryProvider.future),
      throwsStateError,
    );
    await h.container.pump();
    expect(h.api.reads, 1);
    expect(h.api.writes, isEmpty);
  });
  test('preview generation cannot return private material or execute a server operation', () async {
    const preview = _Preview();
    final inventory = await preview.loadSshCredentials();
    expect(inventory.keyPairs.length, 2);
    for (final action in [
      SshCredentialAction.generateKeyPair,
      SshCredentialAction.importKeyPair,
    ]) {
      final request = SshCredentialRequest(
        inventory: inventory,
        action: action,
        name: 'Sample identity',
      );
      final review = await preview.reviewSshCredential(request),
          input = action == SshCredentialAction.importKeyPair
              ? sshInput()
              : null;
      final result = await preview.executeSshCredential(
        review,
        review.target,
        input: input,
      );
      expect(result.outcome, SshCredentialOutcome.rejected);
      expect(result.publicKey, isNull);
      if (input != null) expect(input.disposed, isTrue);
    }
  });
}
