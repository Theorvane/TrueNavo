import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeNamespaceEnabledCoordinatorProvider =
    Provider.autoDispose<NvmeNamespaceEnabledCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = session?.repository;
      if (session?.endpoint == null ||
          api is! AuthenticatedAdminSession ||
          api is! AuthenticatedNvmeHostSession) {
        return null;
      }
      final coordinator = NvmeNamespaceEnabledCoordinator(
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

enum NvmeNamespaceEnabledOutcome { completed, rejected, unknown }

final class NvmeNamespaceEnabledResult {
  const NvmeNamespaceEnabledResult(this.outcome, this.message);
  final NvmeNamespaceEnabledOutcome outcome;
  final String message;
}

final class NvmeNamespaceEnabledReview {
  NvmeNamespaceEnabledReview._(
    this.endpoint,
    this.target,
    this.enabled,
    this._proof,
    this.issuedAt,
  );
  final String endpoint;
  final NvmeNamespace target;
  final bool enabled;
  final String _proof;
  final DateTime issuedAt;
  String get confirmation =>
      '${enabled ? 'ENABLE' : 'DISABLE'} NVME NAMESPACE ${target.id} SUBSYSTEM ${target.subsystemId} NSID ${target.nsid}';
}

/// Saved enabled flag only; no backing paths, sizes or identifiers are submitted.
/// Public sequential snapshots do not prove backing identity/health or runtime IO.
final class NvmeNamespaceEnabledCoordinator {
  NvmeNamespaceEnabledCoordinator({
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
  final _issued = <NvmeNamespaceEnabledReview>{};
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

  void cancel(NvmeNamespaceEnabledReview review) => _issued.remove(review);
  void _guard() {
    if (!available || !isCurrent() || NvmeWriteFence.isUncertain(session)) {
      throw StateError('Namespace setting review is unavailable.');
    }
  }

  bool _fresh(NvmeNamespaceEnabledReview review) {
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
        target.locked != false ||
        target.nsid == null ||
        subsystem == null ||
        subsystem.allowAnyHost ||
        snapshot.topology.portMappings.any(
          (m) => m.subsystemId == target.subsystemId,
        ) ||
        snapshot.hosts.mappings.any(
          (m) => m.subsystemId == target.subsystemId,
        )) {
      throw StateError(
        'Only isolated unlocked ZVOL namespaces with a known NSID are supported.',
      );
    }
    return target;
  }

  Future<NvmeNamespaceEnabledReview> prepare(
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
      final review = NvmeNamespaceEnabledReview._(
        session.endpoint!,
        target,
        enabled,
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

  Future<NvmeNamespaceEnabledResult> execute(
    NvmeNamespaceEnabledReview review,
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
      return NvmeNamespaceEnabledResult(
        NvmeNamespaceEnabledOutcome.completed,
        'Namespace #${target.id} saved enabled=${review.enabled} verified in a fresh public read. No backing fields were submitted; backing identity, health and runtime access were not verified.',
      );
    } on Object {
      return sent ? _unknown() : _rejected();
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeNamespaceEnabledResult _rejected() => const NvmeNamespaceEnabledResult(
    NvmeNamespaceEnabledOutcome.rejected,
    'Review, consent, connection or public configuration changed. Nothing was sent.',
  );
  NvmeNamespaceEnabledResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeNamespaceEnabledResult(
      NvmeNamespaceEnabledOutcome.unknown,
      'Namespace setting may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}
