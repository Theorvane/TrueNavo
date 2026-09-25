import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final cloudSyncSessionProvider = Provider<AuthenticatedCloudSyncSession?>((
  ref,
) {
  final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repo is AuthenticatedCloudSyncSession
      ? repo as AuthenticatedCloudSyncSession
      : null;
});
final cloudSyncInventoryProvider = FutureProvider<CloudSyncInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(cloudSyncSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current cloud sync connection is required.');
  }
  return api.loadCloudSync();
}, retry: (_, _) => null);

final class CloudSyncState {
  const CloudSyncState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final CloudSyncResult? result;
  final String? server, target;
  bool get unknown => result?.outcome == CloudSyncOutcome.unknown;
  bool get pending => result?.outcome == CloudSyncOutcome.pending;
  bool get locked => busy || unknown || pending;
}

final cloudSyncControllerProvider =
    NotifierProvider<CloudSyncController, CloudSyncState>(
      CloudSyncController.new,
    );

class CloudSyncController extends Notifier<CloudSyncState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  bool _expired = false;
  final _used = Expando<bool>();
  @override
  CloudSyncState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        _expired = true;
        state = CloudSyncState(
          server: state.server,
          target: state.target,
          connectionCurrent: identical(_session, next),
          result: CloudSyncResult(
            CloudSyncOutcome.unknown,
            'The connection changed. Inspect the original server and both sync endpoints. Nothing is replayed.',
            job: state.result?.job,
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const CloudSyncState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const CloudSyncState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required CloudSyncReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const CloudSyncState(
        result: CloudSyncResult(
          CloudSyncOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedCloudSyncSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const CloudSyncState(
        result: CloudSyncResult(
          CloudSyncOutcome.rejected,
          'Another operation is pending or unverified. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _expired = false;
    _used[review] = true;
    final generation = ++_generation;
    state = CloudSyncState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
    );
    CloudSyncResult result;
    try {
      result = await (api as AuthenticatedCloudSyncSession).executeCloudSync(
        review,
        confirmation,
      );
    } on CloudSyncException catch (e) {
      result = CloudSyncResult(CloudSyncOutcome.rejected, e.userMessage);
    } on Object {
      result = const CloudSyncResult(
        CloudSyncOutcome.unknown,
        'The outcome could not be verified. Inspect the original server before reconnecting. Do not repeat the request.',
      );
    }
    if (_current(expectedSession, generation)) _apply(result);
  }

  bool _current(AuthenticatedSession session, int generation) =>
      ref.mounted &&
      generation == _generation &&
      identical(session, ref.read(dashboardActiveSessionProvider));
  bool get canPoll =>
      !state.busy &&
      (state.pending || state.unknown) &&
      state.result?.job != null &&
      !_expired &&
      identical(_session, ref.read(dashboardActiveSessionProvider));
  Future<void> poll() async {
    if (!canPoll) return;
    final session = _session!,
        job = state.result!.job!,
        generation = ++_generation;
    state = CloudSyncState(
      busy: true,
      server: state.server,
      target: state.target,
      result: state.result,
    );
    CloudSyncResult result;
    try {
      result = await (session.repository as AuthenticatedCloudSyncSession)
          .pollCloudSync(job);
    } on Object {
      result = CloudSyncResult(
        CloudSyncOutcome.unknown,
        'The owned job could not be verified. Check the same job again; do not start another sync.',
        job: job,
      );
    }
    if (!_current(session, generation)) return;
    if ((result.outcome == CloudSyncOutcome.pending ||
            result.outcome == CloudSyncOutcome.unknown) &&
        result.job == null) {
      result = CloudSyncResult(
        result.outcome,
        result.message,
        job: job,
        percent: result.percent,
      );
    }
    _apply(result);
  }

  void _apply(CloudSyncResult result) {
    state = CloudSyncState(
      server: state.server,
      target: state.target,
      result: result,
    );
    if (!state.locked) {
      _release();
      ref.invalidate(cloudSyncInventoryProvider);
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
    state = const CloudSyncState(
      result: CloudSyncResult(
        CloudSyncOutcome.rejected,
        'Prior effects remain unverified. Current information is reloaded without replaying any operation.',
      ),
    );
    ref.invalidate(cloudSyncInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
