import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/permissions/permissions_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'permissions_fakes.dart';

void main() {
  test('ACL detail waits for inventory and refreshes with newly issued dataset identity', () async {
    final h = PermissionsHarness();
    addTearDown(h.dispose);
    final firstLoad = Completer<List<PermissionDataset>>();
    h.api.onLoad = () => firstLoad.future;
    PermissionDataset issued = PermissionDataset(
      id: permissionDataset.id,
      mountpoint: permissionDataset.mountpoint,
    );
    h.api.onReview = (dataset) async {
      expect(dataset, same(issued));
      return PermissionReview(
        dataset: dataset,
        aclType: PermissionAclType.disabled,
        uid: 3000,
        gid: 3010,
        mode: '750',
        trivial: true,
        acl: [],
      );
    };
    final subscription = h.container.listen(
      permissionsReviewProvider(permissionDataset),
      (_, _) {},
    );
    addTearDown(subscription.close);
    final pending = h.container.read(
      permissionsReviewProvider(permissionDataset).future,
    );
    expect(h.api.reviewReads, 0);
    firstLoad.complete([issued]);
    expect((await pending).dataset, same(issued));
    issued = PermissionDataset(
      id: permissionDataset.id,
      mountpoint: permissionDataset.mountpoint,
    );
    h.api.onLoad = () async => [issued];
    h.container.invalidate(permissionsDatasetsProvider);
    await h.container.pump();
    expect(
      (await h.container.read(
        permissionsReviewProvider(permissionDataset).future,
      )).dataset,
      same(issued),
    );
    expect(h.api.reads, 2);
    expect(h.api.reviewReads, 2);
    expect(h.api.writes, isEmpty);
  });
  Future<void> apply(PermissionsHarness h, [PermissionApplyRequest? request]) =>
      h.container
          .read(permissionsControllerProvider.notifier)
          .apply(
            expectedSession: h.session,
            request: request ?? permissionChange(h.api.review),
            confirmation: permissionDataset.mountpoint,
          );

  test('exact request dispatch once, shares lock, preserves ownership and ordered ACE bits', () async {
    final h = PermissionsHarness();
    addTearDown(h.dispose);
    final done = Completer<PermissionOperationResult>();
    h.api.onApply = () => done.future;
    final request = permissionChange(h.api.review);
    final running = apply(h, request);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    await apply(h, request);
    expect(h.api.writes, [same(request)]);
    expect(request.review.uid, 3000);
    expect(request.review.gid, 3010);
    expect(request.acl![1], same(h.api.review.acl[1]));
    expect(request.acl!.first.flags, h.api.review.acl.first.flags);
    done.complete(
      const PermissionOperationResult(
        outcome: PermissionOperationOutcome.verified,
      ),
    );
    await running;
    await apply(h, request);
    expect(h.api.writes.length, 1);
    expect(
      h.container.read(permissionsControllerProvider).phase,
      PermissionsPhase.verified,
    );
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });
  test('wrong exact target, missing endpoint, stale session and invalid draft never dispatch', () async {
    final h = PermissionsHarness();
    addTearDown(h.dispose);
    final controller = h.container.read(permissionsControllerProvider.notifier);
    final request = permissionChange(h.api.review);
    await controller.apply(
      expectedSession: h.session,
      request: request,
      confirmation: '${permissionDataset.mountpoint} ',
    );
    final withoutEndpoint = h.newSession(endpoint: null);
    h.select(withoutEndpoint);
    await controller.apply(
      expectedSession: withoutEndpoint,
      request: request,
      confirmation: permissionDataset.mountpoint,
    );
    await apply(h, request);
    h.select(h.session);
    await apply(
      h,
      PermissionApplyRequest(review: h.api.review, acl: h.api.review.acl),
    );
    expect(h.api.writes, isEmpty);
  });
  test('another operation lock blocks ACL setter', () async {
    final h = PermissionsHarness();
    addTearDown(h.dispose);
    final lock = h.container.read(serverOperationLockProvider);
    final owner = lock.acquire()!;
    await apply(h);
    expect(h.api.writes, isEmpty);
    lock.release(owner);
    await apply(h);
    expect(h.api.writes.length, 1);
  });
  test('confirmed SDK pre-dispatch rejection releases lock and reports nothing sent', () async {
    final h = PermissionsHarness();
    addTearDown(h.dispose);
    h.api.onApply = () => Future.error(
      const PermissionsException(PermissionsExceptionReason.staleSnapshot),
    );
    await apply(h);
    expect(
      h.container.read(permissionsControllerProvider).phase,
      PermissionsPhase.failed,
    );
    expect(
      h.container.read(permissionsControllerProvider).message,
      contains('Nothing was sent'),
    );
    expect(h.container.read(serverOperationLockProvider).acquire(), isNotNull);
  });
  test(
    'unexpected transport detail is withheld and unknown never replays',
    () async {
      final h = PermissionsHarness();
      addTearDown(h.dispose);
      h.api.onApply = () => Future.error(StateError('remote secret password'));
      await apply(h);
      await apply(h);
      expect(h.api.writes.length, 1);
      final state = h.container.read(permissionsControllerProvider);
      expect(state.unknown, isTrue);
      expect(state.message, isNot(contains('password')));
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  test(
    'read-only manual check uses retained exact receipt without resending',
    () async {
      final h = PermissionsHarness();
      addTearDown(h.dispose);
      const receipt = PermissionOperationResult(
        outcome: PermissionOperationOutcome.pending,
        jobId: 42,
      );
      h.api.onApply = () async => receipt;
      h.api.onCheck = (value) async {
        expect(value, same(receipt));
        return const PermissionOperationResult(
          outcome: PermissionOperationOutcome.verified,
        );
      };
      await apply(h);
      expect(
        h.container.read(permissionsControllerProvider).message,
        contains('paused'),
      );
      await h.container
          .read(permissionsControllerProvider.notifier)
          .checkProgress();
      expect(h.api.checks, 1);
      expect(h.api.writes.length, 1);
      expect(h.container.read(permissionsControllerProvider).jobId, 42);
      expect(
        h.container.read(permissionsControllerProvider).phase,
        PermissionsPhase.verified,
      );
    },
  );
  test(
    'unknown checked result preserves original job ID but disables polling',
    () async {
      final h = PermissionsHarness();
      addTearDown(h.dispose);
      h.api.onApply = () async => const PermissionOperationResult(
        outcome: PermissionOperationOutcome.pending,
        jobId: 91,
      );
      h.api.onCheck = (_) async => const PermissionOperationResult(
        outcome: PermissionOperationOutcome.unknown,
      );
      await apply(h);
      await h.container
          .read(permissionsControllerProvider.notifier)
          .checkProgress();
      expect(h.container.read(permissionsControllerProvider).jobId, 91);
      expect(h.container.read(permissionsControllerProvider).canCheck, isFalse);
      await h.container
          .read(permissionsControllerProvider.notifier)
          .checkProgress();
      expect(h.api.checks, 1);
    },
  );
  test('session switch retains late receipt under original origin and does not poll new connection', () async {
    final h = PermissionsHarness();
    addTearDown(h.dispose);
    final done = Completer<PermissionOperationResult>();
    h.api.onApply = () => done.future;
    final running = apply(h);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    done.complete(
      const PermissionOperationResult(
        outcome: PermissionOperationOutcome.pending,
        jobId: 51,
      ),
    );
    await running;
    final state = h.container.read(permissionsControllerProvider);
    expect(state.unknown, isTrue);
    expect(state.connectionCurrent, isFalse);
    expect(state.server, h.session.endpoint);
    expect(state.jobId, 51);
    await h.container
        .read(permissionsControllerProvider.notifier)
        .checkProgress();
    await apply(h);
    expect(h.api.checks, 0);
    expect(h.api.writes.length, 1);
  });
  test('uncertain state clears only by explicit fresh same-origin reconnect acknowledgement', () async {
    final h = PermissionsHarness();
    addTearDown(h.dispose);
    h.api.onApply = () async => const PermissionOperationResult(
      outcome: PermissionOperationOutcome.unknown,
    );
    await apply(h);
    final controller = h.container.read(permissionsControllerProvider.notifier);
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(permissionsControllerProvider).unknown, isTrue);
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(permissionsControllerProvider).unknown, isTrue);
    h.select(h.newSession());
    controller.acknowledgeAfterReconnect();
    expect(h.container.read(permissionsControllerProvider).locked, isFalse);
    expect(
      h.container.read(permissionsControllerProvider).message,
      contains('remains unverified'),
    );
    expect(h.api.writes.length, 1);
  });
}
