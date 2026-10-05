import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeHostHashCoordinatorProvider = Provider<NvmeHostHashCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession ||
      repository is! AuthenticatedNvmeHostHashSession ||
      repository is! AuthenticatedNvmeHostChoicesSession) {
    return null;
  }
  return NvmeHostHashCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    createApi: repository as AuthenticatedNvmeHostHashSession,
    choicesApi: repository as AuthenticatedNvmeHostChoicesSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

enum NvmeHostHashOutcome { completed, rejected, unknown }

final class NvmeHostHashResult {
  const NvmeHostHashResult(this.outcome, this.message);
  final NvmeHostHashOutcome outcome;
  final String message;
}

final class NvmeHostHashReview {
  NvmeHostHashReview._(
    this.endpoint,
    this.id,
    this.nqn,
    this.oldHash,
    this.hash,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, nqn, oldHash, hash, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'CHANGE NVME HOST $id HASH FROM $oldHash TO $hash';
}

/// Edits only the saved hash of an unassociated, uncredentialed host. Reads cannot exclude another
/// administrator's race or attest initiator identity, runtime access or auth.
final class NvmeHostHashCoordinator {
  NvmeHostHashCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.createApi,
    required this.choicesApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final AuthenticatedNvmeHostHashSession createApi;
  final AuthenticatedNvmeHostChoicesSession choicesApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmeHostHashReview>{};
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
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
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
    final NvmeUncredentialedHost protected;
    try {
      protected = await createApi.loadUncredentialedNvmeHost(id);
    } on Object {
      throw StateError('Protected host preflight failed. Nothing was sent.');
    }
    _guard();
    if (protected.id != id || protected.nqn != host.nqn) {
      throw StateError(
        'Protected and public host identity disagree. Nothing was sent.',
      );
    }
    return protected;
  }

  Future<void> _choices(String hash) async {
    final NvmeHostAuthenticationChoices choices;
    try {
      choices = await choicesApi.loadNvmeHostAuthenticationChoices();
    } on Object {
      throw StateError('Algorithm discovery failed. Nothing was sent.');
    }
    _guard();
    if (!choices.hashes.contains(hash)) {
      throw StateError(
        'The server does not advertise this hash. Nothing was sent.',
      );
    }
  }

  Future<NvmeHostHashReview> prepare(int id, String hash) async {
    _guard();
    if (!available ||
        _busy ||
        id <= 0 ||
        !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(hash)) {
      throw StateError(
        'Select a known hash and positive host database ID. Nothing was sent.',
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
      await _choices(hash);
      final target = await _target(value, id);
      if (target.hash == hash) {
        throw StateError("Hash is unchanged. Nothing was sent.");
      }
      final review = NvmeHostHashReview._(
        session.endpoint!,
        id,
        target.nqn,
        target.hash,
        hash,
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

  void cancel(NvmeHostHashReview review) => _issued.remove(review);
  Future<NvmeHostHashResult> execute(
    NvmeHostHashReview review,
    String confirmation, {
    bool acknowledgeHashChange = false,
  }) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        !acknowledgeHashChange ||
        _busy ||
        !isCurrent() ||
        !available ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmeHostHashResult(
        NvmeHostHashOutcome.rejected,
        'Review, authentication consent or confirmation is invalid. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeHostHashResult(
        NvmeHostHashOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      await _choices(review.hash);
      final target = await _target(before, review.id);
      if (before.proof() != review.proof ||
          target.nqn != review.nqn ||
          target.hash != review.oldHash) {
        return const NvmeHostHashResult(
          NvmeHostHashOutcome.rejected,
          'NVMe configuration changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final updated = await createApi.changeUncredentialedNvmeHostHash(
        id: review.id,
        expectedNqn: review.nqn,
        expectedHash: review.oldHash,
        newHash: review.hash,
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
          after.proof() != before.proof()) {
        return _unknown();
      }
      return NvmeHostHashResult(
        NvmeHostHashOutcome.completed,
        'Host #${review.id} has the reviewed hash in fresh reads with unchanged NQN, no subsystem mapping and keys still unset. This does not configure or prove authentication.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostHashResult(
              NvmeHostHashOutcome.rejected,
              'NVMe host preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeHostHashResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeHostHashResult(
      NvmeHostHashOutcome.unknown,
      'Host hash editing may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
