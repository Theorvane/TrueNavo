import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeAttachedNamespaceEnabledCoordinatorProvider =
    Provider.autoDispose<NvmeAttachedNamespaceEnabledCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeAttachedNamespaceEnabledCoordinator(
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

enum NvmeAttachedNamespaceEnabledOutcome { completed, rejected, unknown }

/// Public configuration hints; selection is never authorization to update.
final class NvmeAttachedNamespaceEnabledCandidate {
  const NvmeAttachedNamespaceEnabledCandidate._(
    this.target,
    this.subsystem,
    this.mapping,
    this.port,
    this.enabled,
  );
  final NvmeNamespace target;
  final NvmeSubsystem subsystem;
  final NvmePortMapping mapping;
  final NvmePort port;
  final bool enabled;
}

final class NvmeAttachedNamespaceEnabledResult {
  const NvmeAttachedNamespaceEnabledResult(this.outcome, this.message);
  final NvmeAttachedNamespaceEnabledOutcome outcome;
  final String message;
}

final class NvmeAttachedNamespaceEnabledReview {
  NvmeAttachedNamespaceEnabledReview._(
    this.endpoint,
    this.target,
    this.enabled,
    this.mapping,
    this.port,
    this.subsystem,
    this.residents,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeNamespace target;
  final bool enabled;
  final NvmePortMapping mapping;
  final NvmePort port;
  final NvmeSubsystem subsystem;
  final List<NvmeNamespace> residents;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      '${enabled ? 'ENABLE' : 'DISABLE'} ATTACHED NVME NAMESPACE ${target.id} NSID ${target.nsid} FROM ${target.enabled} TO $enabled KEEP ASSOCIATION ${mapping.id} PORT ${port.id} SUBSYSTEM ${subsystem.id} NQN ${subsystem.subnqn}';
}

/// Saved enabled flag only on a restricted single disabled port association; no backing paths, sizes or identifiers are submitted.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeAttachedNamespaceEnabledCoordinator {
  NvmeAttachedNamespaceEnabledCoordinator({
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
  final _issued = <NvmeAttachedNamespaceEnabledReview>{};
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
        'nvmet.namespace.update',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void dispose() {
    _closed = true;
    _issued.clear();
  }

  void cancel(NvmeAttachedNamespaceEnabledReview review) =>
      _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Namespace setting review is unavailable.');
    }
  }

  bool _fresh(NvmeAttachedNamespaceEnabledReview review) {
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
          (n) =>
              n.deviceType != 'ZVOL' ||
              (n.id != target.id && n.enabled) ||
              n.locked != false,
        ) ||
        snapshot.hosts.mappings.any(
          (m) => m.subsystemId == target.subsystemId,
        )) {
      throw StateError(
        'Only singly attached unlocked ZVOL namespaces behind a disabled TCP/RDMA port, no host grant and disabled unlocked ZVOL neighbors are supported.',
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

  Future<List<NvmeAttachedNamespaceEnabledCandidate>> loadCandidates({
    required bool enabled,
  }) async {
    _guard();
    if (_busy) throw StateError('Another operation is in progress.');
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final candidates = <NvmeAttachedNamespaceEnabledCandidate>[];
      for (final namespace in snapshot.topology.namespaces) {
        final NvmeNamespace target;
        try {
          target = _target(snapshot, namespace.id);
        } on StateError {
          continue;
        }
        if (target.enabled == enabled) continue;
        final mapping = snapshot.topology.portMappings.singleWhere(
          (m) => m.subsystemId == target.subsystemId,
        );
        candidates.add(
          NvmeAttachedNamespaceEnabledCandidate._(
            target,
            snapshot.topology.subsystems.singleWhere(
              (s) => s.id == target.subsystemId,
            ),
            mapping,
            snapshot.topology.ports.singleWhere((p) => p.id == mapping.portId),
            enabled,
          ),
        );
      }
      candidates.sort((a, b) => a.target.id.compareTo(b.target.id));
      _guard();
      return List.unmodifiable(candidates);
    } on Object {
      throw StateError(
        'Namespace state target discovery failed. No configuration request was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeAttachedNamespaceEnabledReview> prepare(
    int id, {
    required bool enabled,
  }) async {
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
      if (target.enabled == enabled) {
        throw StateError('The selected setting is already saved.');
      }
      final review = NvmeAttachedNamespaceEnabledReview._(
        session.endpoint!,
        target,
        enabled,
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
      throw StateError('Namespace setting preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeAttachedNamespaceEnabledResult> execute(
    NvmeAttachedNamespaceEnabledReview review,
    String phrase, {
    required bool acknowledgeReload,
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
        !acknowledgeReload ||
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
      if (before.proof() != review._proof ||
          target.enabled == review.enabled ||
          !_fresh(review)) {
        return _rejected();
      }
      _guard();
      final method = api.adminCatalog.method('nvmet.namespace.update');
      if (method == null || !method.supported) return _rejected();
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            target.id,
            {'enabled': review.enabled},
          ],
        ),
      );
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = NvmeNamespace.parse(response.value as Map);
      bool matches(NvmeNamespace? n) =>
          n != null &&
          n.id == target.id &&
          n.subsystemId == target.subsystemId &&
          n.nsid == target.nsid &&
          n.deviceType == target.deviceType &&
          n.locked == false &&
          n.enabled == review.enabled;
      if (!matches(returned)) return _unknown();
      final after = await _snapshot();
      if (!matches(_target(after, target.id)) ||
          before.topology.namespaces.length !=
              after.topology.namespaces.length ||
          before.proof(omitNamespaceId: target.id) !=
              after.proof(omitNamespaceId: target.id)) {
        return _unknown();
      }
      return NvmeAttachedNamespaceEnabledResult(
        NvmeAttachedNamespaceEnabledOutcome.completed,
        'Namespace #${target.id} saved enabled=${review.enabled} verified in a fresh public read. No backing fields were submitted; backing identity, health and runtime access were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeAttachedNamespaceEnabledResult _rejected() =>
      const NvmeAttachedNamespaceEnabledResult(
        NvmeAttachedNamespaceEnabledOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeAttachedNamespaceEnabledResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeAttachedNamespaceEnabledResult(
      NvmeAttachedNamespaceEnabledOutcome.unknown,
      'Namespace setting may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
