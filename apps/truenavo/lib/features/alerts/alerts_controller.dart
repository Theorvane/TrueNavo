import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final alertsSessionProvider = Provider<AuthenticatedAlertsSession?>((ref) {
  final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repo is AuthenticatedAlertsSession
      ? repo as AuthenticatedAlertsSession
      : null;
});
final alertsInventoryProvider = FutureProvider<AlertInventory>((ref) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(alertsSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current alert connection is required.');
  }
  return api.loadAlerts();
}, retry: (_, _) => null);

final class AlertsState {
  const AlertsState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final AlertResult? result;
  final String? server, target;
  bool get unknown => result?.outcome == AlertOutcome.unknown;
  bool get locked => busy || unknown;
}

final alertsControllerProvider =
    NotifierProvider<AlertsController, AlertsState>(AlertsController.new);

class AlertsController extends Notifier<AlertsState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  @override
  AlertsState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = AlertsState(
          server: state.server,
          target: state.target,
          connectionCurrent: identical(_session, next),
          result: const AlertResult(
            AlertOutcome.unknown,
            'The connection changed. Inspect the original server; no alert action is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const AlertsState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const AlertsState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required AlertReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const AlertsState(
        result: AlertResult(
          AlertOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedAlertsSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const AlertsState(
        result: AlertResult(
          AlertOutcome.rejected,
          'Another operation is pending or unverified. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = AlertsState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
    );
    AlertResult result;
    try {
      result = await (api as AuthenticatedAlertsSession).executeAlert(
        review,
        confirmation,
      );
    } on AlertsException catch (e) {
      result = AlertResult(AlertOutcome.rejected, e.userMessage);
    } on Object {
      result = const AlertResult(
        AlertOutcome.unknown,
        'The alert outcome could not be verified. Inspect the original server before reconnecting. Do not repeat the request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = AlertsState(
      server: state.server,
      target: state.target,
      result: result,
    );
    if (!state.locked) {
      _release();
      ref.invalidate(alertsInventoryProvider);
    }
  }

  bool get canAcknowledge {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unknown &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _session);
  }

  void acknowledgeAfterReconnect() {
    if (!canAcknowledge) return;
    _release();
    _session = null;
    state = const AlertsState(
      result: AlertResult(
        AlertOutcome.rejected,
        'Prior effects remain unverified. Current alerts are reloaded without replaying the operation.',
      ),
    );
    ref.invalidate(alertsInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
