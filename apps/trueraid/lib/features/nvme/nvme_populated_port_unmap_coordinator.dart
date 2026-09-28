import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePopulatedPortUnmapCoordinatorProvider =
    Provider.autoDispose<NvmePopulatedPortUnmapCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmePopulatedPortUnmapCoordinator(
        session: session!,
        api: api as AuthenticatedAdminSession,
        hostsApi: api as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            ref.mounted &&
            identical(session, ref.read(dashboardActiveSessionProvider)),
      );
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

enum NvmePopulatedPortUnmapOutcome { completed, rejected, unknown }

final class NvmePopulatedPortUnmapResult {
  const NvmePopulatedPortUnmapResult(this.outcome, this.message);
  final NvmePopulatedPortUnmapOutcome outcome;
  final String message;
}

final class NvmePopulatedPortUnmapReview {
  NvmePopulatedPortUnmapReview._(
    this.endpoint,
    this.port,
    this.target,
    this.mappingId,
    this.namespaces,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmePort port;
  final NvmeSubsystem target;
  final int mappingId;
  final List<NvmeNamespace> namespaces;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'UNMAP DISABLED NVME ASSOCIATION $mappingId PORT ${port.id} SUBSYSTEM ${target.id} KEEP NQN ${target.subnqn}';
}

/// Removes only a saved association from a singly associated disabled TCP/RDMA port. Disabled flags and absent host grants are
/// public configuration observations, not runtime access or backing attestations.
final class NvmePopulatedPortUnmapCoordinator {
  NvmePopulatedPortUnmapCoordinator({
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
  final _issued = <NvmePopulatedPortUnmapReview>{};
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
        'nvmet.port_subsys.delete',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void dispose() {
    _closed = true;
    _issued.clear();
  }

  void cancel(NvmePopulatedPortUnmapReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Populated disabled-port unlink is unavailable.');
    }
  }

  bool _fresh(NvmePopulatedPortUnmapReview review) {
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
    int mappingId,
  ) {
    final mapping = snapshot.topology.portMappings
        .where((m) => m.id == mappingId)
        .singleOrNull;
    if (mapping == null) throw StateError('Select an exact association ID.');
    final portId = mapping.portId;
    final associations = snapshot.topology.portMappings
        .where((m) => m.portId == portId)
        .toList();
    if (associations.length != 1) {
      throw StateError('Select a singly associated port.');
    }
    final subsystemId = associations.single.subsystemId;
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
          (m) => m.subsystemId == subsystemId && m.portId != portId,
        ) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == subsystemId)) {
      throw StateError(
        'Select a singly associated disabled TCP/RDMA port and restricted subsystem containing only disabled unlocked ZVOLs with known unique NSIDs.',
      );
    }
    return (port, target);
  }

  Future<NvmePopulatedPortUnmapReview> prepare(int mappingId) async {
    _guard();
    if (_busy || mappingId <= 0) {
      throw StateError('Select exact positive association ID.');
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final (port, target) = _target(snapshot, mappingId);
      final review = NvmePopulatedPortUnmapReview._(
        session.endpoint!,
        port,
        target,
        mappingId,
        List.unmodifiable(
          snapshot.topology.namespaces
              .where((n) => n.subsystemId == target.id)
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
        'Populated disabled-port unlink review failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmePopulatedPortUnmapResult> execute(
    NvmePopulatedPortUnmapReview review,
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
      _target(before, review.mappingId);
      if (before.proof() != review._proof || !_fresh(review)) {
        return _rejected();
      }
      _guard();
      sent = true;
      final method = api.adminCatalog.method('nvmet.port_subsys.delete')!;
      final response = await api.invokeAdmin(
        AdminRequest(method: method, arguments: [review.mappingId]),
      );
      if (response is! AdminCompleted || response.value != true) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.topology.portMappings.any((m) => m.id == review.mappingId) ||
          after.topology.portMappings.length !=
              before.topology.portMappings.length - 1 ||
          after.proof() != before.proof(omitPortMappingId: review.mappingId)) {
        return _unknown();
      }
      return NvmePopulatedPortUnmapResult(
        NvmePopulatedPortUnmapOutcome.completed,
        'Association #${review.mappingId} absent in a fresh public read. Port, subsystem, disabled ZVOL residents and all other projected metadata are unchanged. No backing storage deletion was requested. Runtime access, client IO and hidden backing fields were not tested.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePopulatedPortUnmapResult _rejected() =>
      const NvmePopulatedPortUnmapResult(
        NvmePopulatedPortUnmapOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmePopulatedPortUnmapResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePopulatedPortUnmapResult(
      NvmePopulatedPortUnmapOutcome.unknown,
      'Port association may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
