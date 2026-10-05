import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/network/network_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const _endpoint = 'wss://nas.example/api/current';

void main() {
  test(
    'another session cannot replace an unresolved recovery handle',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.begin();
      final original = h.state.transaction;
      final next = _Network();
      final nextSession = _session(next);
      h.select(nextSession);
      await h.controller.begin(
        expectedSession: nextSession,
        request: next.request,
        serverLabel: _endpoint,
      );
      expect(next.begins, isEmpty);
      expect(h.state.transaction, same(original));
      expect(h.state.unresolved, isTrue);
      expect(h.controller.operationSession, same(h.session));
    },
  );

  test(
    'explicit reconnection verification is read-only and preserves uncertainty',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.begin();
      final next = _Network();
      h.select(_session(next));
      await h.controller.verifyAfterReconnect();
      expect(next.inventoryReads, 1);
      expect(next.keeps, isEmpty);
      expect(next.reverts, isEmpty);
      expect(h.api.keeps, isEmpty);
      expect(h.state.phase, NetworkPhase.reconciled);
      expect(h.state.message, contains('previous outcome remains unverified'));
      expect(h.state.unresolved, isFalse);
    },
  );

  test(
    'foreign pending changes cannot clear the original recovery warning',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.begin();
      final next = _Network()..pendingInventory = true;
      h.select(_session(next));
      await h.controller.verifyAfterReconnect();
      expect(h.state.phase, NetworkPhase.unknown);
      expect(h.state.unresolved, isTrue);
      expect(next.keeps, isEmpty);
      expect(next.reverts, isEmpty);
    },
  );

  test('network review binds the actual authenticated endpoint', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.begin(serverLabel: 'wss://edited-profile.example/api/current');
    expect(h.api.begins, isEmpty);
    expect(h.state.phase, NetworkPhase.rejected);
  });

  test('session replacement invalidates a pending review', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.select(_session(h.api));
    await h.begin();
    expect(h.api.begins, isEmpty);
    expect(h.state.phase, NetworkPhase.rejected);
  });

  test('testing holds the shared operation lock until verified keep', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.begin();
    expect(h.state.phase, NetworkPhase.testing);
    expect(h.state.canKeep, isTrue);
    expect(h.lock.acquire(), isNull);
    expect(h.api.keeps, isEmpty);
    await h.controller.keep();
    expect(h.api.keeps, [h.api.transaction]);
    expect(h.state.phase, NetworkPhase.kept);
    final owner = h.lock.acquire();
    expect(owner, isNotNull);
    h.lock.release(owner!);
  });

  test('another server operation prevents network staging', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final owner = h.lock.acquire()!;
    await h.begin();
    expect(h.api.begins, isEmpty);
    expect(h.state.phase, NetworkPhase.rejected);
    h.lock.release(owner);
  });

  test('duplicate begin while a test is pending is ignored', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.begin();
    await h.begin();
    expect(h.api.begins, hasLength(1));
  });

  test('duplicate explicit keep does not send twice', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final pending = Completer<NetworkChangeResult>();
    h.api.onKeep = (_) => pending.future;
    await h.begin();
    final first = h.controller.keep();
    await h.controller.keep();
    expect(h.api.keeps, hasLength(1));
    pending.complete(
      NetworkChangeResult(
        phase: NetworkChangePhase.kept,
        transaction: h.api.transaction,
      ),
    );
    await first;
  });

  test(
    'local expiry disables keep without inventing rollback success',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.begin();
      h.elapsed = const Duration(seconds: 61);
      await h.controller.keep();
      expect(h.api.keeps, isEmpty);
      expect(h.api.reverts, isEmpty);
      expect(h.state.phase, NetworkPhase.unknown);
      expect(h.state.secondsRemaining, 0);
      expect(h.lock.acquire(), isNull);
      expect(h.state.message, contains('does not prove rollback'));
      h.api.onCheck = (tx) async => NetworkChangeResult(
        phase: NetworkChangePhase.reverted,
        transaction: tx,
      );
      await h.controller.refreshStatus();
      expect(h.state.phase, NetworkPhase.reverted);
    },
  );

  test(
    'unknown staged edit has no timer or keep but permits guarded revert',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.initialPhase = NetworkChangePhase.unknown;
      await h.begin();
      expect(h.state.secondsRemaining, isNull);
      expect(h.state.canKeep, isFalse);
      expect(h.state.canRevert, isTrue);
      expect(h.api.reverts, isEmpty);
      await h.controller.revert();
      expect(h.api.reverts, [h.api.transaction]);
      expect(h.state.phase, NetworkPhase.reverted);
    },
  );

  test(
    'connection change blocks all finalization on the new session',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.begin();
      h.select(_session(_Network()));
      expect(h.state.connectionCurrent, isFalse);
      expect(h.state.phase, NetworkPhase.unknown);
      await h.controller.keep();
      await h.controller.revert();
      await h.controller.refreshStatus();
      expect(h.api.keeps, isEmpty);
      expect(h.api.reverts, isEmpty);
      expect(h.api.checks, isEmpty);
      expect(h.state.serverLabel, _endpoint);
    },
  );

  test(
    'lost connection while staging retains origin and unknown result',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final pending = Completer<NetworkChangeResult>();
      h.api.onBegin = (_) => pending.future;
      final start = h.begin();
      h.select(null);
      pending.complete(
        NetworkChangeResult(
          phase: NetworkChangePhase.testing,
          transaction: h.api.transaction,
          secondsRemaining: 50,
        ),
      );
      await start;
      expect(h.state.phase, NetworkPhase.unknown);
      expect(h.state.connectionCurrent, isFalse);
      expect(h.state.canKeep, isFalse);
      expect(h.state.serverLabel, _endpoint);
    },
  );

  test(
    'status failure is sanitized, retains handle and does not retry mutation',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onCheck = (_) async => throw StateError('private-remote-error');
      await h.begin();
      await h.controller.refreshStatus();
      expect(h.state.phase, NetworkPhase.unknown);
      expect(h.state.transaction, same(h.api.transaction));
      expect(h.state.message, isNot(contains('private-remote-error')));
      expect(h.api.begins, hasLength(1));
      expect(h.api.keeps, isEmpty);
      expect(h.lock.acquire(), isNull);
    },
  );

  test(
    'preflight rejection releases shared lock without claiming a change',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      h.api.onBegin = (_) async => throw const NetworkException(
        NetworkExceptionReason.foreignPendingChanges,
      );
      await h.begin();
      expect(h.state.phase, NetworkPhase.rejected);
      expect(h.state.transaction, isNull);
      final owner = h.lock.acquire();
      expect(owner, isNotNull);
      h.lock.release(owner!);
    },
  );

  testWidgets('timer ticks only inspect status and never auto-keep or revert', (
    tester,
  ) async {
    final h = _Harness();
    await h.begin();
    h.elapsed = const Duration(seconds: 5);
    await tester.pump(const Duration(seconds: 5));
    expect(h.api.checks, hasLength(1));
    expect(h.api.begins, hasLength(1));
    expect(h.api.keeps, isEmpty);
    expect(h.api.reverts, isEmpty);
    expect(h.state.secondsRemaining, 55);
    h.dispose();
  });

  test('disposal never sends rollback or permanent confirmation', () async {
    final h = _Harness();
    await h.begin();
    h.dispose();
    expect(h.api.keeps, isEmpty);
    expect(h.api.reverts, isEmpty);
  });
}

