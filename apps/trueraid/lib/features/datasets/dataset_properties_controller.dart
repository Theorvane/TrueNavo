import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final datasetPropertiesSessionProvider =
    Provider<AuthenticatedDatasetPropertiesSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedDatasetPropertiesSession
          ? repo as AuthenticatedDatasetPropertiesSession
          : null;
    });
final datasetPropertiesProvider = FutureProvider<List<DatasetPropertySnapshot>>(
  (ref) async =>
      await ref
          .watch(datasetPropertiesSessionProvider)
          ?.loadDatasetProperties() ??
      const [],
);

final class DatasetPropertiesState {
  const DatasetPropertiesState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
  });
  final bool busy;
  final DatasetPropertyResult? result;
  final String? server;
  final String? target;
  bool get unresolved => result?.outcome == DatasetPropertyOutcome.unknown;
}

final datasetPropertiesControllerProvider =
    NotifierProvider<DatasetPropertiesController, DatasetPropertiesState>(
      DatasetPropertiesController.new,
    );

class DatasetPropertiesController extends Notifier<DatasetPropertiesState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  @override
  DatasetPropertiesState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (identical(_session, next)) return;
      _generation++;
      _release();
      _session = null;
      // Keep an unknown outcome visibly associated with its original server.
      state = state.busy || state.unresolved
          ? DatasetPropertiesState(
              server: state.server,
              target: state.target,
              result: const DatasetPropertyResult(
                outcome: DatasetPropertyOutcome.unknown,
                message: 'The connection changed. The previous update outcome is unknown; inspect that dataset before retrying.',
              ),
            )
          : const DatasetPropertiesState();
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const DatasetPropertiesState();
  }

  Future<void> apply({
    required AuthenticatedSession expectedSession,
    required DatasetPropertyUpdate request,
  }) async {
    if (state.busy ||
        state.unresolved ||
        !identical(ref.read(dashboardActiveSessionProvider), expectedSession) ||
        expectedSession.endpoint == null) {
      return;
    }
    final repo = expectedSession.repository;
    if (repo is! AuthenticatedDatasetPropertiesSession ||
        request.validationError != null) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const DatasetPropertiesState(
        result: DatasetPropertyResult(
          outcome: DatasetPropertyOutcome.rejected,
          message: 'Another server operation is in progress.',
        ),
      );
      return;
    }
    final generation = ++_generation;
    _session = expectedSession;
    state = DatasetPropertiesState(
      busy: true,
      server: expectedSession.endpoint,
      target: request.snapshot.id,
    );
    DatasetPropertyResult result;
    try {
      result = await (repo as AuthenticatedDatasetPropertiesSession)
          .updateDatasetProperties(request);
    } on DatasetPropertiesException catch (error) {
      result = DatasetPropertyResult(
        outcome: DatasetPropertyOutcome.rejected,
        message: error.userMessage,
      );
    } on Object {
      result = const DatasetPropertyResult(
        outcome: DatasetPropertyOutcome.unknown,
        message: 'The update could not be verified. Do not retry; inspect the dataset in TrueNAS.',
      );
    }
    if (!ref.mounted || generation != _generation) return;
    state = DatasetPropertiesState(
      result: result,
      server: expectedSession.endpoint,
      target: request.snapshot.id,
    );
    if (result.outcome != DatasetPropertyOutcome.unknown) _release();
    ref.invalidate(datasetPropertiesProvider);
  }

  /// User acknowledgement after reconnect, never a replay or success claim.
  void acknowledgeUnknown() {
    if (state.unresolved &&
        !identical(_session, ref.read(dashboardActiveSessionProvider))) {
      _release();
      state = const DatasetPropertiesState();
    }
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _lock?.release(owner);
    _owner = null;
  }
}
