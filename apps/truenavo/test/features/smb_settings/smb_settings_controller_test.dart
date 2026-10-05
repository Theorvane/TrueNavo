import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/smb_settings/smb_settings_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'smb_settings_fakes.dart';

SmbSettingsController controller(SmbHarness h) =>
    h.container.read(smbSettingsControllerProvider.notifier);
SmbSettingsState state(SmbHarness h) =>
    h.container.read(smbSettingsControllerProvider);
Future<SmbSettingsReview> review(
  SmbHarness h, {
  bool rename = false,
  bool encryption = false,
  bool multichannel = false,
}) async => (await controller(h).review(
  expectedSession: h.session,
  request: smbRequest(
    h.api.inventory,
    rename: rename,
    encryption: encryption,
    multichannel: multichannel,
  ),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  SmbHarness h,
  SmbSettingsReview r, {
  String? omit,
  String? target,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: r,
  confirmation: target ?? r.target,
  configurationImpactAccepted: omit != 'impact',
  identityImpactAccepted: omit != 'identity',
  compatibilityImpactAccepted: omit != 'compatibility',
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

void locked(SmbHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void unlocked(SmbHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in ['configure', 'rename', 'encryption', 'multichannel']) {
    test('$mode reviewed one-use config only', () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(
        h,
        rename: mode == 'rename',
        encryption: mode == 'encryption',
        multichannel: mode == 'multichannel',
      );
      expect(h.api.executes, isEmpty);
      await execute(h, r);
      expect(h.api.mutations, 1);
      expect(state(h).status, SmbSettingsStatus.completed);
      expect(state(h).message, contains('not established'));
      expect(h.api.reads, 1);
      unlocked(h);
      await execute(h, r);
      expect(h.api.executes, hasLength(1));
    });
    for (final omit in [
      'impact',
      if (mode == 'rename') 'identity',
      if (mode == 'encryption' || mode == 'multichannel') 'compatibility',
    ]) {
      test('$mode requires $omit consent', () async {
        final h = SmbHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(
          h,
          rename: mode == 'rename',
          encryption: mode == 'encryption',
          multichannel: mode == 'multichannel',
        );
        await execute(h, r, omit: omit);
        expect(h.api.executes, isEmpty);
        unlocked(h);
      });
    }
    test('$mode wrong target and forged review block', () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(
        h,
        rename: mode == 'rename',
        encryption: mode == 'encryption',
        multichannel: mode == 'multichannel',
      );
      await execute(h, r, target: '${r.target} ');
      await execute(
        h,
        SmbSettingsReview(
          request: r.request,
          endpoint: r.endpoint,
          warnings: const [],
        ),
      );
      expect(h.api.executes, isEmpty);
    });
  }
  for (final value in [
    smbInventory(admin: false),
    smbInventory(ha: true),
    smbInventory(jobs: true),
    smbInventory(healthy: false),
  ]) {
    test('readiness blocks ${value.readinessBlockedReason}', () async {
      final h = SmbHarness(fake: SmbFake(inventory: value));
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: smbRequest(value),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final phase in ['review', 'execute']) {
    for (final reason in ['background', 'route', 'disconnect', 'inventory']) {
      test('$phase late $reason cannot dispatch or unlock', () async {
        final h = SmbHarness();
        addTearDown(h.dispose);
        await h.load();
        var route = true;
        if (phase == 'review') {
          final held = Completer<SmbSettingsReview>();
          h.api.onReview = (_) => held.future;
          final request = smbRequest(h.api.inventory),
              pending = controller(h).review(
                expectedSession: h.session,
                request: smbRequest(h.api.inventory),
                isRouteCurrent: () => route,
              );
          await Future<void>.delayed(Duration.zero);
          switch (reason) {
            case 'background':
              background();
            case 'route':
              route = false;
              controller(h).abandonRoute();
            case 'disconnect':
              h.select(null);
            case 'inventory':
              h.container.invalidate(smbSettingsInventoryProvider);
          }
          held.complete(
            SmbSettingsReview(
              request: request,
              endpoint: h.api.inventory.endpoint,
              warnings: const [],
            ),
          );
          expect(await pending, isNull);
          expect(h.api.executes, isEmpty);
        } else {
          final r = await review(h), held = Completer<void>();
          var callback = true;
          h.api.onExecute = (_, current) async {
            await held.future;
            callback = current();
            return const SmbSettingsResult(
              SmbSettingsOutcome.completed,
              'Late',
            );
          };
          final pending = execute(h, r, route: () => route);
          await Future<void>.delayed(Duration.zero);
          switch (reason) {
            case 'background':
              background();
            case 'route':
              route = false;
              controller(h).abandonRoute();
            case 'disconnect':
              h.select(null);
            case 'inventory':
              h.container.invalidate(smbSettingsInventoryProvider);
          }
          held.complete();
          await pending;
          expect(callback, isFalse);
          expect(state(h).status, SmbSettingsStatus.unknown);
          locked(h);
        }
      });
    }
  }
  for (final outcome in SmbSettingsOutcome.values) {
    test('typed result $outcome correct fence', () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      h.api.onExecute = (_, _) async =>
          SmbSettingsResult(outcome, 'PRIVATE_REMOTE_DETAILS');
      await execute(h, r);
      expect(state(h).message, isNot(contains('PRIVATE_REMOTE_DETAILS')));
      if (outcome == SmbSettingsOutcome.unknown) {
        locked(h);
      } else {
        unlocked(h);
      }
      expect(h.api.reads, 1);
    });
  }
  test('thrown execution unknown; no replay', () async {
    final h = SmbHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    h.api.onExecute = (_, _) async => throw StateError('PRIVATE');
    await execute(h, r);
    expect(state(h).status, SmbSettingsStatus.unknown);
    locked(h);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    expect(state(h).message, isNot(contains('PRIVATE')));
  });
  test('global peer owner prevents SDK invocation', () async {
    final h = SmbHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    final lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire();
    await execute(h, r);
    expect(h.api.executes, isEmpty);
    lock.release(owner!);
  });
  for (final wrong in [
    'same session',
    'other endpoint',
    'other host',
    'unready',
  ]) {
    test('recovery rejects $wrong', () async {
      final h = SmbHarness();
      addTearDown(h.dispose);
      await h.load();
      final r = await review(h);
      h.api.onExecute = (_, _) async =>
          const SmbSettingsResult(SmbSettingsOutcome.unknown, 'Unknown');
      await execute(h, r);
      if (wrong != 'same session') {
        h.select(
          h.newSession(
            endpoint: wrong == 'other endpoint'
                ? 'wss://other.example/api/current'
                : h.session.endpoint,
          ),
        );
      }
      if (wrong == 'other host') {
        h.api.inventory = smbInventory(hostId: 'f' * 64);
      }
      if (wrong == 'unready') h.api.inventory = smbInventory(jobs: true);
      await controller(h).verifyReconnectedServer();
      expect(controller(h).canAcknowledge, isFalse);
      controller(h).acknowledgeAfterReconnect();
      locked(h);
    });
  }
  test('pending old future blocks recovery ACK until settled', () async {
    final h = SmbHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h), held = Completer<SmbSettingsResult>();
    h.api.onExecute = (_, _) => held.future;
    final pending = execute(h, r);
    await Future<void>.delayed(Duration.zero);
    h.select(h.newSession());
    await controller(h).verifyReconnectedServer();
    expect(state(h).hostVerified, isTrue);
    expect(controller(h).canAcknowledge, isFalse);
    locked(h);
    held.complete(
      const SmbSettingsResult(SmbSettingsOutcome.completed, 'late'),
    );
    await pending;
    expect(state(h).status, SmbSettingsStatus.unknown);
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    unlocked(h);
    expect(h.api.executes, hasLength(1));
  });
  test('refresh explicitly reads and consumes earlier review', () async {
    final h = SmbHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h);
    controller(h).refreshConfiguration();
    await h.load();
    expect(h.api.reads, 2);
    await execute(h, r);
    expect(h.api.executes, isEmpty);
  });
}
