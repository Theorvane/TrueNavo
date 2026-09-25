import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final permissionsSessionProvider = Provider<AuthenticatedPermissionsSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedPermissionsSession
      ? repository as AuthenticatedPermissionsSession
      : null;
});

final permissionsDatasetsProvider = FutureProvider<List<PermissionDataset>>((
  ref,
) async {
  ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(permissionsSessionProvider);
  if (api == null) return const [];
  return api.loadPermissionDatasets();
});

final permissionsReviewProvider = FutureProvider.autoDispose
    .family<PermissionReview, PermissionDataset>((ref, dataset) async {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = ref.watch(permissionsSessionProvider);
      if (api == null) {
        throw StateError('A live permissions connection is required.');
      }
      // The SDK issues new dataset identities on every list refresh and clears
      // old ACL reviews. Serialize detail loading after that refresh and use
      // the freshly issued exact dataset, never the route's stale object.
      final inventory = await ref.watch(permissionsDatasetsProvider.future);
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        throw const PermissionsException(
          PermissionsExceptionReason.staleSnapshot,
        );
      }
      final matches = inventory
          .where(
            (item) =>
                item.id == dataset.id && item.mountpoint == dataset.mountpoint,
          )
          .toList();
      if (matches.length != 1) {
        throw const PermissionsException(
          PermissionsExceptionReason.staleSnapshot,
        );
      }
      return api.loadPermissionReview(matches.single);
    });

/// Each automatic check is read-only. Thirty 2-second checks is the maximum;
/// the user can explicitly check a retained receipt afterwards without replay.
final permissionsAutoPollLimitProvider = Provider<int>((ref) => 30);

enum PermissionsPhase {
  idle,
  submitting,
  checking,
  pending,
  verified,
  failed,
  unknown,
}

final class PermissionsState {
  const PermissionsState({
    this.phase = PermissionsPhase.idle,
    this.result,
    this.server,
    this.path,
    this.datasetId,
    this.message,
    this.jobId,
    this.connectionCurrent = true,
  });
  final PermissionsPhase phase;
  final PermissionOperationResult? result;
  final String? server, path, datasetId, message;
  final int? jobId;
  final bool connectionCurrent;
  bool get busy =>
      phase == PermissionsPhase.submitting ||
      phase == PermissionsPhase.checking;
  bool get unknown => phase == PermissionsPhase.unknown;
  bool get pending => phase == PermissionsPhase.pending;
  bool get locked => busy || pending || unknown;
  bool get canCheck =>
      connectionCurrent &&
      !busy &&
      (pending || unknown) &&
      result?.canCheck == true;
}

final permissionsControllerProvider =
    NotifierProvider<PermissionsController, PermissionsState>(
      PermissionsController.new,
    );

