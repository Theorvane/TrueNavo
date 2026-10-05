import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeHostCreateCoordinatorProvider = Provider<NvmeHostCreateCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession ||
      repository is! AuthenticatedNvmeHostCreateSession) {
    return null;
  }
  return NvmeHostCreateCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    createApi: repository as AuthenticatedNvmeHostCreateSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

enum NvmeHostCreateOutcome { completed, rejected, unknown }

final class NvmeHostCreateResult {
  const NvmeHostCreateResult(this.outcome, this.message);
  final NvmeHostCreateOutcome outcome;
  final String message;
}

final class NvmeHostCreateReview {
  NvmeHostCreateReview._(this.endpoint, this.nqn, this.proof, this.issuedAt);
  final String endpoint, nqn, proof;
  final DateTime issuedAt;
  String get confirmation =>
      'REGISTER UNASSOCIATED NVME HOST $nqn WITHOUT DHCHAP';
}

/// Registers an identity only. Sequential reads cannot exclude another
/// administrator's race or attest initiator identity, runtime access or auth.
final class NvmeHostCreateCoordinator {
  NvmeHostCreateCoordinator({
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
  final AuthenticatedNvmeHostCreateSession createApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmeHostCreateReview>{};
  bool _busy = false;
  bool get locked => _busy || NvmeWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      // Generic host.create intentionally remains blocked: its response has keys.
      api.adminCatalog.method('nvmet.host.create') != null &&
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

  void _validate(NvmeMutationSnapshot value, String nqn) {
    if (value.hosts.hosts.length >= 99 ||
        value.hosts.hosts.any(
          (h) => h.nqn.toLowerCase() == nqn.toLowerCase(),
        )) {
      throw StateError(
        'NQN already exists or the bounded host inventory cannot verify another create. Nothing was sent.',
      );
    }
  }

  Future<NvmeHostCreateReview> prepare(String nqn) async {
    _guard();
    if (!available || _busy || !isSupportedNvmeHostNqn(nqn)) {
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
      _validate(value, nqn);
      final review = NvmeHostCreateReview._(
        session.endpoint!,
        nqn,
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

  void cancel(NvmeHostCreateReview review) => _issued.remove(review);
  Future<NvmeHostCreateResult> execute(
    NvmeHostCreateReview review,
    String confirmation, {
    bool acknowledgeNoDhchap = false,
  }) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        !acknowledgeNoDhchap ||
        _busy ||
        !isCurrent() ||
        !available ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmeHostCreateResult(
        NvmeHostCreateOutcome.rejected,
        'Review, authentication consent or confirmation is invalid. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeHostCreateResult(
        NvmeHostCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _validate(before, review.nqn);
      if (before.proof() != review.proof) {
        return const NvmeHostCreateResult(
          NvmeHostCreateOutcome.rejected,
          'NVMe configuration changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final created = await createApi.createUnassociatedNvmeHost(
        hostNqn: review.nqn,
      );
      if (created.id <= 0 ||
          created.nqn != review.nqn ||
          before.hosts.hosts.any((h) => h.id == created.id)) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.hosts.hosts.length != before.hosts.hosts.length + 1 ||
          after.hosts.hosts
                  .where((h) => h.id == created.id && h.nqn == review.nqn)
                  .length !=
              1 ||
          after.hosts.mappings.any((m) => m.hostId == created.id) ||
          after.proof(omitHostId: created.id) != before.proof()) {
        return _unknown();
      }
      return NvmeHostCreateResult(
        NvmeHostCreateOutcome.completed,
        'Host #${created.id} was found in fresh reads without a subsystem association. DH-CHAP was not configured; initiator identity, runtime authentication and client access were not verified.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostCreateResult(
              NvmeHostCreateOutcome.rejected,
              'NVMe host preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeHostCreateResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeHostCreateResult(
      NvmeHostCreateOutcome.unknown,
      'Host registration may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
