import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final snapshotSchedulesSessionProvider =
    Provider<AuthenticatedSnapshotSchedulesSession?>((ref) {
      final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repository is AuthenticatedSnapshotSchedulesSession
          ? repository as AuthenticatedSnapshotSchedulesSession
          : null;
    });
final snapshotSchedulesInventoryProvider =
    FutureProvider<SnapshotScheduleInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = ref.watch(snapshotSchedulesSessionProvider);
      if (session?.endpoint == null || api == null) {
        throw StateError('A live snapshot-schedule connection is required.');
      }
      return api.loadSnapshotSchedules();
    }, retry: (_, _) => null);

final class SnapshotSchedulesState {
  const SnapshotSchedulesState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.action,
    this.connectionCurrent = true,
    this.recoveryMessage,
  });
  final bool busy, connectionCurrent;
  final SnapshotScheduleResult? result;
  final String? server, target, recoveryMessage;
  final SnapshotScheduleAction? action;
  bool get unknown => result?.outcome == SnapshotScheduleOutcome.unknown;
  bool get locked => busy || unknown;
}

final snapshotSchedulesControllerProvider =
    NotifierProvider<SnapshotSchedulesController, SnapshotSchedulesState>(
      SnapshotSchedulesController.new,
    );

class SnapshotSchedulesController extends Notifier<SnapshotSchedulesState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  var _generation = 0;
  final _used = Expando<bool>();
  AuthenticatedSession? get operationSession => _session;
  @override
  SnapshotSchedulesState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = SnapshotSchedulesState(
          server: state.server,
          target: state.target,
          action: state.action,
          connectionCurrent: identical(_session, next),
          result: const SnapshotScheduleResult(
            SnapshotScheduleOutcome.unknown,
            'The connection changed. Inspect the schedule and snapshots on the original server before another change. No request is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const SnapshotSchedulesState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const SnapshotSchedulesState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required SnapshotScheduleReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const SnapshotSchedulesState(
        result: SnapshotScheduleResult(
          SnapshotScheduleOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedSnapshotSchedulesSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const SnapshotSchedulesState(
        result: SnapshotScheduleResult(
          SnapshotScheduleOutcome.rejected,
          'Another server operation is in progress. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = SnapshotSchedulesState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
    );
    SnapshotScheduleResult result;
    try {
      result = await (repository as AuthenticatedSnapshotSchedulesSession)
          .executeSnapshotSchedule(review, confirmation);
    } on SnapshotSchedulesException catch (error) {
      // SDK typed errors happen before dispatch. Ambiguous writes return an
      // unknown result, never a retryable failure.
      result = SnapshotScheduleResult(
        SnapshotScheduleOutcome.rejected,
        error.userMessage,
      );
    } on Object {
      result = const SnapshotScheduleResult(
        SnapshotScheduleOutcome.unknown,
        'The outcome could not be verified. Inspect the original server before reconnecting; do not repeat the request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = SnapshotSchedulesState(
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
      result: result,
    );
    if (!state.unknown) {
      _release();
      // Accepted run requests are queued, not verified snapshot completions.
      // Only reload server-reported state; never synthesize a job or next run.
      ref.invalidate(snapshotSchedulesInventoryProvider);
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
    state = const SnapshotSchedulesState(
      recoveryMessage: 'Prior completion remains unverified. Current inventory is reloaded; no prior request was replayed.',
    );
    ref.invalidate(snapshotSchedulesInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
