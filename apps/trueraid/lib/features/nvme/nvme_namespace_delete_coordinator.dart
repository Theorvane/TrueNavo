import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeNamespaceDeleteCoordinatorProvider =
    Provider<NvmeNamespaceDeleteCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmeNamespaceDeleteCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmeNamespaceDeleteOutcome { completed, rejected, unknown }

final class NvmeNamespaceDeleteResult {
  const NvmeNamespaceDeleteResult(this.outcome, this.message);
  final NvmeNamespaceDeleteOutcome outcome;
  final String message;
}

final class NvmeNamespaceDeleteReview {
  NvmeNamespaceDeleteReview._({
    required this.endpoint,
    required this.id,
    required this.deviceType,
    required this.subsystemId,
    required this.nsid,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, deviceType, proof;
  final int id, subsystemId, nsid;
  final DateTime issuedAt;
  String get confirmation =>
      'DELETE NVME NAMESPACE $id SUBSYSTEM $subsystemId NSID $nsid KEEP BACKING';
}

/// Requests configuration removal only, always remove=false.
/// These separate reads cannot exclude a concurrent administrator's race.
final class NvmeNamespaceDeleteCoordinator {
  NvmeNamespaceDeleteCoordinator({
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
  final _issued = <NvmeNamespaceDeleteReview>{};
  bool _busy = false;

  bool get locked => _busy || NvmeWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('nvmet.host.query') != null &&
      api.adminCatalog.method('nvmet.host_subsys.query')?.supported == true &&
      [
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.namespace.delete',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  void _guard() {
    if (!isCurrent() || session.endpoint == null) {
      throw StateError('The server connection changed.');
    }
    if (NvmeWriteFence.isUncertain(session)) {
      throw StateError(
        'An NVMe-oF change is unverified. Reconnect before editing.',
      );
    }
  }

  Future<NvmeMutationSnapshot> _snapshot() async {
    final snapshot = await NvmeMutationSnapshot.load(
      api: api,
      hostsApi: hostsApi,
      isCurrent: () => isCurrent() && session.endpoint != null,
    );
    _guard();
    return snapshot;
  }

  NvmeNamespace _target(NvmeMutationSnapshot snapshot, int id) {
    final namespace = snapshot.topology.namespaces
        .where((n) => n.id == id)
        .singleOrNull;
    final subsystem = namespace == null
        ? null
        : snapshot.topology.subsystems
              .where((s) => s.id == namespace.subsystemId)
              .singleOrNull;
    if (namespace == null ||
        namespace.enabled ||
        namespace.locked != false ||
        namespace.nsid == null ||
        subsystem == null ||
        subsystem.allowAnyHost ||
        snapshot.topology.portMappings.any(
          (m) => m.subsystemId == subsystem.id,
        ) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == subsystem.id)) {
      throw StateError(
        'Only a disabled unlocked namespace with a known NSID in a restricted subsystem without port or host mappings can be removed. Nothing was sent.',
      );
    }
    return namespace;
  }

  Future<NvmeNamespaceDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id <= 0) {
      throw StateError(
        'Select a positive namespace ID on a supported server. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final before = await _snapshot();
      final namespace = _target(before, id);
      final review = NvmeNamespaceDeleteReview._(
        endpoint: session.endpoint!,
        id: namespace.id,
        deviceType: namespace.deviceType,
        subsystemId: namespace.subsystemId,
        nsid: namespace.nsid!,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF namespace delete preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeNamespaceDeleteReview review) => _issued.remove(review);

  Future<NvmeNamespaceDeleteResult> execute(
    NvmeNamespaceDeleteReview review,
    String confirmation, {
    bool acknowledgeConfigurationLoss = false,
  }) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!acknowledgeConfigurationLoss ||
        !issued ||
        _busy ||
        !isCurrent() ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmeNamespaceDeleteResult(
        NvmeNamespaceDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeNamespaceDeleteResult(
        NvmeNamespaceDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final namespace = _target(before, review.id);
      if (namespace.deviceType != review.deviceType ||
          namespace.subsystemId != review.subsystemId ||
          namespace.nsid != review.nsid ||
          before.proof() != review.proof) {
        return const NvmeNamespaceDeleteResult(
          NvmeNamespaceDeleteOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.namespace.delete');
      if (method == null || !method.supported) {
        return const NvmeNamespaceDeleteResult(
          NvmeNamespaceDeleteOutcome.rejected,
          'Namespace delete method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'remove': false},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmeNamespaceDeleteResult(
          NvmeNamespaceDeleteOutcome.rejected,
          'The server denied namespace deletion. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value != true) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.topology.namespaces.any((n) => n.id == review.id) ||
          after.topology.namespaces.length !=
              before.topology.namespaces.length - 1 ||
          after.proof() != before.proof(omitNamespaceId: review.id)) {
        return _unknown();
      }
      return NvmeNamespaceDeleteResult(
        NvmeNamespaceDeleteOutcome.completed,
        'Namespace configuration #${review.id} is absent in a fresh read. Backing-file removal was not requested; backing integrity and live client activity were not measured.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeNamespaceDeleteResult(
              NvmeNamespaceDeleteOutcome.rejected,
              'NVMe-oF namespace delete preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeNamespaceDeleteResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeNamespaceDeleteResult(
      NvmeNamespaceDeleteOutcome.unknown,
      'Namespace deletion may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
