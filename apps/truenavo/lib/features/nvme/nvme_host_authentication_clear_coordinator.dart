import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeHostAuthenticationClearCoordinatorProvider =
    Provider<NvmeHostAuthenticationClearCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession ||
          repository is! AuthenticatedNvmeHostAuthenticationClearSession) {
        return null;
      }
      return NvmeHostAuthenticationClearCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        clearApi: repository as AuthenticatedNvmeHostAuthenticationClearSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmeHostAuthenticationClearOutcome { completed, rejected, unknown }

final class NvmeHostAuthenticationClearResult {
  const NvmeHostAuthenticationClearResult(this.outcome, this.message);
  final NvmeHostAuthenticationClearOutcome outcome;
  final String message;
}

final class NvmeHostAuthenticationClearReview {
  NvmeHostAuthenticationClearReview._(
    this.endpoint,
    this.target,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, proof;
  final NvmeHostAuthentication target;
  final DateTime issuedAt;
  int get id => target.id;
  String get nqn => target.nqn;
  String get confirmation => 'CLEAR NVME HOST $id AUTHENTICATION';
}

/// Clears current authentication settings only for an unassociated host.
/// Returned flags do not identify secret values; rotations with unchanged
/// flags cannot be detected. Sequential reads cannot exclude other admins.
final class NvmeHostAuthenticationClearCoordinator {
  NvmeHostAuthenticationClearCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.clearApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final AuthenticatedNvmeHostAuthenticationClearSession clearApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmeHostAuthenticationClearReview>{};
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
    final NvmeMutationSnapshot value;
    try {
      value = await NvmeMutationSnapshot.load(
        api: api,
        hostsApi: hostsApi,
        isCurrent: isCurrent,
      );
    } on Object {
      throw StateError('NVMe inventory preflight failed. Nothing was sent.');
    }
    _guard();
    return value;
  }

  Future<NvmeHostAuthentication> _target(
    NvmeMutationSnapshot value,
    int id,
  ) async {
    final host = value.hosts.hosts.where((h) => h.id == id).singleOrNull;
    if (host == null || value.hosts.mappings.any((m) => m.hostId == id)) {
      throw StateError(
        'Select an existing host database ID without subsystem mappings. Nothing was sent.',
      );
    }
    final NvmeHostAuthentication protected;
    try {
      protected = await clearApi.loadNvmeHostAuthenticationTarget(id);
    } on Object {
      throw StateError('Protected host preflight failed. Nothing was sent.');
    }
    _guard();
    if (protected.id != id ||
        protected.nqn != host.nqn ||
        !isSupportedNvmeHostNqn(protected.nqn)) {
      throw StateError(
        'Protected and public host identity disagree. Nothing was sent.',
      );
    }
    return protected;
  }

  Future<NvmeHostAuthenticationClearReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id <= 0) {
      throw StateError('Select a positive host database ID. Nothing was sent.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final value = await _snapshot();
      final target = await _target(value, id);
      if (!target.hasReturnedAuthentication) {
        throw StateError(
          "No authentication fields are returned configured. Nothing was sent.",
        );
      }
      final review = NvmeHostAuthenticationClearReview._(
        session.endpoint!,
        target,
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

  void cancel(NvmeHostAuthenticationClearReview review) =>
      _issued.remove(review);
  Future<NvmeHostAuthenticationClearResult> execute(
    NvmeHostAuthenticationClearReview review,
    String confirmation, {
    bool acknowledgeCredentialLoss = false,
  }) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        !acknowledgeCredentialLoss ||
        _busy ||
        !isCurrent() ||
        !available ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmeHostAuthenticationClearResult(
        NvmeHostAuthenticationClearOutcome.rejected,
        'Review, authentication consent or confirmation is invalid. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeHostAuthenticationClearResult(
        NvmeHostAuthenticationClearOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final target = await _target(before, review.id);
      if (before.proof() != review.proof ||
          !target.sameReturnedSettings(review.target)) {
        return const NvmeHostAuthenticationClearResult(
          NvmeHostAuthenticationClearOutcome.rejected,
          'NVMe configuration changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final updated = await clearApi.clearNvmeHostAuthentication(
        expected: review.target,
      );
      if (updated.id != review.id ||
          updated.nqn != review.nqn ||
          updated.hash != review.target.hash ||
          updated.hasReturnedAuthentication) {
        return _unknown();
      }
      final after = await _snapshot();
      final refreshed = await _target(after, review.id);
      if (refreshed.hash != review.target.hash ||
          refreshed.nqn != review.nqn ||
          refreshed.hasReturnedAuthentication) {
        return _unknown();
      }
      if (after.hosts.hosts.length != before.hosts.hosts.length ||
          after.hosts.hosts
                  .where((h) => h.id == review.id && h.nqn == review.nqn)
                  .length !=
              1 ||
          after.hosts.mappings.any((m) => m.hostId == review.id) ||
          after.proof() != before.proof()) {
        return _unknown();
      }
      return NvmeHostAuthenticationClearResult(
        NvmeHostAuthenticationClearOutcome.completed,
        'Host #${review.id} now returns both keys and DH group unset, with unchanged NQN and hash and no subsystem mapping. Key recovery and runtime authentication were not verified.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostAuthenticationClearResult(
              NvmeHostAuthenticationClearOutcome.rejected,
              'NVMe host preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeHostAuthenticationClearResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeHostAuthenticationClearResult(
      NvmeHostAuthenticationClearOutcome.unknown,
      'Authentication clearing may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
