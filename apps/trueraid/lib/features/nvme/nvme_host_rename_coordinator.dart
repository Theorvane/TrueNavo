import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeHostRenameCoordinatorProvider = Provider<NvmeHostRenameCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession ||
      repository is! AuthenticatedNvmeHostRenameSession) {
    return null;
  }
  return NvmeHostRenameCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    createApi: repository as AuthenticatedNvmeHostRenameSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

enum NvmeHostRenameOutcome { completed, rejected, unknown }

final class NvmeHostRenameResult {
  const NvmeHostRenameResult(this.outcome, this.message);
  final NvmeHostRenameOutcome outcome;
  final String message;
}

final class NvmeHostRenameReview {
  NvmeHostRenameReview._(
    this.endpoint,
    this.id,
    this.oldNqn,
    this.nqn,
    this.hash,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, oldNqn, nqn, hash, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'RENAME NVME HOST $id FROM $oldNqn TO $nqn';
}

/// Edits only an unassociated, uncredentialed host NQN. Reads cannot exclude another
/// administrator's race or attest initiator identity, runtime access or auth.
final class NvmeHostRenameCoordinator {
  NvmeHostRenameCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.createApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final AuthenticatedNvmeHostRenameSession createApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmeHostRenameReview>{};
  bool _busy = false;
  bool get locked => _busy || NvmeWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      // Generic host.update intentionally remains blocked: its response has keys.
      api.adminCatalog.method('nvmet.host.update') != null &&
      api.adminCatalog.method('nvmet.host.query') != null &&
      [
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.host_subsys.query',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void _guard() {
    if (!isCurrent() ||
        session.endpoint == null ||
        NvmeWriteFence.isUncertain(session)) {
      throw StateError(
        'Connection changed or an NVMe-oF change is unverified. Nothing was sent.',
      );
    }
  }

  Future<NvmeMutationSnapshot> _snapshot() async {
    final value = await NvmeMutationSnapshot.load(
      api: api,
      hostsApi: hostsApi,
      isCurrent: isCurrent,
    );
    _guard();
    return value;
  }

  Future<NvmeUncredentialedHost> _target(
    NvmeMutationSnapshot value,
    int id,
  ) async {
    final host = value.hosts.hosts.where((h) => h.id == id).singleOrNull;
    if (host == null || value.hosts.mappings.any((m) => m.hostId == id)) {
      throw StateError(
        'Select an existing host database ID without subsystem mappings. Nothing was sent.',
      );
    }
    final protected = await createApi.loadUncredentialedNvmeHost(id);
    _guard();
    if (protected.id != id || protected.nqn != host.nqn) {
      throw StateError(
        'Protected and public host identity disagree. Nothing was sent.',
      );
    }
    return protected;
  }

  void _validate(NvmeMutationSnapshot value, int id, String nqn) {
    if (value.hosts.hosts.any(
      (h) => h.id != id && h.nqn.toLowerCase() == nqn.toLowerCase(),
    )) {
      throw StateError('NQN already exists. Nothing was sent.');
    }
  }

  Future<NvmeHostRenameReview> prepare(int id, String nqn) async {
    _guard();
    if (!available || _busy || id <= 0 || !isSupportedNvmeHostNqn(nqn)) {
      throw StateError(
        'Enter an exact printable ASCII NQN starting with nqn., 11–223 characters. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final value = await _snapshot();
      _validate(value, id, nqn);
      final target = await _target(value, id);
      if (target.nqn == nqn) {
        throw StateError("NQN is unchanged. Nothing was sent.");
      }
      final review = NvmeHostRenameReview._(
        session.endpoint!,
        id,
        target.nqn,
        nqn,
        target.hash,
        value.proof(),
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe host preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeHostRenameReview review) => _issued.remove(review);
  Future<NvmeHostRenameResult> execute(
    NvmeHostRenameReview review,
    String confirmation, {
    bool acknowledgeIdentityChange = false,
  }) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        !acknowledgeIdentityChange ||
        _busy ||
        !isCurrent() ||
        !available ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmeHostRenameResult(
        NvmeHostRenameOutcome.rejected,
        'Review, authentication consent or confirmation is invalid. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeHostRenameResult(
        NvmeHostRenameOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _validate(before, review.id, review.nqn);
      final target = await _target(before, review.id);
      if (before.proof() != review.proof ||
          target.nqn != review.oldNqn ||
          target.hash != review.hash) {
        return const NvmeHostRenameResult(
          NvmeHostRenameOutcome.rejected,
          'NVMe configuration changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final updated = await createApi.renameUncredentialedNvmeHost(
        id: review.id,
        expectedNqn: review.oldNqn,
        expectedHash: review.hash,
        newNqn: review.nqn,
      );
      if (updated.id != review.id ||
          updated.nqn != review.nqn ||
          updated.hash != review.hash) {
        return _unknown();
      }
      final after = await _snapshot();
      final refreshed = await _target(after, review.id);
      if (refreshed.hash != review.hash || refreshed.nqn != review.nqn) {
        return _unknown();
      }
      if (after.hosts.hosts.length != before.hosts.hosts.length ||
          after.hosts.hosts
                  .where((h) => h.id == review.id && h.nqn == review.nqn)
                  .length !=
              1 ||
          after.hosts.mappings.any((m) => m.hostId == review.id) ||
          after.proof(omitHostId: review.id) !=
              before.proof(omitHostId: review.id)) {
        return _unknown();
      }
      return NvmeHostRenameResult(
        NvmeHostRenameOutcome.completed,
        'Host #${review.id} has the reviewed NQN in fresh reads with no subsystem mapping and authentication keys still unset. Initiator identity, runtime authentication and client access were not verified.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostRenameResult(
              NvmeHostRenameOutcome.rejected,
              'NVMe host preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeHostRenameResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeHostRenameResult(
      NvmeHostRenameOutcome.unknown,
      'Host NQN editing may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
