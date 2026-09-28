import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeAttachedNamespaceDeleteCoordinatorProvider =
    Provider.autoDispose<NvmeAttachedNamespaceDeleteCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeAttachedNamespaceDeleteCoordinator(
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

enum NvmeAttachedNamespaceDeleteOutcome { completed, rejected, unknown }

final class NvmeAttachedNamespaceDeleteResult {
  const NvmeAttachedNamespaceDeleteResult(this.outcome, this.message);
  final NvmeAttachedNamespaceDeleteOutcome outcome;
  final String message;
}

final class NvmeAttachedNamespaceDeleteReview {
  NvmeAttachedNamespaceDeleteReview._(
    this.endpoint,
    this.target,
    this.mapping,
    this.port,
    this.subsystem,
    this.residents,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeNamespace target;
  final NvmePortMapping mapping;
  final NvmePort port;
  final NvmeSubsystem subsystem;
  final List<NvmeNamespace> residents;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'DELETE ATTACHED NVME NAMESPACE ${target.id} NSID ${target.nsid} KEEP BACKING KEEP ASSOCIATION ${mapping.id} PORT ${port.id} SUBSYSTEM ${subsystem.id} NQN ${subsystem.subnqn}';
}

/// Configuration removal only on a restricted single disabled port association.
/// Always remove=false; no backing storage deletion or association removal is requested.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeAttachedNamespaceDeleteCoordinator {
  NvmeAttachedNamespaceDeleteCoordinator({
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
  final _issued = <NvmeAttachedNamespaceDeleteReview>{};
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
        'nvmet.namespace.delete',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void dispose() {
    _closed = true;
    _issued.clear();
  }

  void cancel(NvmeAttachedNamespaceDeleteReview review) =>
      _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError(
        'Namespace configuration removal review is unavailable.',
      );
    }
  }

  bool _fresh(NvmeAttachedNamespaceDeleteReview review) {
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

  NvmeNamespace _target(NvmeMutationSnapshot snapshot, int id) {
    final target = snapshot.topology.namespaces
        .where((n) => n.id == id)
        .singleOrNull;
    final subsystem = snapshot.topology.subsystems
        .where((s) => s.id == target?.subsystemId)
        .singleOrNull;
    final mappings = snapshot.topology.portMappings
        .where((m) => m.subsystemId == target?.subsystemId)
        .toList();
    final port = mappings.length == 1
        ? snapshot.topology.ports
              .where((p) => p.id == mappings.single.portId)
              .singleOrNull
        : null;
    final residents = snapshot.topology.namespaces
        .where((n) => n.subsystemId == target?.subsystemId)
        .toList();
    if (target == null ||
        target.deviceType != 'ZVOL' ||
        target.enabled ||
        target.locked != false ||
        target.nsid == null ||
        target.nsid! >= 4294967295 ||
        subsystem == null ||
        subsystem.allowAnyHost ||
        subsystem.subnqn == null ||
        mappings.length != 1 ||
        port == null ||
        port.enabled ||
        !const {'TCP', 'RDMA'}.contains(port.transport) ||
        snapshot.topology.portMappings
                .where((m) => m.portId == port.id)
                .length !=
            1 ||
        residents.any(
          (n) => n.deviceType != 'ZVOL' || n.enabled || n.locked != false,
        ) ||
        snapshot.hosts.mappings.any(
          (m) => m.subsystemId == target.subsystemId,
        )) {
      throw StateError(
        'Only singly attached disabled unlocked ZVOL namespaces behind a disabled TCP/RDMA port, no host grant and safe disabled residents are supported.',
      );
    }
    final ids = snapshot.topology.namespaces
        .where((n) => n.subsystemId == target.subsystemId)
        .map((n) => n.nsid)
        .toList();
    if (ids.any((id) => id == null || id <= 0 || id >= 4294967295) ||
        ids.toSet().length != ids.length) {
      throw StateError(
        'Subsystem NSID inventory is incomplete or inconsistent.',
      );
    }
    return target;
  }

  Future<NvmeAttachedNamespaceDeleteReview> prepare(int id) async {
    _guard();
    if (_busy || id <= 0) {
      throw StateError('Select an exact namespace database ID.');
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      final review = NvmeAttachedNamespaceDeleteReview._(
        session.endpoint!,
        target,
        snapshot.topology.portMappings
            .where((m) => m.subsystemId == target.subsystemId)
            .single,
        snapshot.topology.ports
            .where(
              (p) =>
                  p.id ==
                  snapshot.topology.portMappings
                      .where((m) => m.subsystemId == target.subsystemId)
                      .single
                      .portId,
            )
            .single,
        snapshot.topology.subsystems
            .where((s) => s.id == target.subsystemId)
            .single,
        List.unmodifiable(
          snapshot.topology.namespaces
              .where(
                (n) => n.subsystemId == target.subsystemId && n.id != target.id,
              )
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
        'Namespace configuration removal preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeAttachedNamespaceDeleteResult> execute(
    NvmeAttachedNamespaceDeleteReview review,
    String phrase, {
    required bool acknowledgeConfigurationLoss,
    required bool acknowledgeLimitations,
    required bool acknowledgeExposureRisk,
  }) async {
    final issued = _issued.remove(review);
    if (!issued ||
        locked ||
        !available ||
        !isCurrent() ||
        !_fresh(review) ||
        review.endpoint != session.endpoint ||
        phrase != review.confirmation ||
        !acknowledgeConfigurationLoss ||
        !acknowledgeLimitations ||
        !acknowledgeExposureRisk) {
      return _rejected();
    }
    final owner = lock.acquire();
    if (owner == null) return _rejected();
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final target = _target(before, review.target.id);
      if (before.proof() != review._proof || !_fresh(review)) {
        return _rejected();
      }
      _guard();
      final method = api.adminCatalog.method('nvmet.namespace.delete');
      if (method == null || !method.supported) return _rejected();
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            target.id,
            {'remove': false},
          ],
        ),
      );
      if (response is! AdminCompleted ||
          response.value is! bool ||
          response.value != true) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.topology.namespaces.any((n) => n.id == target.id) ||
          after.topology.namespaces.length !=
              before.topology.namespaces.length - 1 ||
          after.proof() != before.proof(omitNamespaceId: target.id)) {
        return _unknown();
      }
      return NvmeAttachedNamespaceDeleteResult(
        NvmeAttachedNamespaceDeleteOutcome.completed,
        'Namespace configuration #${target.id} is absent in a fresh public read and other projected rows are unchanged. Backing storage and association deletion were not requested; backing integrity and actual client access were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeAttachedNamespaceDeleteResult _rejected() =>
      const NvmeAttachedNamespaceDeleteResult(
        NvmeAttachedNamespaceDeleteOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeAttachedNamespaceDeleteResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeAttachedNamespaceDeleteResult(
      NvmeAttachedNamespaceDeleteOutcome.unknown,
      'Namespace configuration removal may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
