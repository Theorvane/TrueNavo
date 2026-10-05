import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'directory_idmap_page.dart';

final directoryLdapControllerProvider =
    NotifierProvider<DirectoryLdapController, DirectoryLdapState>(
      DirectoryLdapController.new,
    );

final class DirectoryLdapState {
  const DirectoryLdapState({
    this.busy = false,
    this.review,
    this.result,
    this.message,
  });
  final bool busy;
  final DirectoryLdapReview? review;
  final DirectoryLdapResult? result;
  final String? message;
  bool get locked =>
      busy ||
      result?.outcome == DirectoryIdmapOutcome.pending ||
      result?.outcome == DirectoryIdmapOutcome.unknown;
}

class DirectoryLdapController extends Notifier<DirectoryLdapState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  bool _mutationStarted = false;
  String? _unresolvedEndpoint, _unresolvedHost;

  @override
  DirectoryLdapState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      _session = null;
      state = _mutationStarted
          ? const DirectoryLdapState(
              result: DirectoryLdapResult(
                DirectoryIdmapOutcome.unknown,
                'Connection changed during the LDAP update. Inspect the original server; do not repeat it.',
              ),
            )
          : const DirectoryLdapState();
      if (!_mutationStarted) {
        _unresolvedEndpoint = null;
        _unresolvedHost = null;
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const DirectoryLdapState();
  }

  AuthenticatedDirectoryIdmapSession? _api(AuthenticatedSession? session) {
    final repo = session?.repository;
    return repo is AuthenticatedDirectoryIdmapSession
        ? repo as AuthenticatedDirectoryIdmapSession
        : null;
  }

  Future<void> review(DirectoryLdapDraft draft) async {
    final session = ref.read(dashboardActiveSessionProvider);
    final inventory = ref.read(directoryIdmapInventoryProvider).asData?.value;
    final api = _api(session);
    if (state.locked ||
        session == null ||
        inventory == null ||
        inventory.endpoint != session.endpoint ||
        draft.validateAgainst(inventory) != null ||
        api?.directoryIdmapCapabilities.canEdit != true) {
      state = const DirectoryLdapState(
        message: 'LDAP edit is unavailable for this server or proposal.',
      );
      return;
    }
    final generation = ++_generation;
    state = const DirectoryLdapState(busy: true);
    try {
      final reviewed = await api!.reviewDirectoryLdap(draft);
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
      state = DirectoryLdapState(review: reviewed);
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = const DirectoryLdapState(
          message: 'LDAP review failed. Only disabled anonymous LDAP with supported attribute maps and no auxiliary parameters is supported.',
        );
      }
    }
  }

  Future<void> execute(String confirmation) async {
    final reviewed = state.review, session = _session;
    final api = _api(session);
    if (reviewed == null ||
        session == null ||
        api?.directoryIdmapCapabilities.canEdit != true ||
        !identical(session, ref.read(dashboardActiveSessionProvider)) ||
        confirmation != reviewed.confirmation ||
        DateTime.now().toUtc().isAfter(reviewed.expiresAt)) {
      state = const DirectoryLdapState(
        message: 'Review expired or the server changed. Nothing was submitted.',
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const DirectoryLdapState(
        message: 'Another management operation is unresolved.',
      );
      return;
    }
    final generation = ++_generation;
    _mutationStarted = true;
    _unresolvedEndpoint = reviewed.inventory.endpoint;
    _unresolvedHost = reviewed.inventory.hostId;
    state = const DirectoryLdapState(busy: true);
    DirectoryLdapResult result;
    try {
      result = await api!.executeDirectoryLdap(reviewed, confirmation);
    } on DirectoryIdmapException {
      result = const DirectoryLdapResult(
        DirectoryIdmapOutcome.rejected,
        'Preflight rejected the edit before submission.',
      );
    } on Object {
      result = const DirectoryLdapResult(
        DirectoryIdmapOutcome.unknown,
        'Update outcome is unknown. Inspect the original server; do not resubmit.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = DirectoryLdapState(result: result);
    _settleIfResolved();
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
    state = DirectoryLdapState(busy: true, result: current);
    DirectoryLdapResult result;
    try {
      result = await api.pollDirectoryLdap(job);
    } on Object {
      result = DirectoryLdapResult(
        DirectoryIdmapOutcome.unknown,
        'Owned job could not be verified.',
        job: job,
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = DirectoryLdapState(result: result);
    _settleIfResolved();
  }

  void _settleIfResolved() {
    if (state.locked) {
      return;
    }
    _mutationStarted = false;
    _unresolvedEndpoint = null;
    _unresolvedHost = null;
    _release();
    ref.invalidate(directoryIdmapInventoryProvider);
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
    state = const DirectoryLdapState(
      message: 'Prior outcome remains unverified. Fresh LDAP data was loaded without replay.',
    );
    ref.invalidate(directoryIdmapInventoryProvider);
  }

  void clearReview() {
    if (!state.locked) state = const DirectoryLdapState();
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
