import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePortDeleteCoordinatorProvider = Provider<NvmePortDeleteCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession) {
    return null;
  }
  return NvmePortDeleteCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

enum NvmePortDeleteOutcome { completed, rejected, unknown }

final class NvmePortDeleteResult {
  const NvmePortDeleteResult(this.outcome, this.message);
  final NvmePortDeleteOutcome outcome;
  final String message;
}

final class NvmePortDeleteReview {
  NvmePortDeleteReview._({
    required this.endpoint,
    required this.id,
    required this.transport,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, transport, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'DELETE DISABLED NVME PORT $id $transport';
}

/// Never force-deletes a port or deletes one that is enabled or associated.
/// These separate reads cannot exclude a concurrent administrator's race.
final class NvmePortDeleteCoordinator {
  NvmePortDeleteCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmePortDeleteReview>{};
  bool _busy = false;

  bool get locked => _busy || NvmeWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('nvmet.host.query') != null &&
      api.adminCatalog.method('nvmet.host_subsys.query')?.supported == true &&
      [
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.port.delete',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  void _guard() {
    if (!isCurrent() || session.endpoint == null) {
      throw StateError('The server connection changed.');
    }
    if (NvmeWriteFence.isUncertain(session)) {
      throw StateError(
        'An NVMe-oF change is unverified. Reconnect before editing.',
      );
    }
  }

  Future<NvmeMutationSnapshot> _snapshot() async {
    final snapshot = await NvmeMutationSnapshot.load(
      api: api,
      hostsApi: hostsApi,
      isCurrent: () => isCurrent() && session.endpoint != null,
    );
    _guard();
    return snapshot;
  }

  NvmePort _target(NvmeMutationSnapshot snapshot, int id) {
    final port = snapshot.topology.ports.where((p) => p.id == id).singleOrNull;
    if (port == null ||
        port.enabled ||
        snapshot.topology.portMappings.any((m) => m.portId == id)) {
      throw StateError(
        'Only an existing disabled port without subsystem associations can be deleted. Nothing was sent.',
      );
    }
    return port;
  }

  Future<NvmePortDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id <= 0) {
      throw StateError(
        'Select a positive port ID on a supported server. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final before = await _snapshot();
      final port = _target(before, id);
      final review = NvmePortDeleteReview._(
        endpoint: session.endpoint!,
        id: port.id,
        transport: port.transport,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF port delete preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmePortDeleteReview review) => _issued.remove(review);

  Future<NvmePortDeleteResult> execute(
    NvmePortDeleteReview review,
    String confirmation,
  ) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        _busy ||
        !isCurrent() ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmePortDeleteResult(
        NvmePortDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmePortDeleteResult(
        NvmePortDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final port = _target(before, review.id);
      if (port.transport != review.transport ||
          before.proof() != review.proof) {
        return const NvmePortDeleteResult(
          NvmePortDeleteOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.port.delete');
      if (method == null || !method.supported) {
        return const NvmePortDeleteResult(
          NvmePortDeleteOutcome.rejected,
          'Port delete method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'force': false},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmePortDeleteResult(
          NvmePortDeleteOutcome.rejected,
          'The server denied port deletion. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value != true) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.topology.ports.any((p) => p.id == review.id) ||
          after.topology.ports.length != before.topology.ports.length - 1 ||
          after.proof() != before.proof(omitPortId: review.id)) {
        return _unknown();
      }
      return NvmePortDeleteResult(
        NvmePortDeleteOutcome.completed,
        'Disabled unassociated port #${review.id} is absent in a fresh read. Client activity was not measured.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmePortDeleteResult(
              NvmePortDeleteOutcome.rejected,
              'NVMe-oF port delete preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePortDeleteResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePortDeleteResult(
      NvmePortDeleteOutcome.unknown,
      'Port deletion may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
