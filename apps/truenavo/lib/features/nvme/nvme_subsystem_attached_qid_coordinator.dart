import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemAttachedQidCoordinatorProvider =
    Provider.autoDispose<NvmeSubsystemAttachedQidCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeSubsystemAttachedQidCoordinator(
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

final class NvmeAttachedQidChoice {
  const NvmeAttachedQidChoice(this.wireValue);
  final int? wireValue;
  bool get valid =>
      wireValue == null || (wireValue! >= 1 && wireValue! <= 2147483647);
  String get label => wireValue?.toString() ?? 'DEFAULT';
}

enum NvmeSubsystemAttachedQidOutcome { completed, rejected, unknown }

final class NvmeSubsystemAttachedQidResult {
  const NvmeSubsystemAttachedQidResult(this.outcome, this.message);
  final NvmeSubsystemAttachedQidOutcome outcome;
  final String message;
}

final class NvmeSubsystemAttachedQidReview {
  NvmeSubsystemAttachedQidReview._(
    this.endpoint,
    this.target,
    this.choice,
    this.namespaces,
    this.mapping,
    this.port,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeSubsystem target;
  final NvmeAttachedQidChoice choice;
  final List<NvmeNamespace> namespaces;
  final NvmePortMapping mapping;
  final NvmePort port;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'SET ATTACHED NVME QID ${target.id} FROM ${target.qidMax?.toString() ?? 'DEFAULT'} TO ${choice.label} KEEP NQN ${target.subnqn} KEEP ASSOCIATION ${mapping.id} PORT ${port.id}';
}

/// Changes only reported saved QID behind one disabled TCP/RDMA association.
/// The numeric range is a conservative local subset, not the API universal maximum.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeSubsystemAttachedQidCoordinator {
  NvmeSubsystemAttachedQidCoordinator({
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
  final _issued = <NvmeSubsystemAttachedQidReview>{};
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

  void cancel(NvmeSubsystemAttachedQidReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Attached subsystem QID review is unavailable.');
    }
  }

  bool _fresh(NvmeSubsystemAttachedQidReview review) {
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
        !target.qidReported ||
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

  bool _matches(
    NvmeSubsystem? actual,
    NvmeSubsystem before,
    NvmeAttachedQidChoice choice,
  ) =>
      actual != null &&
      actual.id == before.id &&
      actual.subnqn == before.subnqn &&
      actual.name == before.name &&
      actual.allowAnyHost == before.allowAnyHost &&
      actual.anaReported == before.anaReported &&
      actual.ana == before.ana &&
      actual.piReported == before.piReported &&
      actual.piEnable == before.piEnable &&
      actual.qidReported == before.qidReported &&
      actual.qidMax == choice.wireValue &&
      actual.ieeeOuiReported == before.ieeeOuiReported &&
      actual.ieeeOui == before.ieeeOui;

  Future<NvmeSubsystemAttachedQidReview> prepare(
    int id, {
    required NvmeAttachedQidChoice choice,
  }) async {
    _guard();
    if (_busy || id <= 0 || !choice.valid) {
      throw StateError(
        'Select an exact attached subsystem ID and saved QID setting (1–2147483647 or default).',
      );
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      if (target.qidMax == choice.wireValue) {
        throw StateError(
          'The requested saved QID setting is already configured.',
        );
      }
      final review = NvmeSubsystemAttachedQidReview._(
        session.endpoint!,
        target,
        choice,
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
        'Attached subsystem QID preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeSubsystemAttachedQidResult> execute(
    NvmeSubsystemAttachedQidReview review,
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
          target.qidMax == review.choice.wireValue ||
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
            {'qid_max': review.choice.wireValue},
          ],
        ),
      );
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = NvmeSubsystem.parse(response.value as Map);
      if (!_matches(returned, target, review.choice)) return _unknown();
      final after = await _snapshot();
      if (!_matches(_target(after, target.id), target, review.choice) ||
          before.topology.subsystems.length !=
              after.topology.subsystems.length ||
          before.proof(omitSubsystemId: target.id) !=
              after.proof(omitSubsystemId: target.id)) {
        return _unknown();
      }
      return NvmeSubsystemAttachedQidResult(
        NvmeSubsystemAttachedQidOutcome.completed,
        'Subsystem #${target.id} saved QID=${review.choice.label} and preserved NQN=${target.subnqn} verified in a fresh public read. Other projected settings and topology are unchanged; effective queue capacity, performance and initiator compatibility were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeSubsystemAttachedQidResult _rejected() =>
      const NvmeSubsystemAttachedQidResult(
        NvmeSubsystemAttachedQidOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeSubsystemAttachedQidResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeSubsystemAttachedQidResult(
      NvmeSubsystemAttachedQidOutcome.unknown,
      'Attached subsystem QID may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
