import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemPopulatedPiCoordinatorProvider =
    Provider.autoDispose<NvmeSubsystemPopulatedPiCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeSubsystemPopulatedPiCoordinator(
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

enum NvmePopulatedPiChoice { serverDefault, on, off }

extension NvmePopulatedPiSetting on NvmePopulatedPiChoice {
  bool? get wireValue => switch (this) {
    NvmePopulatedPiChoice.serverDefault => null,
    NvmePopulatedPiChoice.on => true,
    NvmePopulatedPiChoice.off => false,
  };
  String get label => this == NvmePopulatedPiChoice.serverDefault
      ? 'DEFAULT'
      : name.toUpperCase();
}

enum NvmeSubsystemPopulatedPiOutcome { completed, rejected, unknown }

final class NvmeSubsystemPopulatedPiResult {
  const NvmeSubsystemPopulatedPiResult(this.outcome, this.message);
  final NvmeSubsystemPopulatedPiOutcome outcome;
  final String message;
}

final class NvmeSubsystemPopulatedPiReview {
  NvmeSubsystemPopulatedPiReview._(
    this.endpoint,
    this.target,
    this.choice,
    this.namespaces,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeSubsystem target;
  final NvmePopulatedPiChoice choice;
  final List<NvmeNamespace> namespaces;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'SET POPULATED NVME PI ${target.id} FROM ${target.piEnable == null
          ? 'DEFAULT'
          : target.piEnable!
          ? 'ON'
          : 'OFF'} TO ${choice.label} KEEP NQN ${target.subnqn}';
}

/// Changes only saved PI on an isolated populated subsystem; not data-integrity or compatibility attestation.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeSubsystemPopulatedPiCoordinator {
  NvmeSubsystemPopulatedPiCoordinator({
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
  final _issued = <NvmeSubsystemPopulatedPiReview>{};
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

  void cancel(NvmeSubsystemPopulatedPiReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Populated subsystem PI review is unavailable.');
    }
  }

  bool _fresh(NvmeSubsystemPopulatedPiReview review) {
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
    if (target == null ||
        target.allowAnyHost ||
        target.subnqn == null ||
        !target.piReported ||
        namespaces.isEmpty ||
        namespaces.any(
          (n) => n.deviceType != 'ZVOL' || n.enabled || n.locked != false,
        ) ||
        nsids.any((n) => n == null || n <= 0 || n >= 4294967295) ||
        nsids.toSet().length != nsids.length ||
        snapshot.topology.portMappings.any((m) => m.subsystemId == id) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == id)) {
      throw StateError(
        'Select an isolated restricted populated subsystem containing only disabled unlocked ZVOLs with known unique NSIDs.',
      );
    }
    return target;
  }

  bool _matches(
    NvmeSubsystem? actual,
    NvmeSubsystem before,
    NvmePopulatedPiChoice choice,
  ) =>
      actual != null &&
      actual.id == before.id &&
      actual.subnqn == before.subnqn &&
      actual.name == before.name &&
      actual.allowAnyHost == before.allowAnyHost &&
      actual.anaReported == before.anaReported &&
      actual.ana == before.ana &&
      actual.piReported == before.piReported &&
      actual.piEnable == choice.wireValue &&
      actual.qidReported == before.qidReported &&
      actual.qidMax == before.qidMax &&
      actual.ieeeOuiReported == before.ieeeOuiReported &&
      actual.ieeeOui == before.ieeeOui;

  Future<NvmeSubsystemPopulatedPiReview> prepare(
    int id, {
    required NvmePopulatedPiChoice choice,
  }) async {
    _guard();
    if (_busy || id <= 0) {
      throw StateError(
        'Select an exact populated subsystem ID and saved PI setting.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      if (target.piEnable == choice.wireValue) {
        throw StateError(
          'The requested saved PI setting is already configured.',
        );
      }
      final review = NvmeSubsystemPopulatedPiReview._(
        session.endpoint!,
        target,
        choice,
        List.unmodifiable(
          snapshot.topology.namespaces
              .where((n) => n.subsystemId == id)
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
        'Populated subsystem PI preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeSubsystemPopulatedPiResult> execute(
    NvmeSubsystemPopulatedPiReview review,
    String phrase, {
    required bool acknowledgeReload,
    required bool acknowledgeLimitations,
    required bool acknowledgeIntegrity,
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
        !acknowledgeIntegrity) {
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
          target.piEnable == review.choice.wireValue ||
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
            {'pi_enable': review.choice.wireValue},
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
      return NvmeSubsystemPopulatedPiResult(
        NvmeSubsystemPopulatedPiOutcome.completed,
        'Subsystem #${target.id} saved PI=${review.choice.label} and preserved NQN=${target.subnqn} verified in a fresh public read. Other projected settings and topology are unchanged; runtime identity, actual data integrity and initiator compatibility were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeSubsystemPopulatedPiResult _rejected() =>
      const NvmeSubsystemPopulatedPiResult(
        NvmeSubsystemPopulatedPiOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeSubsystemPopulatedPiResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeSubsystemPopulatedPiResult(
      NvmeSubsystemPopulatedPiOutcome.unknown,
      'Populated subsystem PI may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
