import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemDeleteCoordinatorProvider =
    Provider<NvmeSubsystemDeleteCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmeSubsystemDeleteCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmeDeleteOutcome { completed, rejected, unknown }

final class NvmeDeleteResult {
  const NvmeDeleteResult(this.outcome, this.message);
  final NvmeDeleteOutcome outcome;
  final String message;
}

final class NvmeDeleteReview {
  NvmeDeleteReview._({
    required this.endpoint,
    required this.id,
    required this.name,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, name, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'DELETE NVME SUBSYSTEM $id $name';
}

final class _Snapshot {
  const _Snapshot(this.topology, this.hosts);
  final NvmeOverview topology;
  final NvmeHostOverview hosts;
}

/// Never deletes a subsystem with any returned namespace, port or host link.
/// Separate reads cannot exclude a concurrent administrator's race.
final class NvmeSubsystemDeleteCoordinator {
  NvmeSubsystemDeleteCoordinator({
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
  final _issued = <NvmeDeleteReview>{};
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
        'nvmet.subsys.delete',
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

  Future<_Snapshot> _snapshot() async {
    final topology = await loadNvmeOverviewFromAdmin(
      api: api,
      isCurrent: () => isCurrent() && session.endpoint != null,
    );
    _guard();
    final rows = await hostsApi.loadNvmeHostReferences();
    _guard();
    final hosts = NvmeHostOverview.parse(
      hosts: rows.hosts,
      mappings: rows.mappings,
    );
    if (topology.unresolvedReferences != 0 ||
        hosts.unresolvedReferences(
              topology.subsystems.map((s) => s.id).toSet(),
            ) !=
            0) {
      throw StateError('NVMe-oF references are unresolved. Nothing was sent.');
    }
    return _Snapshot(topology, hosts);
  }

  NvmeSubsystem _target(_Snapshot snapshot, int id) {
    final matches = snapshot.topology.subsystems.where((s) => s.id == id);
    if (matches.length != 1) {
      throw StateError('Subsystem was not found. Nothing was sent.');
    }
    final target = matches.single;
    if (target.allowAnyHost ||
        snapshot.topology.namespaces.any((n) => n.subsystemId == id) ||
        snapshot.topology.portMappings.any((m) => m.subsystemId == id) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == id)) {
      throw StateError(
        'Only a restricted subsystem with no namespace, port or host associations can be deleted. Nothing was sent.',
      );
    }
    return target;
  }

  Future<NvmeDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id <= 0) {
      throw StateError(
        'Select a positive subsystem ID on a supported server. Nothing was sent.',
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
      final target = _target(before, id);
      final review = NvmeDeleteReview._(
        endpoint: session.endpoint!,
        id: id,
        name: target.name,
        proof: _proof(before),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe-oF delete preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeDeleteReview review) => _issued.remove(review);

  Future<NvmeDeleteResult> execute(
    NvmeDeleteReview review,
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
      return const NvmeDeleteResult(
        NvmeDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeDeleteResult(
        NvmeDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final target = _target(before, review.id);
      if (target.name != review.name || _proof(before) != review.proof) {
        return const NvmeDeleteResult(
          NvmeDeleteOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.subsys.delete');
      if (method == null || !method.supported) {
        return const NvmeDeleteResult(
          NvmeDeleteOutcome.rejected,
          'Deletion method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'force': false},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmeDeleteResult(
          NvmeDeleteOutcome.rejected,
          'The server denied deletion. No deletion was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value != true) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.topology.subsystems.any((s) => s.id == review.id) ||
          after.topology.subsystems.length !=
              before.topology.subsystems.length - 1 ||
          _proof(after) != _proof(before, omitSubsystemId: review.id)) {
        return _unknown();
      }
      return NvmeDeleteResult(
        NvmeDeleteOutcome.completed,
        'Unbound subsystem #${review.id} is absent from a fresh read. No client access was tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeDeleteResult(
              NvmeDeleteOutcome.rejected,
              'NVMe-oF delete preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeDeleteResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeDeleteResult(
      NvmeDeleteOutcome.unknown,
      'Deletion may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}

String _proof(_Snapshot snapshot, {int? omitSubsystemId}) {
  final topology = snapshot.topology;
  final hosts = snapshot.hosts;
  final subsystems =
      topology.subsystems
          .where((s) => s.id != omitSubsystemId)
          .map((s) => [s.id, s.name, s.allowAnyHost])
          .toList()
        ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
  final ports =
      topology.ports.map((p) => [p.id, p.transport, p.enabled]).toList()
        ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
  final namespaces =
      topology.namespaces
          .map(
            (n) => [
              n.id,
              n.nsid,
              n.subsystemId,
              n.deviceType,
              n.enabled,
              n.locked,
            ],
          )
          .toList()
        ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
  final portMappings =
      topology.portMappings.map((m) => [m.id, m.portId, m.subsystemId]).toList()
        ..sort((a, b) => a[0].compareTo(b[0]));
  final hostRows = hosts.hosts.map((h) => [h.id, h.nqn]).toList()
    ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
  final hostMappings =
      hosts.mappings.map((m) => [m.id, m.hostId, m.subsystemId]).toList()
        ..sort((a, b) => a[0].compareTo(b[0]));
  return jsonEncode([
    subsystems,
    ports,
    namespaces,
    portMappings,
    hostRows,
    hostMappings,
  ]);
}
