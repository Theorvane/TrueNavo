import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_nqn_coordinator.dart' show isSupportedNvmeSubsystemNqn;
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemAttachedNqnCoordinatorProvider =
    Provider.autoDispose<NvmeSubsystemAttachedNqnCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeSubsystemAttachedNqnCoordinator(
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

enum NvmeSubsystemAttachedNqnOutcome { completed, rejected, unknown }

final class NvmeSubsystemAttachedNqnResult {
  const NvmeSubsystemAttachedNqnResult(this.outcome, this.message);
  final NvmeSubsystemAttachedNqnOutcome outcome;
  final String message;
}

final class NvmeSubsystemAttachedNqnReview {
  NvmeSubsystemAttachedNqnReview._(
    this.endpoint,
    this.target,
    this.nqn,
    this.namespaces,
    this.mapping,
    this.port,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeSubsystem target;
  final String nqn;
  final List<NvmeNamespace> namespaces;
  final NvmePortMapping mapping;
  final NvmePort port;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'CHANGE ATTACHED NVME SUBSYSTEM ${target.id} NQN ${target.subnqn} TO $nqn KEEP ASSOCIATION ${mapping.id} PORT ${port.id}';
}

/// NQN only behind one disabled TCP/RDMA association without host grants.
/// Residents, if any, must be disabled unlocked unique-NSID ZVOLs.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeSubsystemAttachedNqnCoordinator {
  NvmeSubsystemAttachedNqnCoordinator({
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
  final _issued = <NvmeSubsystemAttachedNqnReview>{};
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
        'nvmet.subsys.update',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);
  void dispose() {
    _closed = true;
    _issued.clear();
  }

  void cancel(NvmeSubsystemAttachedNqnReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Attached subsystem NQN review is unavailable.');
    }
  }

  bool _fresh(NvmeSubsystemAttachedNqnReview review) {
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

  NvmeSubsystem _target(NvmeMutationSnapshot snapshot, int id) {
    final target = snapshot.topology.subsystems
        .where((s) => s.id == id)
        .singleOrNull;
    final nqns = snapshot.topology.subsystems.map((s) => s.subnqn).toList();
    final namespaces = snapshot.topology.namespaces
        .where((n) => n.subsystemId == id)
        .toList();
    final nsids = namespaces.map((n) => n.nsid).toList();
    final mappings = snapshot.topology.portMappings
        .where((m) => m.subsystemId == id)
        .toList();
    final port = mappings.length == 1
        ? snapshot.topology.ports
              .where((p) => p.id == mappings.single.portId)
              .singleOrNull
        : null;
    if (target == null ||
        target.allowAnyHost ||
        target.subnqn == null ||
        nqns.any((n) => n == null) ||
        nqns.toSet().length != nqns.length ||
        namespaces.any(
          (n) => n.deviceType != 'ZVOL' || n.enabled || n.locked != false,
        ) ||
        nsids.any((n) => n == null || n <= 0 || n >= 4294967295) ||
        nsids.toSet().length != nsids.length ||
        mappings.length != 1 ||
        port == null ||
        port.enabled ||
        !const {'TCP', 'RDMA'}.contains(port.transport) ||
        snapshot.topology.portMappings
                .where((m) => m.portId == port.id)
                .length !=
            1 ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == id)) {
      throw StateError(
        'Select a restricted subsystem with one disabled TCP/RDMA association, no host grant, complete unique public NQNs and only disabled unlocked unique-NSID ZVOL residents, if any.',
      );
    }
    return target;
  }

  bool _matches(NvmeSubsystem? actual, NvmeSubsystem before, String nqn) =>
      actual != null &&
      actual.id == before.id &&
      actual.subnqn == nqn &&
      actual.name == before.name &&
      actual.allowAnyHost == before.allowAnyHost &&
      actual.anaReported == before.anaReported &&
      actual.ana == before.ana &&
      actual.piReported == before.piReported &&
      actual.piEnable == before.piEnable &&
      actual.qidReported == before.qidReported &&
      actual.qidMax == before.qidMax &&
      actual.ieeeOuiReported == before.ieeeOuiReported &&
      actual.ieeeOui == before.ieeeOui;

  Future<NvmeSubsystemAttachedNqnReview> prepare(
    int id, {
    required String nqn,
  }) async {
    _guard();
    if (_busy || id <= 0 || !isSupportedNvmeSubsystemNqn(nqn)) {
      throw StateError(
        'Select an exact subsystem ID and a supported explicit dated ASCII NQN.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      if (snapshot.topology.subsystems.any((s) => s.subnqn == nqn)) {
        throw StateError('The requested NQN is already configured.');
      }
      final review = NvmeSubsystemAttachedNqnReview._(
        session.endpoint!,
        target,
        nqn,
        List.unmodifiable(
          snapshot.topology.namespaces
              .where((n) => n.subsystemId == id)
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id)),
        ),
        snapshot.topology.portMappings.where((m) => m.subsystemId == id).single,
        snapshot.topology.ports
            .where(
              (p) =>
                  p.id ==
                  snapshot.topology.portMappings
                      .where((m) => m.subsystemId == id)
                      .single
                      .portId,
            )
            .single,
        snapshot.proof(),
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on Object {
      throw StateError(
        'Attached subsystem NQN preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeSubsystemAttachedNqnResult> execute(
    NvmeSubsystemAttachedNqnReview review,
    String phrase, {
    required bool acknowledgeReload,
    required bool acknowledgeLimitations,
    required bool acknowledgeClientRisk,
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
        !acknowledgeClientRisk) {
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
          before.topology.subsystems.any((s) => s.subnqn == review.nqn) ||
          !_fresh(review)) {
        return _rejected();
      }
      _guard();
      final method = api.adminCatalog.method('nvmet.subsys.update');
      if (method == null || !method.supported) return _rejected();
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            target.id,
            {'subnqn': review.nqn},
          ],
        ),
      );
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = NvmeSubsystem.parse(response.value as Map);
      if (!_matches(returned, target, review.nqn)) return _unknown();
      final after = await _snapshot();
      if (!_matches(_target(after, target.id), target, review.nqn) ||
          before.topology.subsystems.length !=
              after.topology.subsystems.length ||
          before.proof(omitSubsystemId: target.id) !=
              after.proof(omitSubsystemId: target.id)) {
        return _unknown();
      }
      return NvmeSubsystemAttachedNqnResult(
        NvmeSubsystemAttachedNqnOutcome.completed,
        'Subsystem #${target.id} saved NQN=${review.nqn} verified in a fresh public read. Other projected settings and topology are unchanged; runtime identity, initiator access and external client configuration were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeSubsystemAttachedNqnResult _rejected() =>
      const NvmeSubsystemAttachedNqnResult(
        NvmeSubsystemAttachedNqnOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeSubsystemAttachedNqnResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeSubsystemAttachedNqnResult(
      NvmeSubsystemAttachedNqnOutcome.unknown,
      'Attached subsystem NQN may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
