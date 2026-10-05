import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final snapshotsSessionProvider = Provider<AuthenticatedSnapshotsSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedSnapshotsSession
      ? repository as AuthenticatedSnapshotsSession
      : null;
});

final snapshotDatasetsProvider = FutureProvider<List<SnapshotDataset>>((
  ref,
) async {
  final session = ref.watch(snapshotsSessionProvider);
  if (session == null) {
    throw const SnapshotsException(SnapshotsExceptionReason.notAuthenticated);
  }
  return session.loadSnapshotDatasets();
});

final snapshotInventoryProvider = FutureProvider.autoDispose
    .family<SnapshotPageResult, SnapshotQuery>((ref, query) async {
      final session = ref.watch(snapshotsSessionProvider);
      if (session == null) {
        throw const SnapshotsException(
          SnapshotsExceptionReason.notAuthenticated,
        );
      }
      return session.loadSnapshots(query);
    });

final class SnapshotsState {
  const SnapshotsState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
  });
  final bool busy;
  final SnapshotOperationResult? result;
  final String? server;
  final String? target;
  bool get unresolved => result?.outcome == SnapshotOperationOutcome.unknown;
}

final snapshotsControllerProvider =
    NotifierProvider<SnapshotsController, SnapshotsState>(
      SnapshotsController.new,
    );

class SnapshotsController extends Notifier<SnapshotsState> {
  AuthenticatedSession? _operationSession;
  ServerOperationLock? _lock;
  Object? _owner;
  var _generation = 0;

  @override
  SnapshotsState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (_operationSession == null || identical(_operationSession, next)) {
        return;
      }
      _generation++;
      _release();
      if (state.busy || state.unresolved) {
        state = SnapshotsState(
          server: state.server,
          target: state.target,
          result: const SnapshotOperationResult(
            outcome: SnapshotOperationOutcome.unknown,
            message: 'The connection changed. Inspect the snapshot outcome on the original server before making another change.',
          ),
        );
      } else {
        _operationSession = null;
        state = const SnapshotsState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const SnapshotsState();
  }

  Future<void> create({
    required AuthenticatedSession expectedSession,
    required SnapshotCreateRequest request,
  }) => _run(
    expectedSession,
    request.id,
    request.validationError,
    (api) => api.createSnapshot(request),
  );

  Future<void> delete({
    required AuthenticatedSession expectedSession,
    required SnapshotDeleteRequest request,
  }) => _run(
    expectedSession,
    request.snapshot.id,
    request.validationError,
    (api) => api.deleteSnapshot(request),
  );

  Future<void> recover({
    required AuthenticatedSession expectedSession,
    required SnapshotRecoveryRequest request,
  }) => _run(
    expectedSession,
    request.review.plan.target,
    request.validationError,
    (api) => api.applySnapshotRecovery(request),
  );

  Future<void> _run(
    AuthenticatedSession expectedSession,
    String target,
    String? validationError,
    Future<SnapshotOperationResult> Function(AuthenticatedSnapshotsSession)
    action,
  ) async {
    if (state.busy || state.unresolved) return;
    if (!identical(ref.read(dashboardActiveSessionProvider), expectedSession) ||
        expectedSession.endpoint == null) {
      state = const SnapshotsState(
        result: SnapshotOperationResult(
          outcome: SnapshotOperationOutcome.rejected,
          message: 'The authenticated server changed. Reload and review again. Nothing was sent.',
        ),
      );
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedSnapshotsSession ||
        validationError != null) {
      state = SnapshotsState(
        result: SnapshotOperationResult(
          outcome: SnapshotOperationOutcome.rejected,
          message: validationError ?? 'Reconnect to load the snapshot adapter.',
        ),
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const SnapshotsState(
        result: SnapshotOperationResult(
          outcome: SnapshotOperationOutcome.rejected,
          message: 'Another server operation is in progress.',
        ),
      );
      return;
    }
    final generation = ++_generation;
    _operationSession = expectedSession;
    state = SnapshotsState(
      busy: true,
      server: expectedSession.endpoint,
      target: target,
    );
    SnapshotOperationResult result;
    try {
      result = await action(repository as AuthenticatedSnapshotsSession);
    } on SnapshotsException catch (error) {
      result = SnapshotOperationResult(
        outcome: SnapshotOperationOutcome.rejected,
        message: error.userMessage,
      );
    } on Object {
      result = const SnapshotOperationResult(
        outcome: SnapshotOperationOutcome.unknown,
        message: 'The snapshot operation could not be verified. Do not retry; inspect the original server and reconnect.',
      );
    }
    if (!ref.mounted || generation != _generation) return;
    state = SnapshotsState(
      result: result,
      server: expectedSession.endpoint,
      target: target,
    );
    if (result.outcome != SnapshotOperationOutcome.unknown) _release();
    ref.invalidate(snapshotDatasetsProvider);
    ref.invalidate(snapshotInventoryProvider);
  }

  bool get canAcknowledgeUnknown =>
      state.unresolved &&
      ref.read(dashboardActiveSessionProvider) != null &&
      !identical(_operationSession, ref.read(dashboardActiveSessionProvider));

  void acknowledgeUnknown() {
    if (!canAcknowledgeUnknown) return;
    _release();
    _operationSession = null;
    state = const SnapshotsState();
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _lock?.release(owner);
    _owner = null;
  }
}
