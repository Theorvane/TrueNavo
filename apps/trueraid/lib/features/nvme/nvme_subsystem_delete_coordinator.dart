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
          .map((s) => [s.id, s.name, s.subnqn, s.allowAnyHost])
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

final nvmeHostAccessRevokeCoordinatorProvider =
    Provider<NvmeHostAccessRevokeCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmeHostAccessRevokeCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmeHostRevokeOutcome { completed, rejected, unknown }

final class NvmeHostRevokeResult {
  const NvmeHostRevokeResult(this.outcome, this.message);
  final NvmeHostRevokeOutcome outcome;
  final String message;
}

final class NvmeHostRevokeReview {
  NvmeHostRevokeReview._({
    required this.endpoint,
    required this.mappingId,
    required this.hostId,
    required this.hostNqn,
    required this.subsystemId,
    required this.subsystemName,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, hostNqn, subsystemName, proof;
  final int mappingId, hostId, subsystemId;
  final DateTime issuedAt;
  String get confirmation =>
      'REVOKE NVME HOST $hostId FROM SUBSYSTEM $subsystemId MAPPING $mappingId';
}

/// Revokes one reviewed host grant from a restricted subsystem. This can
/// disconnect clients; the public inventories cannot prove live sessions.
final class NvmeHostAccessRevokeCoordinator {
  NvmeHostAccessRevokeCoordinator({
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
  final _issued = <NvmeHostRevokeReview>{};
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
        'nvmet.host_subsys.delete',
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

  (NvmeHostMapping, NvmeHost, NvmeSubsystem) _target(
    _Snapshot snapshot,
    int mappingId,
  ) {
    final mapping = snapshot.hosts.mappings
        .where((m) => m.id == mappingId)
        .singleOrNull;
    if (mapping == null) {
      throw StateError('Host association was not found. Nothing was sent.');
    }
    final host = snapshot.hosts.hosts
        .where((h) => h.id == mapping.hostId)
        .singleOrNull;
    final subsystem = snapshot.topology.subsystems
        .where((s) => s.id == mapping.subsystemId)
        .singleOrNull;
    if (host == null || subsystem == null || subsystem.allowAnyHost) {
      throw StateError(
        'Only a verified association on a host-restricted subsystem can be revoked. Nothing was sent.',
      );
    }
    return (mapping, host, subsystem);
  }

  Future<NvmeHostRevokeReview> prepare(int mappingId) async {
    _guard();
    if (!available || _busy || mappingId <= 0) {
      throw StateError(
        'Select a positive host association ID on a supported server. Nothing was sent.',
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
      final (mapping, host, subsystem) = _target(before, mappingId);
      final review = NvmeHostRevokeReview._(
        endpoint: session.endpoint!,
        mappingId: mapping.id,
        hostId: host.id,
        hostNqn: host.nqn,
        subsystemId: subsystem.id,
        subsystemName: subsystem.name,
        proof: _proof(before),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF host revocation preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeHostRevokeReview review) => _issued.remove(review);

  Future<NvmeHostRevokeResult> execute(
    NvmeHostRevokeReview review,
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
      return const NvmeHostRevokeResult(
        NvmeHostRevokeOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeHostRevokeResult(
        NvmeHostRevokeOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final (mapping, host, subsystem) = _target(before, review.mappingId);
      if (host.id != review.hostId ||
          host.nqn != review.hostNqn ||
          subsystem.id != review.subsystemId ||
          subsystem.name != review.subsystemName ||
          mapping.id != review.mappingId ||
          _proof(before) != review.proof) {
        return const NvmeHostRevokeResult(
          NvmeHostRevokeOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.host_subsys.delete');
      if (method == null || !method.supported) {
        return const NvmeHostRevokeResult(
          NvmeHostRevokeOutcome.rejected,
          'Host association delete method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(method: method, arguments: [review.mappingId]),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmeHostRevokeResult(
          NvmeHostRevokeOutcome.rejected,
          'The server denied revocation. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value != true) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.hosts.mappings.any((m) => m.id == review.mappingId) ||
          after.hosts.mappings.length != before.hosts.mappings.length - 1 ||
          _proof(after) != _proofWithoutHostMapping(before, review.mappingId)) {
        return _unknown();
      }
      return NvmeHostRevokeResult(
        NvmeHostRevokeOutcome.completed,
        'Host association #${review.mappingId} is absent in a fresh read. Active client disconnection was not measured.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostRevokeResult(
              NvmeHostRevokeOutcome.rejected,
              'NVMe-oF host revocation preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeHostRevokeResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeHostRevokeResult(
      NvmeHostRevokeOutcome.unknown,
      'Host access may have changed. Do not retry; inspect the original server and reconnect.',
    );
  }
}

String _proofWithoutHostMapping(_Snapshot snapshot, int mappingId) {
  final hosts = NvmeHostOverview(
    hosts: snapshot.hosts.hosts,
    mappings: snapshot.hosts.mappings.where((m) => m.id != mappingId).toList(),
  );
  return _proof(_Snapshot(snapshot.topology, hosts));
}

final nvmeHostDeleteCoordinatorProvider = Provider<NvmeHostDeleteCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession) {
    return null;
  }
  return NvmeHostDeleteCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

enum NvmeHostDeleteOutcome { completed, rejected, unknown }

final class NvmeHostDeleteResult {
  const NvmeHostDeleteResult(this.outcome, this.message);
  final NvmeHostDeleteOutcome outcome;
  final String message;
}

final class NvmeHostDeleteReview {
  NvmeHostDeleteReview._({
    required this.endpoint,
    required this.id,
    required this.nqn,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, nqn, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'DELETE NVME HOST $id $nqn';
}

/// Deletes only a host with no returned subsystem association. Sequential
/// reads cannot exclude an association created by another administrator.
final class NvmeHostDeleteCoordinator {
  NvmeHostDeleteCoordinator({
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
  final _issued = <NvmeHostDeleteReview>{};
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
        'nvmet.host.delete',
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

  NvmeHost _target(_Snapshot snapshot, int id) {
    final host = snapshot.hosts.hosts.where((h) => h.id == id).singleOrNull;
    if (host == null || snapshot.hosts.mappings.any((m) => m.hostId == id)) {
      throw StateError(
        'Only an existing host without subsystem associations can be deleted. Nothing was sent.',
      );
    }
    return host;
  }

  Future<NvmeHostDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id <= 0) {
      throw StateError(
        'Select a positive host ID on a supported server. Nothing was sent.',
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
      final host = _target(before, id);
      final review = NvmeHostDeleteReview._(
        endpoint: session.endpoint!,
        id: host.id,
        nqn: host.nqn,
        proof: _proof(before),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF host delete preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeHostDeleteReview review) => _issued.remove(review);

  Future<NvmeHostDeleteResult> execute(
    NvmeHostDeleteReview review,
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
      return const NvmeHostDeleteResult(
        NvmeHostDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeHostDeleteResult(
        NvmeHostDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final host = _target(before, review.id);
      if (host.nqn != review.nqn || _proof(before) != review.proof) {
        return const NvmeHostDeleteResult(
          NvmeHostDeleteOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.host.delete');
      if (method == null || !method.supported) {
        return const NvmeHostDeleteResult(
          NvmeHostDeleteOutcome.rejected,
          'Host delete method is unavailable. Nothing was sent.',
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
        return const NvmeHostDeleteResult(
          NvmeHostDeleteOutcome.rejected,
          'The server denied deletion. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value != true) {
        return _unknown();
      }
      final after = await _snapshot();
      if (after.hosts.hosts.any((h) => h.id == review.id) ||
          after.hosts.hosts.length != before.hosts.hosts.length - 1 ||
          _proof(after) != _proofWithoutHost(before, review.id)) {
        return _unknown();
      }
      return NvmeHostDeleteResult(
        NvmeHostDeleteOutcome.completed,
        'Unassociated host #${review.id} is absent in a fresh read. Client activity was not measured.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeHostDeleteResult(
              NvmeHostDeleteOutcome.rejected,
              'NVMe-oF host delete preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeHostDeleteResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeHostDeleteResult(
      NvmeHostDeleteOutcome.unknown,
      'Host deletion may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}

String _proofWithoutHost(_Snapshot snapshot, int hostId) => _proof(
  _Snapshot(
    snapshot.topology,
    NvmeHostOverview(
      hosts: snapshot.hosts.hosts.where((h) => h.id != hostId).toList(),
      mappings: snapshot.hosts.mappings,
    ),
  ),
);
