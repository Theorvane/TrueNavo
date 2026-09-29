import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_populated_rename_coordinator.dart'
    show isSupportedNvmeSubsystemDisplayName;
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemAttachedRenameCoordinatorProvider =
    Provider.autoDispose<NvmeSubsystemAttachedRenameCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeSubsystemAttachedRenameCoordinator(
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

enum NvmeSubsystemAttachedRenameOutcome { completed, rejected, unknown }

final class NvmeSubsystemAttachedRenameResult {
  const NvmeSubsystemAttachedRenameResult(this.outcome, this.message);
  final NvmeSubsystemAttachedRenameOutcome outcome;
  final String message;
}

final class NvmeSubsystemAttachedRenameReview {
  NvmeSubsystemAttachedRenameReview._(
    this.endpoint,
    this.target,
    this.name,
    this.namespaces,
    this.mapping,
    this.port,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeSubsystem target;
  final String name;
  final List<NvmeNamespace> namespaces;
  final NvmePortMapping mapping;
  final NvmePort port;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'RENAME ATTACHED NVME SUBSYSTEM ${target.id} FROM ${target.name} TO $name KEEP NQN ${target.subnqn} KEEP ASSOCIATION ${mapping.id} PORT ${port.id}';
}

/// Renames an empty or safe ZVOL-populated subsystem behind one disabled TCP/RDMA port while preserving its NQN.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeSubsystemAttachedRenameCoordinator {
  NvmeSubsystemAttachedRenameCoordinator({
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
  final _issued = <NvmeSubsystemAttachedRenameReview>{};
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

  void cancel(NvmeSubsystemAttachedRenameReview review) =>
      _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Attached subsystem rename review is unavailable.');
    }
  }

  bool _fresh(NvmeSubsystemAttachedRenameReview review) {
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
        'Select a restricted subsystem with one disabled TCP/RDMA association, no host grant and only disabled unlocked unique-NSID ZVOL residents, if any.',
      );
    }
    return target;
  }

  bool _matches(NvmeSubsystem? actual, NvmeSubsystem before, String name) =>
      actual != null &&
      actual.id == before.id &&
      actual.subnqn == before.subnqn &&
      actual.name == name &&
      actual.allowAnyHost == before.allowAnyHost &&
      actual.anaReported == before.anaReported &&
      actual.ana == before.ana &&
      actual.piReported == before.piReported &&
      actual.piEnable == before.piEnable &&
      actual.qidReported == before.qidReported &&
      actual.qidMax == before.qidMax &&
      actual.ieeeOuiReported == before.ieeeOuiReported &&
      actual.ieeeOui == before.ieeeOui;

  Future<NvmeSubsystemAttachedRenameReview> prepare(
    int id, {
    required String name,
  }) async {
    _guard();
    if (_busy || id <= 0 || !isSupportedNvmeSubsystemDisplayName(name)) {
      throw StateError(
        'Select an exact subsystem ID and a supported display name.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      if (snapshot.topology.subsystems.any(
        (s) => s.name.toLowerCase() == name.toLowerCase(),
      )) {
        throw StateError('The requested name is already configured.');
      }
      final review = NvmeSubsystemAttachedRenameReview._(
        session.endpoint!,
        target,
        name,
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
        'Attached subsystem rename preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeSubsystemAttachedRenameResult> execute(
    NvmeSubsystemAttachedRenameReview review,
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
          target.name == review.name ||
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
            {'name': review.name, 'subnqn': target.subnqn},
          ],
        ),
      );
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = NvmeSubsystem.parse(response.value as Map);
      if (!_matches(returned, target, review.name)) return _unknown();
      final after = await _snapshot();
      if (!_matches(_target(after, target.id), target, review.name) ||
          before.topology.subsystems.length !=
              after.topology.subsystems.length ||
          before.proof(omitSubsystemId: target.id) !=
              after.proof(omitSubsystemId: target.id)) {
        return _unknown();
      }
      return NvmeSubsystemAttachedRenameResult(
        NvmeSubsystemAttachedRenameOutcome.completed,
        'Subsystem #${target.id} saved name=${review.name} and preserved NQN=${target.subnqn} verified in a fresh public read. Other projected settings and topology are unchanged; runtime identity and initiator access were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeSubsystemAttachedRenameResult _rejected() =>
      const NvmeSubsystemAttachedRenameResult(
        NvmeSubsystemAttachedRenameOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeSubsystemAttachedRenameResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeSubsystemAttachedRenameResult(
      NvmeSubsystemAttachedRenameOutcome.unknown,
      'Attached subsystem rename may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
