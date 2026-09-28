import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemPopulatedOuiCoordinatorProvider =
    Provider.autoDispose<NvmeSubsystemPopulatedOuiCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeSubsystemPopulatedOuiCoordinator(
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

final class NvmePopulatedOuiChoice {
  const NvmePopulatedOuiChoice(this.wireValue);
  final String? wireValue;
  bool get valid =>
      wireValue == null ||
      RegExp(r'^[0-9A-F]{2}(:[0-9A-F]{2}){2}$').hasMatch(wireValue!);
  String get label => wireValue ?? 'DEFAULT';
}

enum NvmeSubsystemPopulatedOuiOutcome { completed, rejected, unknown }

final class NvmeSubsystemPopulatedOuiResult {
  const NvmeSubsystemPopulatedOuiResult(this.outcome, this.message);
  final NvmeSubsystemPopulatedOuiOutcome outcome;
  final String message;
}

final class NvmeSubsystemPopulatedOuiReview {
  NvmeSubsystemPopulatedOuiReview._(
    this.endpoint,
    this.target,
    this.choice,
    this.namespaces,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeSubsystem target;
  final NvmePopulatedOuiChoice choice;
  final List<NvmeNamespace> namespaces;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'SET POPULATED NVME OUI ${target.id} FROM ${target.ieeeOui ?? 'DEFAULT'} TO ${choice.label} KEEP NQN ${target.subnqn}';
}

/// Changes only saved OUI on an isolated populated subsystem; not registered OUI ownership or runtime device identity attestation.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeSubsystemPopulatedOuiCoordinator {
  NvmeSubsystemPopulatedOuiCoordinator({
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
  final _issued = <NvmeSubsystemPopulatedOuiReview>{};
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

  void cancel(NvmeSubsystemPopulatedOuiReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Populated subsystem OUI review is unavailable.');
    }
  }

  bool _fresh(NvmeSubsystemPopulatedOuiReview review) {
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
        !target.ieeeOuiReported ||
        (target.ieeeOui != null &&
            !RegExp(r'^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){2}$')
                .hasMatch(target.ieeeOui!)) ||
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
    NvmePopulatedOuiChoice choice,
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
      actual.qidMax == before.qidMax &&
      actual.ieeeOuiReported == before.ieeeOuiReported &&
      actual.ieeeOui == choice.wireValue;

  Future<NvmeSubsystemPopulatedOuiReview> prepare(
    int id, {
    required NvmePopulatedOuiChoice choice,
  }) async {
    _guard();
    if (_busy || id <= 0 || !choice.valid) {
      throw StateError(
        'Select an exact populated subsystem ID and saved OUI setting (AA:BB:CC uppercase hex or default).',
      );
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      if (target.ieeeOui?.toUpperCase() == choice.wireValue) {
        throw StateError(
          'The requested saved OUI setting is already configured.',
        );
      }
      final review = NvmeSubsystemPopulatedOuiReview._(
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
        'Populated subsystem OUI preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Future<NvmeSubsystemPopulatedOuiResult> execute(
    NvmeSubsystemPopulatedOuiReview review,
    String phrase, {
    required bool acknowledgeReload,
    required bool acknowledgeLimitations,
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
        !acknowledgeLimitations) {
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
          target.ieeeOui?.toUpperCase() == review.choice.wireValue ||
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
            {'ieee_oui': review.choice.wireValue},
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
      return NvmeSubsystemPopulatedOuiResult(
        NvmeSubsystemPopulatedOuiOutcome.completed,
        'Subsystem #${target.id} saved OUI=${review.choice.label} and preserved NQN=${target.subnqn} verified in a fresh public read. Other projected settings and topology are unchanged; registered OUI ownership, actual device identity and initiator compatibility were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeSubsystemPopulatedOuiResult _rejected() =>
      const NvmeSubsystemPopulatedOuiResult(
        NvmeSubsystemPopulatedOuiOutcome.rejected,
        'Review, consent, connection or public configuration changed. Nothing was sent.',
      );
  NvmeSubsystemPopulatedOuiResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeSubsystemPopulatedOuiResult(
      NvmeSubsystemPopulatedOuiOutcome.unknown,
      'Populated subsystem OUI may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
