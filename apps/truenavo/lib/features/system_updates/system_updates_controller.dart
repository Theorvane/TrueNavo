import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final systemUpdatesSessionProvider =
    Provider<AuthenticatedSystemUpdatesSession?>((ref) {
      final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repository is AuthenticatedSystemUpdatesSession
          ? repository as AuthenticatedSystemUpdatesSession
          : null;
    });

/// Local safety reads and the SDK's cached catalog only. Opening or refreshing
/// this provider must never start an update-source check.
final systemUpdatesInventoryProvider = FutureProvider<SystemUpdateInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(systemUpdatesSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current update connection is required.');
  }
  return api.loadSystemUpdates();
}, retry: (_, _) => null);

final class SystemUpdatesState {
  const SystemUpdatesState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.action,
    this.connectionCurrent = true,
    this.recoveryMessage,
  });
  final bool busy, connectionCurrent;
  final SystemUpdateResult? result;
  final String? server, target, recoveryMessage;
  final SystemUpdateAction? action;
  bool get unknown => result?.outcome == SystemUpdateOutcome.unknown;
  bool get pending => result?.outcome == SystemUpdateOutcome.pending;
  bool get requiresVerification => unknown || result?.rebootRequired == true;
  bool get locked => busy || pending || requiresVerification;
}

final systemUpdatesControllerProvider =
    NotifierProvider<SystemUpdatesController, SystemUpdatesState>(
      SystemUpdatesController.new,
    );

class SystemUpdatesController extends Notifier<SystemUpdatesState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  bool _connectionExpired = false;
  final _used = Expando<bool>();

  @override
  SystemUpdatesState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        _connectionExpired = true;
        state = SystemUpdatesState(
          server: state.server,
          target: state.target,
          action: state.action,
          connectionCurrent: identical(_session, next),
          result: SystemUpdateResult(
            SystemUpdateOutcome.unknown,
            'The connection changed. Verify the original server, update job and boot selection in TrueNAS. Nothing is replayed.',
            job: state.result?.job,
            rebootRequired: state.result?.rebootRequired ?? false,
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const SystemUpdatesState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const SystemUpdatesState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required SystemUpdateReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const SystemUpdatesState(
        result: SystemUpdateResult(
          SystemUpdateOutcome.rejected,
          'The exact target or endpoint changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedSystemUpdatesSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const SystemUpdatesState(
        result: SystemUpdateResult(
          SystemUpdateOutcome.rejected,
          'Another server operation is pending or needs verification. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _connectionExpired = false;
    _used[review] = true;
    final generation = ++_generation;
    state = SystemUpdatesState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
    );
    SystemUpdateResult result;
    try {
      result = await (api as AuthenticatedSystemUpdatesSession)
          .executeSystemUpdate(review, confirmation);
    } on SystemUpdatesException catch (error) {
      result = SystemUpdateResult(
        SystemUpdateOutcome.rejected,
        error.userMessage,
      );
    } on Object {
      result = const SystemUpdateResult(
        SystemUpdateOutcome.unknown,
        'The update outcome could not be verified. Inspect the original server and reconnect. Do not repeat this request.',
      );
    }
    if (!_current(expectedSession, generation)) return;
    _apply(result);
  }

  bool get canPoll =>
      !state.busy &&
      (state.pending || state.unknown) &&
      state.result?.job != null &&
      !_connectionExpired &&
      identical(_session, ref.read(dashboardActiveSessionProvider));

  /// A button drives each read; there is no timer, retry loop or job replay.
  Future<void> poll() async {
    if (!canPoll) return;
    final session = _session!;
    final job = state.result!.job!;
    final api = session.repository as AuthenticatedSystemUpdatesSession;
    final generation = ++_generation;
    state = SystemUpdatesState(
      busy: true,
      server: state.server,
      target: state.target,
      action: state.action,
      result: state.result,
    );
    SystemUpdateResult result;
    try {
      result = await api.pollSystemUpdate(job);
    } on Object {
      result = SystemUpdateResult(
        SystemUpdateOutcome.unknown,
        'This job read could not verify completion. The original job remains owned; you may check its status manually. Do not submit another update.',
        job: job,
      );
    }
    if (!_current(session, generation)) return;
    if ((result.outcome == SystemUpdateOutcome.pending ||
            result.outcome == SystemUpdateOutcome.unknown) &&
        result.job == null) {
      result = SystemUpdateResult(
        result.outcome,
        result.message,
        job: job,
        percent: result.percent,
        rebootRequired: result.rebootRequired,
      );
    }
    _apply(result);
  }

  bool _current(AuthenticatedSession session, int generation) =>
      ref.mounted &&
      generation == _generation &&
      identical(session, ref.read(dashboardActiveSessionProvider));

  void _apply(SystemUpdateResult result) {
    state = SystemUpdatesState(
      server: state.server,
      target: state.target,
      action: state.action,
      result: result,
    );
    if (!state.locked) {
      _release();
      ref.invalidate(systemUpdatesInventoryProvider);
    }
  }

  bool get canAcknowledge {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.requiresVerification &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _session);
  }

  void acknowledgeAfterReconnect() {
    if (!canAcknowledge) return;
    _release();
    _session = null;
    state = const SystemUpdatesState(
      recoveryMessage: 'Prior effects still require independent verification. Local safety information is reloaded; no check, download, installation or reboot was replayed.',
    );
    ref.invalidate(systemUpdatesInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
