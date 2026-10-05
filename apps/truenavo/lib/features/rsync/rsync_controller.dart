import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final rsyncSessionProvider = Provider<AuthenticatedRsyncSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedRsyncSession
      ? repository as AuthenticatedRsyncSession
      : null;
});
final rsyncInventoryProvider = FutureProvider<RsyncInventory>((ref) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(rsyncSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current Rsync connection is required.');
  }
  final inventory = await api.loadRsync();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      inventory.endpoint != session!.endpoint) {
    throw StateError('The Rsync inventory connection changed.');
  }
  return inventory;
}, retry: (_, _) => null);

final class RsyncState {
  const RsyncState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.job,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final RsyncResult? result;
  final RsyncJob? job;
  final String? server, target;
  bool get unknown => result?.outcome == RsyncOutcome.unknown;
  bool get pendingJob => job != null && !unknown;
  bool get locked => busy || unknown || pendingJob;
}

final rsyncControllerProvider = NotifierProvider<RsyncController, RsyncState>(
  RsyncController.new,
);

class RsyncController extends Notifier<RsyncState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  @override
  RsyncState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = RsyncState(
          server: state.server,
          target: state.target,
          job: state.job,
          connectionCurrent: identical(_session, next),
          result: const RsyncResult(
            RsyncOutcome.unknown,
            'The connection changed. Inspect the original server. No Rsync request is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const RsyncState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const RsyncState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required RsyncReview review,
    required String confirmation,
  }) async {
    if (_used[review] == true || !allowsRequest(review.request)) return;

    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const RsyncState(
        result: RsyncResult(
          RsyncOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedRsyncSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const RsyncState(
        result: RsyncResult(
          RsyncOutcome.rejected,
          'Another operation is pending or unverified. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = RsyncState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
    );
    RsyncResult result;
    try {
      result = await (api as AuthenticatedRsyncSession).executeRsync(
        review,
        confirmation,
      );
    } on RsyncException catch (e) {
      result = RsyncResult(RsyncOutcome.rejected, e.userMessage);
    } on Object {
      result = const RsyncResult(
        RsyncOutcome.unknown,
        'The outcome could not be verified. Inspect the original server before reconnecting. Do not repeat the request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    if (result.outcome == RsyncOutcome.accepted &&
        (result.job == null ||
            result.job!.id <= 0 ||
            result.job!.endpoint != review.endpoint ||
            review.action != RsyncAction.run ||
            result.job!.taskId != review.request.task?.id ||
            result.job!.path != review.request.desired?.path ||
            result.job!.connectionId != review.request.desired?.connectionId ||
            result.job!.remotePath != review.request.desired?.remotePath)) {
      result = const RsyncResult(
        RsyncOutcome.unknown,
        'The accepted Rsync job identity was not verified. Inspect the original server before another change.',
      );
    }
    state = RsyncState(
      server: state.server,
      target: state.target,
      result: result,
      job: result.job,
    );
    if (!state.locked) {
      _release();
    }
    if (!state.unknown) {
      ref.invalidate(rsyncInventoryProvider);
    }
  }

  bool allowsRequest(RsyncRequest request) => !state.locked;

  bool get canCheck =>
      state.pendingJob &&
      !state.busy &&
      state.connectionCurrent &&
      identical(_session, ref.read(dashboardActiveSessionProvider));

  Future<void> checkJob() async {
    if (!canCheck) return;
    final session = _session!, job = state.job!;
    final api = session.repository;
    if (api is! AuthenticatedRsyncSession) return;
    final generation = ++_generation;
    final prior = state;
    state = RsyncState(
      busy: true,
      server: prior.server,
      target: prior.target,
      result: prior.result,
      job: job,
    );
    RsyncResult result;
    try {
      result = await (api as AuthenticatedRsyncSession).checkRsyncJob(job);
    } on Object {
      result = const RsyncResult(
        RsyncOutcome.unknown,
        'The owned Rsync job could not be verified. Inspect the original server before reconnecting. No request was replayed.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    if (result.outcome == RsyncOutcome.accepted &&
        (result.job == null ||
            result.job!.id != job.id ||
            result.job!.endpoint != job.endpoint ||
            result.job!.taskId != job.taskId ||
            result.job!.path != job.path ||
            result.job!.connectionId != job.connectionId ||
            result.job!.remotePath != job.remotePath)) {
      result = const RsyncResult(
        RsyncOutcome.unknown,
        'The reported Rsync job identity changed. Inspect the original server before another change.',
      );
    }
    state = RsyncState(
      server: prior.server,
      target: prior.target,
      result: result,
      job: result.outcome == RsyncOutcome.succeeded ? null : result.job ?? job,
    );
    if (!state.locked) _release();
    if (!state.unknown) ref.invalidate(rsyncInventoryProvider);
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
    state = const RsyncState(
      result: RsyncResult(
        RsyncOutcome.rejected,
        'Prior effects remain unverified. Information is reloaded without replaying the Rsync change.',
      ),
    );
    ref.invalidate(rsyncInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
