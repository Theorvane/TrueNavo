import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final networkSessionProvider = Provider<AuthenticatedNetworkSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return switch (repository) {
    final AuthenticatedNetworkSession network => network,
    _ => null,
  };
});

final networkInventoryProvider = FutureProvider<NetworkInventory>((ref) async {
  final session = ref.watch(networkSessionProvider);
  if (session == null) {
    throw const NetworkException(NetworkExceptionReason.notAuthenticated);
  }
  return session.loadNetworkInventory();
});

/// Monotonic time keeps a device-clock adjustment from extending confirmation.
final networkElapsedProvider = Provider<Duration Function()>((ref) {
  final watch = Stopwatch()..start();
  ref.onDispose(watch.stop);
  return () => watch.elapsed;
});

enum NetworkPhase {
  idle,
  starting,
  testing,
  checking,
  keeping,
  reverting,
  kept,
  reverted,
  rejected,
  unknown,
  reconciled,
}

final class NetworkState {
  const NetworkState({
    this.phase = NetworkPhase.idle,
    this.transaction,
    this.request,
    this.serverLabel,
    this.message,
    this.secondsRemaining,
    this.connectionCurrent = false,
  });

  final NetworkPhase phase;
  final NetworkTransaction? transaction;
  final NetworkChangeRequest? request;
  final String? serverLabel;
  final String? message;
  final int? secondsRemaining;
  final bool connectionCurrent;

  bool get busy => const {
    NetworkPhase.starting,
    NetworkPhase.checking,
    NetworkPhase.keeping,
    NetworkPhase.reverting,
  }.contains(phase);

  bool get unresolved =>
      busy ||
      phase == NetworkPhase.testing ||
      (phase == NetworkPhase.unknown && request != null);

  bool get active => connectionCurrent && unresolved;

  bool get canKeep =>
      connectionCurrent &&
      phase == NetworkPhase.testing &&
      (secondsRemaining ?? 0) > 2;

  // An owned staged edit might need explicit revert before any timer was armed.
  // The gateway verifies the entire configuration before dispatching rollback.
  bool get canRevert =>
      connectionCurrent &&
      !busy &&
      transaction != null &&
      (phase == NetworkPhase.testing || phase == NetworkPhase.unknown);

  bool get canRefresh => canRevert;
}

final networkControllerProvider =
    NotifierProvider<NetworkController, NetworkState>(NetworkController.new);

/// Route-independent temporary-change controller. Only explicit user actions
/// can start, keep or revert a test; periodic work is read-only status checking.
class NetworkController extends Notifier<NetworkState> {
  AuthenticatedSession? _operationSession;
  AuthenticatedSession? get operationSession => _operationSession;
  ServerOperationLock? _operationLock;
  Object? _lockOwner;
  Timer? _ticker;
  Duration? _deadline;
  Duration? _startedAt;
  var _generation = 0;
  var _ticks = 0;

