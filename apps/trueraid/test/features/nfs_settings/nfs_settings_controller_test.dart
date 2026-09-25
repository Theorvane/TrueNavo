import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/nfs_settings/nfs_settings_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'nfs_settings_fakes.dart';

NfsSettingsController controller(NfsHarness h) =>
    h.container.read(nfsSettingsControllerProvider.notifier);
NfsSettingsState state(NfsHarness h) =>
    h.container.read(nfsSettingsControllerProvider);
Future<NfsSettingsReview> review(
  NfsHarness h, {
  NfsSettingsRequest? request,
}) async => (await controller(h).review(
  expectedSession: h.session,
  request: request ?? nfsRequest(h.api.inventory),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  NfsHarness h,
  NfsSettingsReview review, {
  String? target,
  String? omit,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: target ?? review.target,
  configurationImpactAccepted: omit != 'impact',
  clientImpactAccepted: omit != 'client',
  bindingExposureAccepted: omit != 'binding',
  isRouteCurrent: route ?? () => true,
);
void background() {
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.inactive,
  );
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.resumed,
  );
}

void expectLocked(NfsHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(NfsHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final change in ['threads', 'protocol', 'binding', 'mountd', 'statd']) {
    test(
      '$change confirms once and requires explicit fresh inventory',
      () async {
        final h = NfsHarness();
        addTearDown(h.dispose);
        await h.load();
        final i = h.api.inventory;
        final request = switch (change) {
          'protocol' => nfsRequest(i, threads: null, protocols: ['NFSV4']),
          'binding' => nfsRequest(i, threads: null, bindings: []),
          'mountd' => nfsRequest(i, threads: null, mountdLog: false),
          'statd' => nfsRequest(i, threads: null, statdLockdLog: true),
          _ => nfsRequest(i),
        };
        final r = await review(h, request: request);
        expect(h.api.executes, isEmpty);
        expect(h.api.reads, 1);
        await execute(h, r);
        expect(state(h).status, NfsSettingsStatus.completed);
        expect(h.api.mutations, 1);
        expect(h.api.reads, 1);
        expectUnlocked(h);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        controller(h).refreshConfiguration();
        await h.load();
        expect(h.api.reads, 2);
      },
    );
  }
  for (final omit in ['impact', 'client', 'binding']) {
    test('missing $omit consent consumes review without SDK execute', () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(
        h,
        request: nfsRequest(h.api.inventory, bindings: []),
      );
      await execute(h, r, omit: omit);
      await execute(h, r);
      expect(h.api.executes, isEmpty);
      expectUnlocked(h);
    });
  }
  for (final entry in <String, NfsSettingsInventory>{
    'HA': nfsInventory(ha: true),
    'admin': nfsInventory(admin: false),
    'jobs': nfsInventory(jobs: true),
    'boot': nfsInventory(healthy: false),
    'nextboot': nfsInventory(nextChanged: true),
    'state': nfsInventory(state: 'BOOTING'),
    'running': nfsInventory(serviceState: 'RUNNING'),
    'directory': nfsInventory(directoryConfigured: true),
    'kerberos': nfsInventory(kerberos: true),
    'rdma': nfsInventory(rdma: true),
  }.entries) {
    test('${entry.key} remains readable but no change', () async {
      final h = NfsHarness(fake: NfsFake(inventory: entry.value));
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: nfsRequest(h.api.inventory),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  test('wrong exact target and forged review never execute', () async {
    final h = NfsHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    await execute(h, r, target: '${r.target} ');
    await execute(h, r);
    await execute(
      h,
      NfsSettingsReview(
        request: r.request,
        endpoint: r.endpoint,
        warnings: const [],
      ),
    );
    expect(h.api.executes, isEmpty);
  });
  test('missing update capability blocks review', () async {
    final h = NfsHarness(
      fake: NfsFake(
        caps: const NfsSettingsCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
        ),
      ),
    );
    addTearDown(h.dispose);
    await h.load();
    expect(
      await controller(h).review(
        expectedSession: h.session,
        request: nfsRequest(h.api.inventory),
        isRouteCurrent: () => true,
      ),
      isNull,
    );
    expect(h.api.reviews, isEmpty);
  });
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      'review late response after $cause cannot issue authorization',
      () async {
        final h = NfsHarness();
        addTearDown(h.dispose);
        await h.load();
        final pending = Completer<NfsSettingsReview>();
        h.api.onReview = (_) => pending.future;
        var route = true;
        final future = controller(h).review(
          expectedSession: h.session,
          request: nfsRequest(h.api.inventory),
          isRouteCurrent: () => route,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: nfsRequest(h.api.inventory),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = nfsInventory();
          h.container.invalidate(nfsSettingsInventoryProvider);
        }
        pending.complete(
          NfsSettingsReview(
            request: h.api.reviews.single,
            endpoint: nfsEndpoint,
            warnings: const [],
          ),
        );
        expect(await future, isNull);
        expect(h.api.executes, isEmpty);
      },
    );
    test('issued review after $cause cannot execute', () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      if (cause == 'session') {
        h.select(h.newSession());
        h.select(h.session);
      }
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'inventory') {
        h.api.inventory = nfsInventory();
        h.container.invalidate(nfsSettingsInventoryProvider);
        await h.load();
      }
      await execute(h, r);
      expect(h.api.executes, isEmpty);
    });
    test(
      'held execute final check after $cause prevents fake dispatch and retains lock',
      () async {
        final h = NfsHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h), pending = Completer<void>();
        var route = true;
        h.api.onExecute = (_, current) async {
          await pending.future;
          if (current()) h.api.mutations++;
          return const NfsSettingsResult(NfsSettingsOutcome.rejected, 'stale');
        };
        final future = execute(h, r, route: () => route);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = nfsInventory();
          h.container.invalidate(nfsSettingsInventoryProvider);
        }
        pending.complete();
        await future;
        expect(h.api.mutations, 0);
        expect(state(h).status, NfsSettingsStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final kind in ['request', 'endpoint', 'error']) {
    test('$kind malformed review hides raw details', () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onReview = (request) async {
        if (kind == 'error') throw StateError('PRIVATE-NFS');
        return NfsSettingsReview(
          request: kind == 'request' ? nfsRequest(h.api.inventory) : request,
          endpoint: kind == 'endpoint'
              ? 'wss://other.example/api/current'
              : nfsEndpoint,
          warnings: const [],
        );
      };
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: nfsRequest(h.api.inventory),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(state(h).message, isNot(contains('PRIVATE-NFS')));
    });
  }
  test('global owner prevents dispatch, duplicate in-flight review is consumed once', () async {
    final h = NfsHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h),
        lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire()!;
    await execute(h, r);
    expect(h.api.executes, isEmpty);
    lock.release(owner);
    controller(h).refreshConfiguration();
    await h.load();
    final next = await review(h);
    final pending = Completer<NfsSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, next);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    pending.complete(
      const NfsSettingsResult(NfsSettingsOutcome.rejected, 'rejected'),
    );
    await future;
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    expectUnlocked(h);
  });
  for (final kind in ['unknown', 'exception', 'typedexception']) {
    test(
      '$kind is terminal with no automatic read/retry and route-persistent lock',
      () async {
        final h = NfsHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h);
        h.api.onExecute = (_, _) async {
          if (kind == 'exception') throw StateError('PRIVATE-NFS');
          if (kind == 'typedexception') {
            throw const NfsSettingsException(NfsSettingsExceptionReason.busy);
          }
          return const NfsSettingsResult(
            NfsSettingsOutcome.unknown,
            'PRIVATE-NFS',
          );
        };
        await execute(h, r);
        expect(state(h).status, NfsSettingsStatus.unknown);
        expect(state(h).message, isNot(contains('PRIVATE-NFS')));
        await execute(h, r);
        await controller(h).verifyReconnectedServer();
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
        controller(h).abandonRoute();
        await Future<void>.delayed(Duration.zero);
        expectLocked(h);
      },
    );
  }
  for (final cause in [
    'differenthost',
    'unready',
    'endpoint',
    'background',
    'route',
    'session',
    'failure',
  ]) {
    test('recovery $cause never releases unverified write fence', () async {
      final h = NfsHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (_, _) async =>
          const NfsSettingsResult(NfsSettingsOutcome.unknown, 'unknown');
      await execute(h, await review(h));
      h.select(
        h.newSession(
          endpoint: cause == 'endpoint'
              ? 'wss://other.example/api/current'
              : nfsEndpoint,
        ),
      );
      if (cause == 'endpoint') {
        expect(controller(h).canVerifyReconnectedServer, isFalse);
        expectLocked(h);
        return;
      }
      final pending = Completer<NfsSettingsInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'failure') {
        pending.completeError(StateError('PRIVATE-NFS'));
      } else {
        pending.complete(
          nfsInventory(
            hostId: cause == 'differenthost' ? 'f' * 64 : nfsHost,
            state: cause == 'unready' ? 'BOOTING' : 'READY',
          ),
        );
      }
      await future;
      expect(state(h).hostVerified, isFalse);
      expect(controller(h).canAcknowledge, isFalse);
      expectLocked(h);
    });
  }
  test('recovery is explicit same-host read plus independent ACK after old invocation settles', () async {
    final h = NfsHarness();
    addTearDown(h.dispose);
    await h.load();
    final pending = Completer<NfsSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, await review(h));
    h.select(h.newSession());
    expect(h.api.reads, 1);
    controller(h).acknowledgeAfterReconnect();
    expectLocked(h);
    await controller(h).verifyReconnectedServer();
    expect(h.api.reads, 2);
    expect(state(h).hostVerified, isTrue);
    expect(controller(h).canAcknowledge, isFalse);
    controller(h).acknowledgeAfterReconnect();
    expectLocked(h);
    pending.complete(
      const NfsSettingsResult(NfsSettingsOutcome.completed, 'late'),
    );
    await future;
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expectUnlocked(h);
    expect(state(h).message, contains('remains unverified'));
    expect(h.api.executes, hasLength(1));
  });
}
