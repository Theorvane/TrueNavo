import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final replicationSessionProvider = Provider<AuthenticatedReplicationSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedReplicationSession
      ? repository as AuthenticatedReplicationSession
      : null;
});

final replicationInventoryProvider = FutureProvider<ReplicationInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(replicationSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current replication connection is required.');
  }
  return api.loadReplication();
}, retry: (_, _) => null);

final class ReplicationState {
  const ReplicationState({
    this.busy = false,
    this.connectionCurrent = true,
    this.result,
    this.server,
    this.target,
    this.action,
    this.recoveryMessage,
  });
  final bool busy, connectionCurrent;
  final ReplicationResult? result;
  final String? server, target, recoveryMessage;
  final ReplicationAction? action;
  bool get unknown => result?.outcome == ReplicationOutcome.unknown;
  bool get pending => result?.outcome == ReplicationOutcome.pending;
  bool get locked => busy || pending || unknown;
}

final replicationControllerProvider =
    NotifierProvider<ReplicationController, ReplicationState>(
      ReplicationController.new,
    );

class ReplicationController extends Notifier<ReplicationState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  bool _connectionExpired = false;
  final _used = Expando<bool>();

  @override
  ReplicationState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        _connectionExpired = true;
        state = ReplicationState(
          server: state.server,
          target: state.target,
          action: state.action,
          connectionCurrent: identical(_session, next),
          result: ReplicationResult(
            ReplicationOutcome.unknown,
            'The connection changed. Verify the original server, task and destination in TrueNAS. Nothing is replayed.',
            job: state.result?.job,
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const ReplicationState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const ReplicationState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required ReplicationReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const ReplicationState(
        result: ReplicationResult(
          ReplicationOutcome.rejected,
          'The exact target or endpoint changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedReplicationSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const ReplicationState(
        result: ReplicationResult(
          ReplicationOutcome.rejected,
          'Another server operation is pending or needs verification. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _connectionExpired = false;
    _used[review] = true;
    final generation = ++_generation;
    state = ReplicationState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
    );
    ReplicationResult result;
    try {
      result = await (api as AuthenticatedReplicationSession)
          .executeReplication(review, confirmation);
    } on ReplicationException catch (error) {
      result = ReplicationResult(
        ReplicationOutcome.rejected,
        error.userMessage,
      );
    } on Object {
      result = const ReplicationResult(
        ReplicationOutcome.unknown,
        'The replication outcome could not be verified. Inspect the original server and reconnect. Do not repeat this request.',
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

  /// Each owned-job read requires a tap; no timer, retry loop or run replay.
  Future<void> poll() async {
    if (!canPoll) return;
    final session = _session!, job = state.result!.job!;
    final api = session.repository as AuthenticatedReplicationSession;
    final generation = ++_generation;
    state = ReplicationState(
      busy: true,
      server: state.server,
      target: state.target,
      action: state.action,
      result: state.result,
    );
    ReplicationResult result;
    try {
      result = await api.pollReplication(job);
    } on Object {
      result = ReplicationResult(
        ReplicationOutcome.unknown,
        'Completion could not be verified. The original job remains owned; check its status manually. Do not submit another operation.',
        job: job,
      );
    }
    if (!_current(session, generation)) return;
    if ((result.outcome == ReplicationOutcome.pending ||
            result.outcome == ReplicationOutcome.unknown) &&
        result.job == null) {
      result = ReplicationResult(
        result.outcome,
        result.message,
        job: job,
        percent: result.percent,
      );
    }
    _apply(result);
  }

  bool _current(AuthenticatedSession session, int generation) =>
      ref.mounted &&
      generation == _generation &&
      identical(session, ref.read(dashboardActiveSessionProvider));
  void _apply(ReplicationResult result) {
    state = ReplicationState(
      server: state.server,
      target: state.target,
      action: state.action,
      result: result,
    );
    if (!state.locked) {
      _release();
      ref.invalidate(replicationInventoryProvider);
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
    state = const ReplicationState(
      recoveryMessage: 'Prior effects still require independent verification. Inventory is reloaded; no task change or replication run was replayed.',
    );
    ref.invalidate(replicationInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
