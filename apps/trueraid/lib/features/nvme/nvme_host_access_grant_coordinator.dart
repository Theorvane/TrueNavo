import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeHostAccessGrantCoordinatorProvider =
    Provider<NvmeHostAccessGrantCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession ||
          repository is! AuthenticatedNvmeHostAccessSession) {
        return null;
      }
      return NvmeHostAccessGrantCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        accessApi: repository as AuthenticatedNvmeHostAccessSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmeHostGrantOutcome { completed, rejected, unknown }

final class NvmeHostGrantResult {
  const NvmeHostGrantResult(this.outcome, this.message);
  final NvmeHostGrantOutcome outcome;
  final String message;
}

final class NvmeHostGrantReview {
  NvmeHostGrantReview._({
    required this.endpoint,
    required this.hostId,
    required this.hostNqn,
    required this.subsystemId,
    required this.subsystemName,
    required this.subnqn,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, hostNqn, subsystemName, subnqn, proof;
  final int hostId, subsystemId;
  final DateTime issuedAt;
  String get confirmation =>
      'GRANT NVME HOST $hostId TO SUBSYSTEM $subsystemId';
}

final class _Snapshot {
  const _Snapshot(this.topology, this.hosts);
  final NvmeOverview topology;
  final NvmeHostOverview hosts;
}

/// Grants an existing host only to a restricted subsystem with no returned
/// namespace or port association. A concurrent administrator can still change
/// the target between these sequential reads and the write.
final class NvmeHostAccessGrantCoordinator {
  NvmeHostAccessGrantCoordinator({
    required this.session,
    required this.api,
    required this.hostsApi,
    required this.accessApi,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final AuthenticatedNvmeHostSession hostsApi;
  final AuthenticatedNvmeHostAccessSession accessApi;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <NvmeHostGrantReview>{};
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
        'nvmet.host_subsys.create',
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

  (NvmeHost, NvmeSubsystem) _target(
    _Snapshot snapshot,
    int hostId,
    int subsystemId,
  ) {
    final host = snapshot.hosts.hosts.where((h) => h.id == hostId).singleOrNull;
    final subsystem = snapshot.topology.subsystems
        .where((s) => s.id == subsystemId)
        .singleOrNull;
    if (host == null ||
        subsystem == null ||
        subsystem.allowAnyHost ||
        subsystem.subnqn == null ||
        snapshot.topology.namespaces.any((n) => n.subsystemId == subsystemId) ||
        snapshot.topology.portMappings.any(
          (m) => m.subsystemId == subsystemId,
        ) ||
        snapshot.hosts.mappings.any(
          (m) => m.hostId == hostId && m.subsystemId == subsystemId,
        ) ||
        snapshot.hosts.mappings.length >= 99) {
      throw StateError(
        'Grant requires an existing host and a restricted subsystem with a returned NQN, no port or namespace association, no duplicate grant and room for complete readback. Nothing was sent.',
      );
    }
    return (host, subsystem);
  }

  Future<NvmeHostGrantReview> prepare(int hostId, int subsystemId) async {
    _guard();
    if (!available || _busy || hostId <= 0 || subsystemId <= 0) {
      throw StateError(
        'Select positive host and subsystem IDs on a supported server. Nothing was sent.',
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
      final (host, subsystem) = _target(before, hostId, subsystemId);
      final review = NvmeHostGrantReview._(
        endpoint: session.endpoint!,
        hostId: host.id,
        hostNqn: host.nqn,
        subsystemId: subsystem.id,
        subsystemName: subsystem.name,
        subnqn: subsystem.subnqn!,
        proof: _proof(before),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF host grant preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeHostGrantReview review) => _issued.remove(review);

  Future<NvmeHostGrantResult> execute(
    NvmeHostGrantReview review,
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
      return const NvmeHostGrantResult(
        NvmeHostGrantOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeHostGrantResult(
        NvmeHostGrantOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final (host, subsystem) = _target(
        before,
        review.hostId,
        review.subsystemId,
      );
      if (host.nqn != review.hostNqn ||
          subsystem.name != review.subsystemName ||
          subsystem.subnqn != review.subnqn ||
          _proof(before) != review.proof) {
        return const NvmeHostGrantResult(
          NvmeHostGrantOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final created = await accessApi.createNvmeHostAssociation(
        hostId: review.hostId,
        subsystemId: review.subsystemId,
      );
      if (created.hostId != review.hostId ||
          created.subsystemId != review.subsystemId ||
          created.id <= 0) {
        return _unknown();
      }
      final after = await _snapshot();
      final matches = after.hosts.mappings.where((m) => m.id == created.id);
      if (matches.length != 1 ||
          matches.single.hostId != review.hostId ||
          matches.single.subsystemId != review.subsystemId ||
          after.hosts.mappings.length != before.hosts.mappings.length + 1 ||
          after.topology.namespaces.any(
            (n) => n.subsystemId == review.subsystemId,
          ) ||
          after.topology.portMappings.any(
            (m) => m.subsystemId == review.subsystemId,
          ) ||
          _proofWithoutMapping(after, created.id) != _proof(before)) {
        return _unknown();
      }
      return NvmeHostGrantResult(
        NvmeHostGrantOutcome.completed,
        'Host association #${created.id} was found in a fresh read. No port or namespace was returned for this subsystem; client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostGrantResult(
              NvmeHostGrantOutcome.rejected,
              'NVMe-oF host grant preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeHostGrantResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeHostGrantResult(
      NvmeHostGrantOutcome.unknown,
      'Host access may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}

String _proofWithoutMapping(_Snapshot snapshot, int mappingId) => _proof(
  _Snapshot(
    snapshot.topology,
    NvmeHostOverview(
      hosts: snapshot.hosts.hosts,
      mappings: snapshot.hosts.mappings
          .where((m) => m.id != mappingId)
          .toList(),
    ),
  ),
);

String _proof(_Snapshot snapshot) {
  final topology = snapshot.topology;
  final subsystems =
      topology.subsystems
          .map(
            (s) => [
              s.id,
              s.name,
              s.subnqn,
              s.allowAnyHost,
              s.anaReported,
              s.ana,
              s.piReported,
              s.piEnable,
              s.qidReported,
              s.qidMax,
              s.ieeeOuiReported,
              s.ieeeOui,
            ],
          )
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
  final hosts = snapshot.hosts.hosts.map((h) => [h.id, h.nqn]).toList()
    ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
  final hostMappings =
      snapshot.hosts.mappings
          .map((m) => [m.id, m.hostId, m.subsystemId])
          .toList()
        ..sort((a, b) => a[0].compareTo(b[0]));
  return jsonEncode([
    subsystems,
    ports,
    namespaces,
    portMappings,
    hosts,
    hostMappings,
  ]);
}
