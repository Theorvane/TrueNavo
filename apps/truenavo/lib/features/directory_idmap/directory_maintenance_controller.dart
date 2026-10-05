import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'directory_idmap_page.dart';

final directoryMaintenanceControllerProvider =
    NotifierProvider<DirectoryMaintenanceController, DirectoryMaintenanceState>(
      DirectoryMaintenanceController.new,
    );

final class DirectoryMaintenanceState {
  const DirectoryMaintenanceState({
    this.busy = false,
    this.review,
    this.result,
    this.message,
  });
  final bool busy;
  final DirectoryMaintenanceReview? review;
  final DirectoryMaintenanceResult? result;
  final String? message;
  bool get locked =>
      busy ||
      result?.outcome == DirectoryIdmapOutcome.pending ||
      result?.outcome == DirectoryIdmapOutcome.unknown;
}

class DirectoryMaintenanceController
    extends Notifier<DirectoryMaintenanceState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  bool _mutationStarted = false;
  String? _unresolvedEndpoint, _unresolvedHost;

  @override
  DirectoryMaintenanceState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      _session = null;
      state = _mutationStarted
          ? const DirectoryMaintenanceState(
              result: DirectoryMaintenanceResult(
                DirectoryIdmapOutcome.unknown,
                'Connection changed during a directory operation. Inspect the original server job; do not repeat it.',
              ),
            )
          : const DirectoryMaintenanceState();
      if (!_mutationStarted) {
        _unresolvedEndpoint = null;
        _unresolvedHost = null;
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const DirectoryMaintenanceState();
  }

  AuthenticatedDirectoryIdmapSession? _api(AuthenticatedSession? session) {
    final repo = session?.repository;
    return repo is AuthenticatedDirectoryIdmapSession
        ? repo as AuthenticatedDirectoryIdmapSession
        : null;
  }

  Future<void> review(DirectoryMaintenanceAction action) async {
    final session = ref.read(dashboardActiveSessionProvider);
    final inventory = ref.read(directoryIdmapInventoryProvider).asData?.value;
    final api = _api(session);
    if (state.locked ||
        session == null ||
        inventory == null ||
        inventory.endpoint != session.endpoint ||
        !inventory.enabled ||
        inventory.status != 'HEALTHY' ||
        (action == DirectoryMaintenanceAction.refreshCache
            ? api?.directoryIdmapCapabilities.canRefreshCache != true
            : api?.directoryIdmapCapabilities.canSyncKeytab != true ||
                  inventory.serviceType != 'ACTIVEDIRECTORY')) {
      state = const DirectoryMaintenanceState(
        message: 'Directory operation is unavailable for this server.',
      );
      return;
    }
    final generation = ++_generation;
    state = const DirectoryMaintenanceState(busy: true);
    try {
      final review = action == DirectoryMaintenanceAction.refreshCache
          ? await api!.reviewDirectoryCacheRefresh()
          : await api!.reviewDirectoryKeytabSync();
      if (!ref.mounted ||
          generation != _generation ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            inventory,
            ref.read(directoryIdmapInventoryProvider).asData?.value,
          )) {
        return;
      }
      _session = session;
      state = DirectoryMaintenanceState(review: review);
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = const DirectoryMaintenanceState(
          message:
              'Directory operation review failed. Reload the directory status.',
        );
      }
    }
  }

  Future<void> execute(String confirmation) async {
    final review = state.review, session = _session;
    final api = _api(session);
    if (review == null ||
        session == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider)) ||
        (review.action == DirectoryMaintenanceAction.refreshCache
            ? api?.directoryIdmapCapabilities.canRefreshCache != true
            : api?.directoryIdmapCapabilities.canSyncKeytab != true) ||
        confirmation != review.confirmation ||
        DateTime.now().toUtc().isAfter(review.expiresAt)) {
      state = const DirectoryMaintenanceState(
        message: 'Review expired or connection changed; nothing was submitted.',
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const DirectoryMaintenanceState(
        message: 'Another management operation is unresolved.',
      );
      return;
    }
    final generation = ++_generation;
    _mutationStarted = true;
    _unresolvedEndpoint = review.inventory.endpoint;
    _unresolvedHost = review.inventory.hostId;
    state = const DirectoryMaintenanceState(busy: true);
    DirectoryMaintenanceResult result;
    try {
      result = review.action == DirectoryMaintenanceAction.refreshCache
          ? await api!.executeDirectoryCacheRefresh(review, confirmation)
          : await api!.executeDirectoryKeytabSync(review, confirmation);
    } on DirectoryIdmapException {
      result = const DirectoryMaintenanceResult(
        DirectoryIdmapOutcome.rejected,
        'Preflight rejected; no directory operation was submitted.',
      );
    } on Object {
      result = const DirectoryMaintenanceResult(
        DirectoryIdmapOutcome.unknown,
        'Submission outcome is unknown. Inspect the original server.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = DirectoryMaintenanceState(result: result);
    _settleIfCertain();
  }

  Future<void> poll() async {
    final current = state.result, session = _session;
    final job = current?.job, api = _api(session);
    if (job == null ||
        session == null ||
        api == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final generation = ++_generation;
    state = DirectoryMaintenanceState(busy: true, result: current);
    DirectoryMaintenanceResult result;
    try {
      result = job.action == DirectoryMaintenanceAction.refreshCache
          ? await api.pollDirectoryCacheRefresh(job)
          : await api.pollDirectoryKeytabSync(job);
    } on Object {
      result = DirectoryMaintenanceResult(
        DirectoryIdmapOutcome.unknown,
        'Owned directory job could not be verified.',
        job: job,
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = DirectoryMaintenanceState(result: result);
    _settleIfCertain();
  }

  bool get canAcknowledgeAfterReconnect {
    if (!_mutationStarted ||
        _session != null ||
        state.result?.outcome != DirectoryIdmapOutcome.unknown) {
      return false;
    }
    final session = ref.read(dashboardActiveSessionProvider);
    final inventory = ref.read(directoryIdmapInventoryProvider).asData?.value;
    return session != null &&
        session.endpoint == _unresolvedEndpoint &&
        inventory != null &&
        inventory.endpoint == _unresolvedEndpoint &&
        inventory.hostId == _unresolvedHost &&
        _api(session)?.directoryIdmapCapabilities.canRead == true;
  }

  void acknowledgeAfterReconnect() {
    if (!canAcknowledgeAfterReconnect) return;
    _mutationStarted = false;
    _unresolvedEndpoint = null;
    _unresolvedHost = null;
    state = const DirectoryMaintenanceState(
      message: 'Prior job remains unverified. Fresh directory status was loaded without replay.',
    );
    ref.invalidate(directoryIdmapInventoryProvider);
  }

  void clearReview() {
    if (!state.locked) state = const DirectoryMaintenanceState();
  }

  void _settleIfCertain() {
    if (state.locked) return;
    _mutationStarted = false;
    _unresolvedEndpoint = null;
    _unresolvedHost = null;
    _release();
    ref.invalidate(directoryIdmapInventoryProvider);
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _lock?.release(owner);
    _owner = null;
  }
}
