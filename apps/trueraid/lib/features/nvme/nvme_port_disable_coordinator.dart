import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePortDisableCoordinatorProvider =
    Provider<NvmePortDisableCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmePortDisableCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmePortDisableOutcome { completed, rejected, unknown }

final class NvmePortDisableResult {
  const NvmePortDisableResult(this.outcome, this.message);
  final NvmePortDisableOutcome outcome;
  final String message;
}

final class NvmePortDisableReview {
  NvmePortDisableReview._({
    required this.endpoint,
    required this.id,
    required this.transport,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, transport, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'DISABLE NVME PORT $id $transport';
}

/// Disables only an enabled port without a returned subsystem association.
/// These separate reads cannot exclude a concurrent administrator's race.
final class NvmePortDisableCoordinator {
  NvmePortDisableCoordinator({
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
  final _issued = <NvmePortDisableReview>{};
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
        'nvmet.port.update',
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

  NvmePort _target(NvmeMutationSnapshot snapshot, int id) {
    final port = snapshot.topology.ports.where((p) => p.id == id).singleOrNull;
    if (port == null ||
        !port.enabled ||
        snapshot.topology.portMappings.any((m) => m.portId == id)) {
      throw StateError(
        'Only an existing enabled port without subsystem associations can be disabled. Nothing was sent.',
      );
    }
    return port;
  }

  Future<NvmePortDisableReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id <= 0) {
      throw StateError(
        'Select a positive port ID on a supported server. Nothing was sent.',
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
      final port = _target(before, id);
      final review = NvmePortDisableReview._(
        endpoint: session.endpoint!,
        id: port.id,
        transport: port.transport,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF port disable preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmePortDisableReview review) => _issued.remove(review);

  Future<NvmePortDisableResult> execute(
    NvmePortDisableReview review,
    String confirmation,
  ) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        _busy ||
        !isCurrent() ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmePortDisableResult(
        NvmePortDisableOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmePortDisableResult(
        NvmePortDisableOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final port = _target(before, review.id);
      if (port.transport != review.transport ||
          before.proof() != review.proof) {
        return const NvmePortDisableResult(
          NvmePortDisableOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.port.update');
      if (method == null || !method.supported) {
        return const NvmePortDisableResult(
          NvmePortDisableOutcome.rejected,
          'Port update method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'enabled': false},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmePortDisableResult(
          NvmePortDisableOutcome.rejected,
          'The server denied port disable. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = response.value as Map;
      if (returned['id'] != review.id ||
          returned['addr_trtype'] != review.transport ||
          returned['enabled'] != false) {
        return _unknown();
      }
      final after = await _snapshot();
      final changed = after.topology.ports.where((p) => p.id == review.id);
      if (changed.length != 1 ||
          changed.single.transport != review.transport ||
          changed.single.enabled ||
          after.topology.ports.length != before.topology.ports.length ||
          after.proof(omitPortId: review.id) !=
              before.proof(omitPortId: review.id) ||
          after.topology.portMappings.any((m) => m.portId == review.id)) {
        return _unknown();
      }
      return NvmePortDisableResult(
        NvmePortDisableOutcome.completed,
        'Unassociated port #${review.id} is configured disabled in a fresh read. Client activity was not measured.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmePortDisableResult(
              NvmePortDisableOutcome.rejected,
              'NVMe-oF port disable preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePortDisableResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePortDisableResult(
      NvmePortDisableOutcome.unknown,
      'Port disable may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