  @override
  NetworkState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (_operationSession == null || state.request == null) return;
      final current = identical(next, _operationSession);
      if (current == state.connectionCurrent) return;
      if (!current) {
        _ticker?.cancel();
        _release();
        state = _copy(
          phase: state.active ? NetworkPhase.unknown : state.phase,
          connectionCurrent: false,
          message: state.active
              ? 'The original connection changed. Do not confirm on another '
                    'connection. Verify network state on the original server; '
                    'a rollback timer is not guaranteed if staging was interrupted.'
              : state.message,
        );
      } else if (state.transaction != null &&
          state.phase == NetworkPhase.unknown) {
        _acquire();
        state = _copy(connectionCurrent: true);
        // Selecting the same still-authenticated session does not commit it.
        unawaited(refreshStatus());
      } else {
        state = _copy(connectionCurrent: true);
      }
    });
    ref.onDispose(() {
      _generation++;
      _ticker?.cancel();
      _release();
      // Never call checkin, cancel_rollback or rollback on route/app disposal.
    });
    return const NetworkState();
  }

  Future<void> begin({
    required AuthenticatedSession expectedSession,
    required NetworkChangeRequest request,
    required String serverLabel,
  }) async {
    if (state.unresolved) return;
    if (!identical(ref.read(dashboardActiveSessionProvider), expectedSession) ||
        expectedSession.endpoint == null ||
        expectedSession.endpoint != serverLabel) {
      state = NetworkState(
        phase: NetworkPhase.rejected,
        serverLabel: serverLabel,
        message:
            'The authenticated server changed. Reload and review again. '
            'Nothing was sent.',
      );
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedNetworkSession) {
      state = const NetworkState(
        phase: NetworkPhase.rejected,
        message: 'Reconnect to load the dedicated network adapter.',
      );
      return;
    }
    if (!_acquire()) {
      state = const NetworkState(
        phase: NetworkPhase.rejected,
        message: 'Another server operation is still in progress.',
      );
      return;
    }
    final generation = ++_generation;
    _operationSession = expectedSession;
    _ticker?.cancel();
    _deadline = null;
    _startedAt = _now;
    state = NetworkState(
      phase: NetworkPhase.starting,
      request: request,
      serverLabel: serverLabel,
      connectionCurrent: true,
      message:
          'Rechecking the complete network configuration, then staging '
          'one temporary test. No mutation will be retried.',
    );
    try {
      final result = await (repository as AuthenticatedNetworkSession)
          .beginNetworkTest(request);
      if (!_valid(generation)) return;
      _accept(result);
    } on NetworkException catch (error) {
      if (!_valid(generation)) return;
      state = _copy(phase: NetworkPhase.rejected, message: error.userMessage);
      _release();
    } catch (_) {
      if (!_valid(generation)) return;
      state = _copy(
        phase: NetworkPhase.unknown,
        message:
            'The network change could not be verified. No command was '
            'retried. Check the original server before making more changes.',
      );
      // The SDK owns any ambiguous staged mutation, even without a UI handle.
      if (!state.connectionCurrent) _release();
    }
  }

  Future<void> keep() async {
    _updateCountdown();
    if (!state.canKeep) return;
    await _command(NetworkPhase.keeping, (api, tx) => api.keepNetworkTest(tx));
  }

  Future<void> revert() async {
    if (!state.canRevert) return;
    await _command(
      NetworkPhase.reverting,
      (api, tx) => api.revertNetworkTest(tx),
    );
  }

  Future<void> refreshStatus() async {
    if (!state.canRefresh) return;
    await _command(
      NetworkPhase.checking,
      (api, tx) => api.checkNetworkTest(tx),
    );
  }

  /// Losing the old session never grants ownership of its transaction to a new
  /// one. This explicit read-only acknowledgement clears only the local warning
  /// after the newly authenticated address reports no pending network changes.
  /// It deliberately does not label the old operation kept or rolled back.
  Future<void> verifyAfterReconnect() async {
    if (!state.unresolved || state.busy || state.connectionCurrent) return;
    final session = ref.read(dashboardActiveSessionProvider);
    if (session == null ||
        identical(session, _operationSession) ||
        session.endpoint != state.serverLabel) {
      return;
    }
    final repository = session.repository;
    if (repository is! AuthenticatedNetworkSession || !_acquire()) return;
    final generation = _generation;
    state = _copy(phase: NetworkPhase.checking);
    try {
      final inventory = await (repository as AuthenticatedNetworkSession)
          .loadNetworkInventory();
      if (!_valid(generation)) return;
      final sameConnection = identical(
        ref.read(dashboardActiveSessionProvider),
        session,
      );
      if (sameConnection &&
          !inventory.hasPendingChanges &&
          inventory.checkinWaitingSeconds == null) {
        state = _copy(
          phase: NetworkPhase.reconciled,
          message:
              'The current connection reports no pending network changes. '
              'The previous outcome remains unverified; inspect its configuration '
              'before starting another change. No recovery command was sent.',
        );
        ref.invalidate(networkInventoryProvider);
      } else {
        state = _copy(
          phase: NetworkPhase.unknown,
          message:
              'Pending changes remain or the connection changed again. '
              'Resolve them using the original client or server console.',
        );
      }
    } catch (_) {
      if (!_valid(generation)) return;
      state = _copy(
        phase: NetworkPhase.unknown,
        message:
            'Recovery status could not be verified. The previous outcome '
            'is still unknown. No recovery command was sent.',
      );
    } finally {
      _release();
    }
  }

  Future<void> _command(
    NetworkPhase phase,
    Future<NetworkChangeResult> Function(
      AuthenticatedNetworkSession,
      NetworkTransaction,
    )
    command,
  ) async {
    final expected = _operationSession;
    final transaction = state.transaction;
    if (expected == null || transaction == null || !_current) return;
    final repository = expected.repository;
    if (repository is! AuthenticatedNetworkSession || !_acquire()) return;
    final generation = _generation;
    state = _copy(phase: phase);
    try {
      final result = await command(
        repository as AuthenticatedNetworkSession,
        transaction,
      );
      if (!_valid(generation)) return;
      _accept(result);
    } catch (_) {
      if (!_valid(generation)) return;
      state = _copy(
        phase: NetworkPhase.unknown,
        connectionCurrent: _current,
        message:
            'The result could not be verified. Nothing was retried. '
            'Check status before taking another action on the original server.',
      );
      if (!_current) _release();
    }
  }

  void _accept(NetworkChangeResult result) {
    final current = _current;
    final terminal = const {
      NetworkChangePhase.kept,
      NetworkChangePhase.reverted,
      NetworkChangePhase.rejected,
    }.contains(result.phase);
    if (result.phase == NetworkChangePhase.testing &&
        result.secondsRemaining != null) {
      final seconds = result.secondsRemaining!.clamp(0, 60);
      final candidate = _now + Duration(seconds: seconds);
      if (_deadline == null || candidate < _deadline!) _deadline = candidate;
    }
    state = NetworkState(
      phase: !current && !terminal
          ? NetworkPhase.unknown
          : switch (result.phase) {
              NetworkChangePhase.testing => NetworkPhase.testing,
              NetworkChangePhase.kept => NetworkPhase.kept,
              NetworkChangePhase.reverted => NetworkPhase.reverted,
              NetworkChangePhase.rejected => NetworkPhase.rejected,
              NetworkChangePhase.unknown => NetworkPhase.unknown,
            },
      transaction: result.transaction ?? state.transaction,
      request: state.request,
      serverLabel: state.serverLabel,
      message: !current && !terminal
          ? 'This result belongs to the original connection. Verify it there; '
                'no confirmation will be sent from the selected connection.'
          : result.userMessage,
      secondsRemaining: terminal ? null : _remaining,
      connectionCurrent: current,
    );
    if (terminal) {
      _ticker?.cancel();
      _deadline = null;
      _release();
      if (current) ref.invalidate(networkInventoryProvider);
    } else if (current && state.transaction != null) {
      _startTicker();
    } else if (!current) {
      _release();
    }
  }

  void _startTicker() {
    if (_ticker?.isActive == true) return;
    _ticks = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!ref.mounted || !_current) {
        _ticker?.cancel();
        return;
      }
      _updateCountdown();
      if (_startedAt != null &&
          _now - _startedAt! >= const Duration(minutes: 2)) {
        _ticker?.cancel();
        return;
      }
      if (++_ticks % 5 == 0) unawaited(refreshStatus());
    });
  }

  void _updateCountdown() {
    if (_deadline == null || !state.active) return;
    final remaining = _remaining;
    final expired = remaining == 0 && state.phase == NetworkPhase.testing;
    state = _copy(
      secondsRemaining: remaining,
      phase: expired ? NetworkPhase.unknown : state.phase,
      message: expired
          ? 'The estimated test window has ended. This does not prove rollback '
                'completed. Checking the server is required; Keep is disabled.'
          : state.message,
    );
  }

  int? get _remaining => _deadline == null
      ? null
      : ((_deadline! - _now).inMilliseconds / 1000).ceil().clamp(0, 60);
  Duration get _now => ref.read(networkElapsedProvider)();
  bool get _current =>
      identical(ref.read(dashboardActiveSessionProvider), _operationSession);
  bool _valid(int generation) => ref.mounted && generation == _generation;

  bool _acquire() {
    if (_lockOwner != null) return true;
    _operationLock = ref.read(serverOperationLockProvider);
    _lockOwner = _operationLock!.acquire();
    return _lockOwner != null;
  }

  void _release() {
    if (_lockOwner case final owner?) _operationLock?.release(owner);
    _lockOwner = null;
    _operationLock = null;
  }

  NetworkState _copy({
    NetworkPhase? phase,
    bool? connectionCurrent,
    String? message,
    int? secondsRemaining,
  }) => NetworkState(
    phase: phase ?? state.phase,
    transaction: state.transaction,
    request: state.request,
    serverLabel: state.serverLabel,
    message: message ?? state.message,
    secondsRemaining: secondsRemaining ?? state.secondsRemaining,
    connectionCurrent: connectionCurrent ?? state.connectionCurrent,
  );
}
