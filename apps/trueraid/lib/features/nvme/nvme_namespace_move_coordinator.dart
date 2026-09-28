import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeNamespaceMoveCoordinatorProvider =
    Provider.autoDispose<NvmeNamespaceMoveCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeNamespaceMoveCoordinator(
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

enum NvmeNamespaceMoveOutcome { completed, rejected, unknown }

final class NvmeNamespaceMoveResult {
  const NvmeNamespaceMoveResult(this.outcome, this.message);
  final NvmeNamespaceMoveOutcome outcome;
  final String message;
}

final class NvmeNamespaceMoveReview {
  NvmeNamespaceMoveReview._(
    this.endpoint,
    this.target,
    this.source,
    this.destination,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeNamespace target;
  final NvmeSubsystem source, destination;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      'MOVE NVME NAMESPACE ${target.id} FROM SUBSYSTEM ${source.id} TO ${destination.id} KEEP NSID ${target.nsid}';
}

/// Saved subsystem assignment only; no backing paths, sizes or identifiers are submitted.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeNamespaceMoveCoordinator {
  NvmeNamespaceMoveCoordinator({
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
  final _issued = <NvmeNamespaceMoveReview>{};
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

  void cancel(NvmeNamespaceMoveReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Namespace setting review is unavailable.');
    }
  }

  bool _fresh(NvmeNamespaceMoveReview review) {
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
    if (target == null ||
        target.deviceType != 'ZVOL' ||
        target.enabled ||
        target.locked != false ||
        target.nsid == null ||
        target.nsid! >= 4294967295 ||
        subsystem == null ||
        subsystem.subnqn == null ||
        subsystem.allowAnyHost ||
        snapshot.topology.portMappings.any(
          (m) => m.subsystemId == target.subsystemId,
        ) ||
        snapshot.hosts.mappings.any(
          (m) => m.subsystemId == target.subsystemId,
        )) {
      throw StateError(
        'Only isolated disabled unlocked ZVOL namespaces with a valid NSID are supported.',
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

  NvmeSubsystem _destination(
    NvmeMutationSnapshot snapshot,
    int sourceId,
    int destinationId, {
    int? movedId,
  }) {
    final source = snapshot.topology.subsystems
        .where((s) => s.id == sourceId)
        .singleOrNull;
    final destination = snapshot.topology.subsystems
        .where((s) => s.id == destinationId)
        .singleOrNull;
    if (source == null ||
        destination == null ||
        sourceId == destinationId ||
        source.subnqn == null ||
        destination.subnqn == null ||
        source.subnqn == destination.subnqn ||
        source.allowAnyHost ||
        destination.allowAnyHost ||
        snapshot.topology.portMappings.any(
          (m) => m.subsystemId == sourceId || m.subsystemId == destinationId,
        ) ||
        snapshot.hosts.mappings.any(
          (m) => m.subsystemId == sourceId || m.subsystemId == destinationId,
        ) ||
        snapshot.topology.namespaces.any(
          (n) => n.subsystemId == destinationId && n.id != movedId,
        )) {
      throw StateError(
        'Select a different empty restricted isolated destination with a known NQN.',
      );
    }
    return destination;
  }

  Future<NvmeNamespaceMoveReview> prepare(
    int id, {
    required int destinationId,
  }) async {
    _guard();
    if (_busy || id <= 0 || destinationId <= 0) {
      throw StateError('Select an exact namespace database ID.');
    }
    final owner = lock.acquire();
    if (owner == null) throw StateError('Another operation is in progress.');
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _target(snapshot, id);
      final destination = _destination(
        snapshot,
        target.subsystemId,
        destinationId,
      );
      final source = snapshot.topology.subsystems.singleWhere(
        (s) => s.id == target.subsystemId,
      );
      final review = NvmeNamespaceMoveReview._(
        session.endpoint!,
        target,
        source,
        destination,
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

  Future<NvmeNamespaceMoveResult> execute(
    NvmeNamespaceMoveReview review,
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
          target.subsystemId == review.destination.id ||
          !_fresh(review)) {
        return _rejected();
      }
      _destination(before, target.subsystemId, review.destination.id);
      _guard();
      final method = api.adminCatalog.method('nvmet.namespace.update');
      if (method == null || !method.supported) return _rejected();
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            target.id,
            {'subsys_id': review.destination.id},
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
          n.subsystemId == review.destination.id &&
          n.nsid == target.nsid &&
          n.deviceType == target.deviceType &&
          n.locked == false &&
          n.enabled == false;
      if (!matches(returned)) return _unknown();
      final after = await _snapshot();
      if (!matches(_target(after, target.id)) ||
          before.topology.namespaces.length !=
              after.topology.namespaces.length ||
          before.proof(omitNamespaceId: target.id) !=
              after.proof(omitNamespaceId: target.id)) {
        return _unknown();
      }
      _destination(
        after,
        target.subsystemId,
        review.destination.id,
        movedId: target.id,
      );
      return NvmeNamespaceMoveResult(
        NvmeNamespaceMoveOutcome.completed,
        'Namespace #${target.id} saved subsystem #${review.destination.id} and unchanged NSID=${target.nsid} verified in a fresh public read. No backing fields were submitted; backing identity, health and runtime access were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeNamespaceMoveResult _rejected() => const NvmeNamespaceMoveResult(
    NvmeNamespaceMoveOutcome.rejected,
    'Review, consent, connection or public configuration changed. Nothing was sent.',
  );
  NvmeNamespaceMoveResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeNamespaceMoveResult(
      NvmeNamespaceMoveOutcome.unknown,
      'Namespace setting may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