AuthenticatedSession _session(_Network api) => AuthenticatedSession(
  profileId: 'nas',
  repository: api,
  availableMethodNames: const {},
  version: '25.10.1',
  endpoint: _endpoint,
);

final class _Harness {
  _Harness() {
    session = _session(api);
    active = session;
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => active),
        networkElapsedProvider.overrideWithValue(() => elapsed),
      ],
    );
  }
  final api = _Network();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  Duration elapsed = Duration.zero;
  late final ProviderContainer container;
  NetworkState get state => container.read(networkControllerProvider);
  NetworkController get controller =>
      container.read(networkControllerProvider.notifier);
  ServerOperationLock get lock => container.read(serverOperationLockProvider);
  Future<void> begin({String serverLabel = _endpoint}) => controller.begin(
    expectedSession: session,
    request: api.request,
    serverLabel: serverLabel,
  );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}

final class _Network implements SessionRepository, AuthenticatedNetworkSession {
  final original = NetworkInterfaceSnapshot(
    id: 'enp1s0',
    name: 'enp1s0',
    type: 'PHYSICAL',
    description: 'Management',
    dhcp: false,
    ipv6Auto: false,
    mtu: 1500,
    aliases: const [NetworkAddress(address: '192.168.1.10', netmask: 24)],
  );
  late final inventory = NetworkInventory(
    interfaces: [original],
    failoverLicensed: false,
    hasPendingChanges: false,
    checkinWaitingSeconds: null,
  );
  late final request = NetworkChangeRequest(
    inventory: inventory,
    interfaceId: original.id,
    description: 'Storage',
    dhcp: false,
    ipv4Aliases: original.aliases,
    mtu: 1500,
  );
  late final transaction = NetworkTransaction(
    interfaceId: original.id,
    original: original,
    requested: request,
  );
  NetworkChangePhase initialPhase = NetworkChangePhase.testing;
  Future<NetworkChangeResult> Function(NetworkChangeRequest)? onBegin;
  Future<NetworkChangeResult> Function(NetworkTransaction)? onKeep;
  Future<NetworkChangeResult> Function(NetworkTransaction)? onCheck;
  final begins = <NetworkChangeRequest>[];
  final keeps = <NetworkTransaction>[];
  final reverts = <NetworkTransaction>[];
  final checks = <NetworkTransaction>[];
  int inventoryReads = 0;
  bool pendingInventory = false;
  @override
  NetworkCapabilities get networkCapabilities => const NetworkCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
  );
  @override
  Future<NetworkInventory> loadNetworkInventory() async {
    inventoryReads++;
    return pendingInventory
        ? NetworkInventory(
            interfaces: [original],
            failoverLicensed: false,
            hasPendingChanges: true,
            checkinWaitingSeconds: 50,
          )
        : inventory;
  }

  @override
  Future<NetworkChangeResult> beginNetworkTest(
    NetworkChangeRequest request,
  ) async {
    begins.add(request);
    return onBegin != null
        ? onBegin!(request)
        : NetworkChangeResult(
            phase: initialPhase,
            transaction: transaction,
            secondsRemaining: initialPhase == NetworkChangePhase.testing
                ? 60
                : null,
          );
  }

  @override
  Future<NetworkChangeResult> checkNetworkTest(
    NetworkTransaction transaction,
  ) async {
    checks.add(transaction);
    return onCheck != null
        ? onCheck!(transaction)
        : NetworkChangeResult(
            phase: NetworkChangePhase.testing,
            transaction: transaction,
            secondsRemaining: 55,
          );
  }

  @override
  Future<NetworkChangeResult> keepNetworkTest(
    NetworkTransaction transaction,
  ) async {
    keeps.add(transaction);
    return onKeep != null
        ? onKeep!(transaction)
        : NetworkChangeResult(
            phase: NetworkChangePhase.kept,
            transaction: transaction,
          );
  }

  @override
  Future<NetworkChangeResult> revertNetworkTest(
    NetworkTransaction transaction,
  ) async {
    reverts.add(transaction);
    return NetworkChangeResult(
      phase: NetworkChangePhase.reverted,
      transaction: transaction,
    );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => throw UnimplementedError();
}
