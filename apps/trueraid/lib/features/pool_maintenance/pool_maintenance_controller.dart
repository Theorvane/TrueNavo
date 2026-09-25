import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final poolMaintenanceSessionProvider =
    Provider<AuthenticatedPoolMaintenanceSession?>((ref) {
      final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repository is AuthenticatedPoolMaintenanceSession
          ? repository as AuthenticatedPoolMaintenanceSession
          : null;
    });
final poolMaintenanceInventoryProvider =
    FutureProvider<PoolMaintenanceInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider),
          api = ref.watch(poolMaintenanceSessionProvider);
      if (session?.endpoint == null || api == null) {
        throw StateError('A current maintenance connection is required.');
      }
      return api.loadPoolMaintenance();
    }, retry: (_, _) => null);

final class PoolMaintenanceState {
  const PoolMaintenanceState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.job,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final PoolMaintenanceResult? result;
  final PoolMaintenanceJob? job;
  final String? server, target;
  bool get unknown => result?.outcome == PoolMaintenanceOutcome.unknown;
  bool get pendingJob => job != null && !unknown;
  bool get locked => busy || unknown || pendingJob;
}

final poolMaintenanceControllerProvider =
    NotifierProvider<PoolMaintenanceController, PoolMaintenanceState>(
      PoolMaintenanceController.new,
    );

class PoolMaintenanceController extends Notifier<PoolMaintenanceState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  @override
  PoolMaintenanceState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = PoolMaintenanceState(
          server: state.server,
          target: state.target,
          job: state.job,
          connectionCurrent: identical(_session, next),
          result: const PoolMaintenanceResult(
            PoolMaintenanceOutcome.unknown,
            'The connection changed. Inspect the original server. No maintenance request is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const PoolMaintenanceState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const PoolMaintenanceState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required PoolMaintenanceReview review,
    required String confirmation,
  }) async {
    if (_used[review] == true || !allowsRequest(review.request)) return;
    final priorJob = state.job;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const PoolMaintenanceState(
        result: PoolMaintenanceResult(
          PoolMaintenanceOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedPoolMaintenanceSession) return;
    _lock = ref.read(serverOperationLockProvider);
    if (priorJob == null) _owner = _lock!.acquire();
    if (_owner == null) {
      state = const PoolMaintenanceState(
        result: PoolMaintenanceResult(
          PoolMaintenanceOutcome.rejected,
          'Another operation is pending or unverified. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = PoolMaintenanceState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
      job: priorJob,
    );
    PoolMaintenanceResult result;
    try {
      result = await (api as AuthenticatedPoolMaintenanceSession)
          .executePoolMaintenance(review, confirmation);
    } on PoolMaintenanceException catch (e) {
      result = PoolMaintenanceResult(
        PoolMaintenanceOutcome.rejected,
        e.userMessage,
      );
    } on Object {
      result = const PoolMaintenanceResult(
        PoolMaintenanceOutcome.unknown,
        'The outcome could not be verified. Inspect the original server before reconnecting. Do not repeat the request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    if (result.outcome == PoolMaintenanceOutcome.accepted &&
        (result.job == null ||
            result.job!.id <= 0 ||
            result.job!.endpoint != review.endpoint ||
            result.job!.poolId != review.request.pool.id ||
            result.job!.poolName != review.request.pool.name ||
            result.job!.poolGuid != review.request.pool.guid ||
            result.job!.action != review.action)) {
      result = const PoolMaintenanceResult(
        PoolMaintenanceOutcome.unknown,
        'The accepted scrub job identity was not verified. Inspect the original server before another change.',
      );
    }
    state = PoolMaintenanceState(
      server: state.server,
      target: state.target,
      result: result,
      job: result.outcome == PoolMaintenanceOutcome.rejected
          ? priorJob
          : result.job,
    );
    if (!state.locked) {
      _release();
    }
    if (!state.unknown) {
      ref.invalidate(poolMaintenanceInventoryProvider);
    }
  }

  bool canStop(PoolMaintenancePool pool) {
    final job = state.job;
    return !state.busy &&
        !state.unknown &&
        state.connectionCurrent &&
        identical(_session, ref.read(dashboardActiveSessionProvider)) &&
        job != null &&
        job.action == PoolMaintenanceAction.startScrub &&
        job.poolId == pool.id &&
        job.poolName == pool.name &&
        job.poolGuid == pool.guid;
  }

  bool allowsRequest(PoolMaintenanceRequest request) =>
      !state.busy &&
      !state.unknown &&
      (!state.pendingJob ||
          request.action == PoolMaintenanceAction.stopScrub &&
              canStop(request.pool));

  bool get canCheck =>
      state.pendingJob &&
      !state.busy &&
      state.connectionCurrent &&
      identical(_session, ref.read(dashboardActiveSessionProvider));

  Future<void> checkJob() async {
    if (!canCheck) return;
    final session = _session!, job = state.job!;
    final api = session.repository;
    if (api is! AuthenticatedPoolMaintenanceSession) return;
    final generation = ++_generation;
    final prior = state;
    state = PoolMaintenanceState(
      busy: true,
      server: prior.server,
      target: prior.target,
      result: prior.result,
      job: job,
    );
    PoolMaintenanceResult result;
    try {
      result = await (api as AuthenticatedPoolMaintenanceSession)
          .checkPoolMaintenanceJob(job);
    } on Object {
      result = const PoolMaintenanceResult(
        PoolMaintenanceOutcome.unknown,
        'The owned scrub job could not be verified. Inspect the original server before reconnecting. No request was replayed.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    if (result.outcome == PoolMaintenanceOutcome.accepted &&
        (result.job == null ||
            result.job!.id != job.id ||
            result.job!.endpoint != job.endpoint ||
            result.job!.poolId != job.poolId ||
            result.job!.poolGuid != job.poolGuid ||
            result.job!.poolName != job.poolName ||
            result.job!.action != job.action)) {
      result = const PoolMaintenanceResult(
        PoolMaintenanceOutcome.unknown,
        'The reported scrub job identity changed. Inspect the original server before another change.',
      );
    }
    state = PoolMaintenanceState(
      server: prior.server,
      target: prior.target,
      result: result,
      job: result.outcome == PoolMaintenanceOutcome.succeeded
          ? null
          : result.job ?? job,
    );
    if (!state.locked) _release();
    if (!state.unknown) ref.invalidate(poolMaintenanceInventoryProvider);
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
    state = const PoolMaintenanceState(
      result: PoolMaintenanceResult(
        PoolMaintenanceOutcome.rejected,
        'Prior effects remain unverified. Information is reloaded without replaying the maintenance change.',
      ),
    );
    ref.invalidate(poolMaintenanceInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
