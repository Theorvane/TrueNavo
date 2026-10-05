import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'directory_idmap_page.dart';

final directoryIdmapControllerProvider =
    NotifierProvider<DirectoryIdmapController, DirectoryIdmapState>(
      DirectoryIdmapController.new,
    );

final class DirectoryIdmapState {
  const DirectoryIdmapState({
    this.busy = false,
    this.review,
    this.result,
    this.message,
  });
  final bool busy;
  final DirectoryIdmapReview? review;
  final DirectoryIdmapResult? result;
  final String? message;
  bool get locked =>
      busy ||
      result?.outcome == DirectoryIdmapOutcome.pending ||
      result?.outcome == DirectoryIdmapOutcome.unknown;
}

class DirectoryIdmapController extends Notifier<DirectoryIdmapState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  bool _mutationStarted = false;
  String? _unresolvedEndpoint, _unresolvedHost;

  @override
  DirectoryIdmapState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      _session = null;
      final mightHaveMutated = _mutationStarted;
      state = mightHaveMutated
          ? const DirectoryIdmapState(
              result: DirectoryIdmapResult(
                DirectoryIdmapOutcome.unknown,
                'The connection changed during an ID mapping operation. Inspect the original server; do not repeat it.',
              ),
            )
          : const DirectoryIdmapState();
      if (!mightHaveMutated) {
        _unresolvedEndpoint = null;
        _unresolvedHost = null;
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const DirectoryIdmapState();
  }

  AuthenticatedDirectoryIdmapSession? _api(AuthenticatedSession? session) {
    final repo = session?.repository;
    return repo is AuthenticatedDirectoryIdmapSession
        ? repo as AuthenticatedDirectoryIdmapSession
        : null;
  }

  Future<void> review(DirectoryIdmapRangeDraft draft) async {
    final session = ref.read(dashboardActiveSessionProvider);
    final inventory = ref.read(directoryIdmapInventoryProvider).asData?.value;
    final api = _api(session);
    if (state.locked ||
        session == null ||
        inventory == null ||
        inventory.endpoint != session.endpoint ||
        draft.validateAgainst(inventory) != null ||
        api?.directoryIdmapCapabilities.canEdit != true) {
      state = const DirectoryIdmapState(
        message:
            'This ID mapping edit is not available for the current server.',
      );
      return;
    }
    final generation = ++_generation;
    state = const DirectoryIdmapState(busy: true);
    try {
      final review = await api!.reviewDirectoryIdmap(draft);
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
      state = DirectoryIdmapState(review: review);
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = const DirectoryIdmapState(
          message: 'ID mapping review failed or the server configuration changed. Reload before retrying.',
        );
      }
    }
  }

  Future<void> execute(String confirmation) async {
    final review = state.review, session = _session;
    final api = _api(session);
    if (review == null ||
        session == null ||
        api?.directoryIdmapCapabilities.canEdit != true ||
        !identical(session, ref.read(dashboardActiveSessionProvider)) ||
        confirmation != review.confirmation ||
        DateTime.now().toUtc().isAfter(review.expiresAt)) {
      state = const DirectoryIdmapState(
        message: 'The review expired or the connection changed. Nothing was submitted.',
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const DirectoryIdmapState(
        message: 'Another management operation is unresolved. Nothing was submitted.',
      );
      return;
    }
    final generation = ++_generation;
    _mutationStarted = true;
    _unresolvedEndpoint = review.inventory.endpoint;
    _unresolvedHost = review.inventory.hostId;
    state = const DirectoryIdmapState(busy: true);
    DirectoryIdmapResult result;
    try {
      result = await api!.executeDirectoryIdmap(review, confirmation);
    } on DirectoryIdmapException {
      result = const DirectoryIdmapResult(
        DirectoryIdmapOutcome.rejected,
        'The review was rejected before submission. Reload the server state.',
      );
    } on Object {
      result = const DirectoryIdmapResult(
        DirectoryIdmapOutcome.unknown,
        'The update outcome could not be confirmed. Inspect the original server; do not repeat it.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = DirectoryIdmapState(result: result);
    if (!state.locked) {
      _mutationStarted = false;
      _unresolvedEndpoint = null;
      _unresolvedHost = null;
      _release();
      ref.invalidate(directoryIdmapInventoryProvider);
    }
  }

  Future<void> poll() async {
    final result = state.result, session = _session;
    final job = result?.job, api = _api(session);
    if (job == null ||
        session == null ||
        api == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final generation = ++_generation;
    state = DirectoryIdmapState(busy: true, result: result);
    DirectoryIdmapResult next;
    try {
      next = await api.pollDirectoryIdmap(job);
    } on Object {
      next = DirectoryIdmapResult(
        DirectoryIdmapOutcome.unknown,
        'The owned job could not be verified. Inspect the original server.',
        job: job,
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = DirectoryIdmapState(result: next);
    if (!state.locked) {
      _mutationStarted = false;
      _unresolvedEndpoint = null;
      _unresolvedHost = null;
      _release();
      ref.invalidate(directoryIdmapInventoryProvider);
    }
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
    state = const DirectoryIdmapState(
      message: 'The prior update outcome remains unverified. Fresh ID mapping was loaded without replaying the request.',
    );
    ref.invalidate(directoryIdmapInventoryProvider);
  }

  void clearReview() {
    if (state.locked) return;
    state = const DirectoryIdmapState();
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _lock?.release(owner);
    _owner = null;
  }
}