/// A route-independent operation receipt. Disconnecting never implies success
/// or resends an ACL; old inventories are separately fenced by the route.
class PermissionsController extends Notifier<PermissionsState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _lockOwner;
  Timer? _timer;
  var _generation = 0;
  var _polls = 0;
  final _submitted = Expando<bool>();
  AuthenticatedSession? get operationSession => _session;

  @override
  PermissionsState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (_session == null) return;
      final current = identical(_session, next);
      if (current == state.connectionCurrent) return;
      _generation++;
      _timer?.cancel();
      if (!current) _release();
      if (current && state.locked) _lockOwner ??= _lock?.acquire();
      state = state.locked
          ? _copy(
              phase: PermissionsPhase.unknown,
              connectionCurrent: current,
              message: current
                  ? 'The original connection is selected again. Check the retained job receipt; no request was replayed.'
                  : 'The connection changed. The original operation may still run. Old ACL data is hidden; verify the original server before another change.',
            )
          : const PermissionsState();
    });
    ref.onDispose(() {
      _generation++;
      _timer?.cancel();
      _release();
    });
    return const PermissionsState();
  }

  Future<void> apply({
    required AuthenticatedSession expectedSession,
    required PermissionApplyRequest request,
    required String confirmation,
  }) async {
    if (state.locked || _submitted[request] == true) return;
    if (expectedSession.endpoint == null ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        confirmation != request.review.dataset.mountpoint ||
        request.validationError != null) {
      state = const PermissionsState(
        phase: PermissionsPhase.failed,
        message: 'The target or connection changed, or the draft is invalid. Nothing was sent.',
      );
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedPermissionsSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _lockOwner = _lock!.acquire();
    if (_lockOwner == null) {
      state = const PermissionsState(
        phase: PermissionsPhase.failed,
        message: 'Another server operation is in progress. Nothing was sent.',
      );
      return;
    }
    _session = expectedSession;
    _submitted[request] = true;
    final generation = ++_generation;
    _polls = 0;
    state = PermissionsState(
      phase: PermissionsPhase.submitting,
      server: expectedSession.endpoint,
      path: request.review.dataset.mountpoint,
      datasetId: request.review.dataset.id,
      message: 'Submitting the reviewed non-recursive change once. It will not be retried automatically.',
    );
    try {
      final result = await (repository as AuthenticatedPermissionsSession)
          .applyPermissions(request);
      if (_current(generation)) {
        _accept(result);
      } else if (ref.mounted &&
          identical(_session, expectedSession) &&
          state.unknown) {
        state = _copy(
          result: result,
          phase: PermissionsPhase.unknown,
          message: 'A late receipt belongs to the original server only. Its outcome has not been verified on this connection.',
        );
      }
    } on PermissionsException catch (error) {
      // The SDK returns unknown receipts after dispatch; typed exceptions here
      // are confirmed pre-dispatch rejections, so the shared lock can release.
      if (_current(generation)) {
        state = _copy(
          phase: PermissionsPhase.failed,
          message: '${error.userMessage} Nothing was sent.',
        );
        _release();
      }
    } on Object {
      if (_current(generation)) {
        state = _copy(
          phase: PermissionsPhase.unknown,
          message: 'Completion could not be verified. Check the original server; no ACL request will be replayed.',
        );
      }
    }
  }

  Future<void> checkProgress() async {
    final receipt = state.result;
    if (!state.canCheck || receipt == null || !_current(_generation)) return;
    final api = ref.read(permissionsSessionProvider);
    if (api == null) return;
    _timer?.cancel();
    final generation = _generation;
    state = _copy(phase: PermissionsPhase.checking);
    try {
      final result = await api.checkPermissionOperation(receipt);
      if (_current(generation)) _accept(result);
    } on Object {
      if (_current(generation)) {
        state = _copy(
          phase: PermissionsPhase.unknown,
          message: 'The existing job could not be checked. Its receipt is retained; the change was not resent.',
        );
      }
    }
  }

  void _accept(PermissionOperationResult result) {
    final phase = switch (result.outcome) {
      PermissionOperationOutcome.pending => PermissionsPhase.pending,
      PermissionOperationOutcome.verified => PermissionsPhase.verified,
      PermissionOperationOutcome.failed => PermissionsPhase.failed,
      PermissionOperationOutcome.unknown => PermissionsPhase.unknown,
    };
    state = _copy(
      phase: phase,
      result: result,
      message:
          result.message ??
          switch (phase) {
            PermissionsPhase.pending =>
              'The server accepted the job. Completion is not yet verified.',
            PermissionsPhase.verified =>
              'The server verified the resulting permissions.',
            PermissionsPhase.failed => 'The server did not complete this change. Reload current permissions before editing again.',
            _ => 'The outcome is unknown. Check the original server before another change.',
          },
    );
    if (state.pending && result.canCheck) {
      if (_polls++ < ref.read(permissionsAutoPollLimitProvider)) {
        _timer = Timer(const Duration(seconds: 2), checkProgress);
      } else {
        state = _copy(
          message: 'Automatic checking has paused. Use Check job to read its status; the ACL is not resent.',
        );
      }
    } else {
      _timer?.cancel();
      if (!state.unknown) {
        _release();
        ref.invalidate(permissionsDatasetsProvider);
      }
    }
  }

  /// Explicit acknowledgement, only after a different authenticated connection
  /// to the same origin. It clears local blocking, never declares job success.
  void acknowledgeAfterReconnect() {
    final session = ref.read(dashboardActiveSessionProvider);
    if (state.unknown &&
        !state.connectionCurrent &&
        session?.endpoint != null &&
        session?.endpoint == state.server &&
        !identical(session, _session)) {
      _release();
      _session = null;
      state = const PermissionsState(
        message: 'Prior completion remains unverified. Reload the current ACL before making any new change.',
      );
      ref.invalidate(permissionsDatasetsProvider);
    }
  }

  bool _current(int generation) =>
      ref.mounted &&
      generation == _generation &&
      identical(_session, ref.read(dashboardActiveSessionProvider));
  PermissionsState _copy({
    PermissionsPhase? phase,
    PermissionOperationResult? result,
    String? message,
    bool? connectionCurrent,
  }) => PermissionsState(
    phase: phase ?? state.phase,
    result: result ?? state.result,
    server: state.server,
    path: state.path,
    datasetId: state.datasetId,
    jobId: result?.jobId ?? state.jobId,
    message: message ?? state.message,
    connectionCurrent: connectionCurrent ?? state.connectionCurrent,
  );
  void _release() {
    if (_lockOwner != null) _lock?.release(_lockOwner!);
    _lockOwner = null;
  }
}
