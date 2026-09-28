import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeAssociatedPortEnabledCoordinatorProvider =
    Provider.autoDispose<NvmeAssociatedPortEnabledCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeAssociatedPortEnabledCoordinator(
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

enum NvmeAssociatedPortChoice { on, off }

extension NvmeAssociatedPortSetting on NvmeAssociatedPortChoice {
  bool get wireValue => this == NvmeAssociatedPortChoice.on;
  String get label => name.toUpperCase();
}

enum NvmeAssociatedPortEnabledOutcome { completed, rejected, unknown }

final class NvmeAssociatedPortEnabledResult {
  const NvmeAssociatedPortEnabledResult(this.outcome, this.message);
  final NvmeAssociatedPortEnabledOutcome outcome;
  final String message;
}

final class NvmeAssociatedPortEnabledReview {
  NvmeAssociatedPortEnabledReview._(
    this.endpoint,
    this.port,
    this.target,
    this.choice,
    this.namespaces,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmePort port;
  final NvmeSubsystem target;
  final NvmeAssociatedPortChoice choice;
  final List<NvmeNamespace> namespaces;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'SET ASSOCIATED NVME PORT ${port.id} FROM ${port.enabled ? 'ON' : 'OFF'} TO ${choice.label} KEEP SUBSYSTEM ${target.id} NQN ${target.subnqn}';
}

/// Changes only the saved enabled flag of a singly associated TCP/RDMA port. Disabled flags and absent host grants are
/// public configuration observations, not runtime access or backing attestations.
final class NvmeAssociatedPortEnabledCoordinator {
  NvmeAssociatedPortEnabledCoordinator({
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
  final _issued = <NvmeAssociatedPortEnabledReview>{};
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
        'nvmet.port.update',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void dispose() {
    _closed = true;
    _issued.clear();
  }

  void cancel(NvmeAssociatedPortEnabledReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Associated port enabled setting is unavailable.');
    }
  }

  bool _fresh(NvmeAssociatedPortEnabledReview review) {
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

  (NvmePort, NvmeSubsystem) _target(NvmeMutationSnapshot snapshot, int portId) {
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
        'Select an singly associated TCP/RDMA port and restricted subsystem containing only disabled unlocked ZVOLs with known unique NSIDs.',
      );
    }
    return (port, target);
  }

  Future<NvmeAssociatedPortEnabledReview> prepare(
    int portId, {
    required NvmeAssociatedPortChoice choice,
  }) async {
    _guard();
    if (_busy || portId <= 0) {
      throw StateError('Select exact positive port ID.');
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final (port, target) = _target(snapshot, portId);
      if (port.enabled == choice.wireValue) {
        throw StateError('Already configured.');
      }
      final review = NvmeAssociatedPortEnabledReview._(
        session.endpoint!,
        port,
        target,
        choice,
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
        'Associated port enabled setting review failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeAssociatedPortEnabledResult> execute(
    NvmeAssociatedPortEnabledReview review,
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
      _target(before, review.port.id);
      if (before.proof() != review._proof || !_fresh(review)) {
        return _rejected();
      }
      _guard();
      sent = true;
      final method = api.adminCatalog.method('nvmet.port.update')!;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.port.id,
            {'enabled': review.choice.wireValue},
          ],
        ),
      );
      if (response is! AdminCompleted ||
          response.value is! Map ||
          !_matches(
            NvmePort.parse(response.value as Map),
            review.port,
            review.choice,
          )) {
        return _unknown();
      }
      final after = await _snapshot();
      final (actual, _) = _target(after, review.port.id);
      if (!_matches(actual, review.port, review.choice) ||
          after.topology.ports.length != before.topology.ports.length ||
          after.proof(omitPortId: review.port.id) !=
              before.proof(omitPortId: review.port.id)) {
        return _unknown();
      }
      return NvmeAssociatedPortEnabledResult(
        NvmeAssociatedPortEnabledOutcome.completed,
        'Port #${review.port.id} saved enabled=${review.choice.label} verified in a fresh public read. Associated subsystem, disabled residents and other projected metadata are unchanged. Runtime listener state, client IO, backing identity and access were not tested.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  bool _matches(
    NvmePort? actual,
    NvmePort before,
    NvmeAssociatedPortChoice choice,
  ) =>
      actual != null &&
      actual.id == before.id &&
      actual.transport == before.transport &&
      actual.enabled == choice.wireValue &&
      actual.inlineDataSizeReported == before.inlineDataSizeReported &&
      actual.inlineDataSize == before.inlineDataSize &&
      actual.maxQueueSizeReported == before.maxQueueSizeReported &&
      actual.maxQueueSize == before.maxQueueSize &&
      actual.piReported == before.piReported &&
      actual.piEnable == before.piEnable;

  NvmeAssociatedPortEnabledResult _rejected() =>
      const NvmeAssociatedPortEnabledResult(
        NvmeAssociatedPortEnabledOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeAssociatedPortEnabledResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeAssociatedPortEnabledResult(
      NvmeAssociatedPortEnabledOutcome.unknown,
      'Port enabled setting may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
