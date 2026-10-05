import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePortAccessGrantCoordinatorProvider =
    Provider<NvmePortAccessGrantCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession ||
          repository is! AuthenticatedNvmePortAccessSession) {
        return null;
      }
      return NvmePortAccessGrantCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        accessApi: repository as AuthenticatedNvmePortAccessSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmePortGrantOutcome { completed, rejected, unknown }

final class NvmePortGrantResult {
  const NvmePortGrantResult(this.outcome, this.message);
  final NvmePortGrantOutcome outcome;
  final String message;
}

final class NvmePortGrantReview {
  NvmePortGrantReview._({
    required this.endpoint,
    required this.portId,
    required this.transport,
    required this.subsystemId,
    required this.subsystemName,
    required this.subnqn,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, transport, subsystemName, subnqn, proof;
  final int portId, subsystemId;
  final DateTime issuedAt;
  String get confirmation => 'MAP NVME PORT $portId TO SUBSYSTEM $subsystemId';
}

/// Only binds an empty, host-restricted subsystem to an unused disabled port.
/// Sequential reads cannot exclude a concurrent administrator enabling the
/// port or attaching backing storage before or during this write.
final class NvmePortAccessGrantCoordinator {
  NvmePortAccessGrantCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.accessApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final AuthenticatedNvmePortAccessSession accessApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmePortGrantReview>{};
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
        'nvmet.port_subsys.create',
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

  (NvmePort, NvmeSubsystem) _target(
    NvmeMutationSnapshot snapshot,
    int portId,
    int subsystemId,
  ) {
    final port = snapshot.topology.ports
        .where((p) => p.id == portId)
        .singleOrNull;
    final subsystem = snapshot.topology.subsystems
        .where((s) => s.id == subsystemId)
        .singleOrNull;
    if (port == null ||
        port.enabled ||
        subsystem == null ||
        subsystem.allowAnyHost ||
        subsystem.subnqn == null ||
        snapshot.topology.namespaces.any((n) => n.subsystemId == subsystemId) ||
        snapshot.topology.portMappings.any(
          (m) => m.portId == portId || m.subsystemId == subsystemId,
        ) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == subsystemId) ||
        snapshot.topology.portMappings.length >= 100) {
      throw StateError(
        'Mapping requires an unused disabled port and a restricted subsystem with a returned NQN, no namespace, host grant or existing port association. Nothing was sent.',
      );
    }
    return (port, subsystem);
  }

  Future<NvmePortGrantReview> prepare(int portId, int subsystemId) async {
    _guard();
    if (!available || _busy || portId <= 0 || subsystemId <= 0) {
      throw StateError(
        'Select positive port and subsystem IDs on a supported server. Nothing was sent.',
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
      final (port, subsystem) = _target(before, portId, subsystemId);
      final review = NvmePortGrantReview._(
        endpoint: session.endpoint!,
        portId: port.id,
        transport: port.transport,
        subsystemId: subsystem.id,
        subsystemName: subsystem.name,
        subnqn: subsystem.subnqn!,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF port mapping preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmePortGrantReview review) => _issued.remove(review);

  Future<NvmePortGrantResult> execute(
    NvmePortGrantReview review,
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
      return const NvmePortGrantResult(
        NvmePortGrantOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmePortGrantResult(
        NvmePortGrantOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final (port, subsystem) = _target(
        before,
        review.portId,
        review.subsystemId,
      );
      if (port.transport != review.transport ||
          subsystem.name != review.subsystemName ||
          subsystem.subnqn != review.subnqn ||
          before.proof() != review.proof) {
        return const NvmePortGrantResult(
          NvmePortGrantOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final created = await accessApi.createNvmePortAssociation(
        portId: review.portId,
        subsystemId: review.subsystemId,
      );
      if (created.id <= 0 ||
          created.portId != review.portId ||
          created.subsystemId != review.subsystemId) {
        return _unknown();
      }
      final after = await _snapshot();
      final matches = after.topology.portMappings.where(
        (m) => m.id == created.id,
      );
      if (matches.length != 1 ||
          matches.single.portId != review.portId ||
          matches.single.subsystemId != review.subsystemId ||
          after.topology.portMappings.length !=
              before.topology.portMappings.length + 1 ||
          after.proof(omitPortMappingId: created.id) != before.proof()) {
        return _unknown();
      }
      return NvmePortGrantResult(
        NvmePortGrantOutcome.completed,
        'Port association #${created.id} was found in a fresh read. The port remains configured disabled and the subsystem has no returned namespace or host grant; client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmePortGrantResult(
              NvmePortGrantOutcome.rejected,
              'NVMe-oF port mapping preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePortGrantResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePortGrantResult(
      NvmePortGrantOutcome.unknown,
      'Port mapping may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
