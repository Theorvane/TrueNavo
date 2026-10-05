import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePopulatedPortMappingCoordinatorProvider =
    Provider.autoDispose<NvmePopulatedPortMappingCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession ||
          api is! AuthenticatedNvmePortAccessSession) {
        return null;
      }
      final coordinator = NvmePopulatedPortMappingCoordinator(
        session: session!,
        api: api as AuthenticatedAdminSession,
        hostsApi: api as AuthenticatedNvmeHostSession,
        accessApi: api as AuthenticatedNvmePortAccessSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            ref.mounted &&
            identical(session, ref.read(dashboardActiveSessionProvider)),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

enum NvmePopulatedPortMappingOutcome { completed, rejected, unknown }

final class NvmePopulatedPortMappingResult {
  const NvmePopulatedPortMappingResult(this.outcome, this.message);
  final NvmePopulatedPortMappingOutcome outcome;
  final String message;
}

final class NvmePopulatedPortMappingReview {
  NvmePopulatedPortMappingReview._(
    this.endpoint,
    this.port,
    this.target,
    this.namespaces,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmePort port;
  final NvmeSubsystem target;
  final List<NvmeNamespace> namespaces;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'MAP DISABLED NVME PORT ${port.id} TO POPULATED SUBSYSTEM ${target.id} KEEP NQN ${target.subnqn}';
}

/// Creates only a saved association. Disabled flags and absent host grants are
/// public configuration observations, not runtime access or backing attestations.
final class NvmePopulatedPortMappingCoordinator {
  NvmePopulatedPortMappingCoordinator({
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
  final _issued = <NvmePopulatedPortMappingReview>{};
  bool _busy = false, _closed = false;
  bool get locked => _busy || _closed || NvmeWriteFence.isUncertain(session);
  bool get available =>
      !_closed &&
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('nvmet.host.query') != null &&
      [
        'nvmet.host_subsys.query',
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.port_subsys.create',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void dispose() {
    _closed = true;
    _issued.clear();
  }

  void cancel(NvmePopulatedPortMappingReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Populated port mapping is unavailable.');
    }
  }

  bool _fresh(NvmePopulatedPortMappingReview review) {
    final age = _now().toUtc().difference(review.issuedAt);
    return !age.isNegative && age < const Duration(minutes: 5);
  }

  Future<NvmeMutationSnapshot> _snapshot() async {
    final value = await NvmeMutationSnapshot.load(
      api: api,
      hostsApi: hostsApi,
      isCurrent: () => !_closed && isCurrent(),
    );
    _guard();
    return value;
  }

  (NvmePort, NvmeSubsystem) _target(
    NvmeMutationSnapshot snapshot,
    int portId,
    int subsystemId,
  ) {
    final port = snapshot.topology.ports
        .where((p) => p.id == portId)
        .singleOrNull;
    final target = snapshot.topology.subsystems
        .where((s) => s.id == subsystemId)
        .singleOrNull;
    final residents = snapshot.topology.namespaces
        .where((n) => n.subsystemId == subsystemId)
        .toList();
    final nsids = residents.map((n) => n.nsid).toList();
    if (port == null ||
        port.enabled ||
        !const {'TCP', 'RDMA'}.contains(port.transport) ||
        target == null ||
        target.allowAnyHost ||
        target.subnqn == null ||
        residents.isEmpty ||
        residents.any(
          (n) => n.deviceType != 'ZVOL' || n.enabled || n.locked != false,
        ) ||
        nsids.any((n) => n == null || n <= 0 || n >= 4294967295) ||
        nsids.toSet().length != nsids.length ||
        snapshot.topology.portMappings.any(
          (m) => m.portId == portId || m.subsystemId == subsystemId,
        ) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == subsystemId) ||
        snapshot.topology.portMappings.length >= 100) {
      throw StateError(
        'Select an unused disabled TCP/RDMA port and isolated restricted subsystem containing only disabled unlocked ZVOLs with known unique NSIDs.',
      );
    }
    return (port, target);
  }

  Future<NvmePopulatedPortMappingReview> prepare(
    int portId,
    int subsystemId,
  ) async {
    _guard();
    if (_busy || portId <= 0 || subsystemId <= 0) {
      throw StateError('Select exact positive port and subsystem IDs.');
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final (port, target) = _target(snapshot, portId, subsystemId);
      final review = NvmePopulatedPortMappingReview._(
        session.endpoint!,
        port,
        target,
        List.unmodifiable(
          snapshot.topology.namespaces
              .where((n) => n.subsystemId == subsystemId)
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id)),
        ),
        snapshot.proof(),
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on Object {
      throw StateError(
        'Populated port mapping review failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmePopulatedPortMappingResult> execute(
    NvmePopulatedPortMappingReview review,
    String phrase, {
    required bool acknowledgeReload,
    required bool acknowledgeLimitations,
    required bool acknowledgeExposure,
  }) async {
    final issued = _issued.remove(review);
    if (!issued ||
        locked ||
        !available ||
        !isCurrent() ||
        !_fresh(review) ||
        review.endpoint != session.endpoint ||
        phrase != review.confirmation ||
        !acknowledgeReload ||
        !acknowledgeLimitations ||
        !acknowledgeExposure) {
      return _rejected();
    }
    final owner = lock.acquire();
    if (owner == null) return _rejected();
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _target(before, review.port.id, review.target.id);
      if (before.proof() != review._proof || !_fresh(review)) {
        return _rejected();
      }
      _guard();
      sent = true;
      final created = await accessApi.createNvmePortAssociation(
        portId: review.port.id,
        subsystemId: review.target.id,
      );
      if (created.id <= 0 ||
          created.portId != review.port.id ||
          created.subsystemId != review.target.id ||
          before.topology.portMappings.any((m) => m.id == created.id)) {
        return _unknown();
      }
      final after = await _snapshot();
      final mapping = after.topology.portMappings
          .where((m) => m.id == created.id)
          .singleOrNull;
      if (mapping == null ||
          mapping.portId != review.port.id ||
          mapping.subsystemId != review.target.id ||
          after.topology.portMappings.length !=
              before.topology.portMappings.length + 1 ||
          after.proof(omitPortMappingId: created.id) != before.proof()) {
        return _unknown();
      }
      return NvmePopulatedPortMappingResult(
        NvmePopulatedPortMappingOutcome.completed,
        'Association #${created.id} verified in a fresh public read. Port and resident ZVOL namespaces remain configured disabled with unchanged NQN and public metadata and no host grant. Runtime reachability, backing identity and access were not tested.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePopulatedPortMappingResult _rejected() =>
      const NvmePopulatedPortMappingResult(
        NvmePopulatedPortMappingOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmePopulatedPortMappingResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePopulatedPortMappingResult(
      NvmePopulatedPortMappingOutcome.unknown,
      'Port association may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
