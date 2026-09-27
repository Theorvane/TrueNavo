import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';

final nvmeSubsystemCreateCoordinatorProvider =
    Provider<NvmeSubsystemCreateCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmeSubsystemCreateCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

final class NvmeWriteFence {
  NvmeWriteFence._();
  static final Expando<bool> _uncertain = Expando<bool>();
  static bool isUncertain(AuthenticatedSession session) =>
      _uncertain[session] == true;
  static void markUncertain(AuthenticatedSession session) =>
      _uncertain[session] = true;
}

enum NvmeCreateOutcome { completed, rejected, unknown }

final class NvmeCreateResult {
  const NvmeCreateResult(this.outcome, this.message);
  final NvmeCreateOutcome outcome;
  final String message;
}

final class NvmeCreateReview {
  NvmeCreateReview._({
    required this.endpoint,
    required this.name,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, name, proof;
  final DateTime issuedAt;
  String get confirmation => 'CREATE NVME SUBSYSTEM $name';
}

final class _Snapshot {
  const _Snapshot(this.topology, this.hosts);
  final NvmeOverview topology;
  final NvmeHostOverview hosts;
}

/// Requests only an unbound subsystem. Host, port and namespace associations
/// are checked in readback with separate bounded inventories.
/// It never uses a generic schema form and never changes existing objects.
final class NvmeSubsystemCreateCoordinator {
  NvmeSubsystemCreateCoordinator({
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
  final _issued = <NvmeCreateReview>{};
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
        'nvmet.subsys.create',
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
      throw StateError(
        'NVMe-oF references are unresolved. Reload before editing.',
      );
    }
    return _Snapshot(topology, hosts);
  }

  Future<NvmeCreateReview> prepare(String name) async {
    _guard();
    if (!available ||
        _busy ||
        name.trim() != name ||
        name.isEmpty ||
        name.length > 120 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Enter a new name of 1–120 characters without surrounding whitespace or controls.',
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
      _guard();
      if (before.topology.subsystems.length >= 99) {
        throw StateError(
          'The bounded subsystem inventory cannot verify another create.',
        );
      }
      if (before.topology.subsystems.any(
        (row) => row.name.toLowerCase() == name.toLowerCase(),
      )) {
        throw StateError('A subsystem with this name is already configured.');
      }
      final review = NvmeCreateReview._(
        endpoint: session.endpoint!,
        name: name,
        proof: _proof(before),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe-oF preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeCreateReview review) => _issued.remove(review);

  Future<NvmeCreateResult> execute(
    NvmeCreateReview review,
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
      return const NvmeCreateResult(
        NvmeCreateOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeCreateResult(
        NvmeCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _guard();
      if (before.topology.subsystems.length >= 99 ||
          _proof(before) != review.proof) {
        return const NvmeCreateResult(
          NvmeCreateOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.subsys.create');
      if (method == null || !method.supported) {
        return const NvmeCreateResult(
          NvmeCreateOutcome.rejected,
          'Creation method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            {'name': review.name, 'allow_any_host': false},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmeCreateResult(
          NvmeCreateOutcome.rejected,
          'The server denied creation. No subsystem was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final created = response.value as Map;
      final id = created['id'];
      if (id is! int ||
          id <= 0 ||
          created['name'] != review.name ||
          created['allow_any_host'] != false) {
        return _unknown();
      }
      final after = await _snapshot();
      _guard();
      if (after.topology.subsystems.length !=
              before.topology.subsystems.length + 1 ||
          after.topology.subsystems
                  .where(
                    (s) =>
                        s.id == id && s.name == review.name && !s.allowAnyHost,
                  )
                  .length !=
              1 ||
          after.topology.namespaces.any((n) => n.subsystemId == id) ||
          after.topology.portMappings.any((m) => m.subsystemId == id) ||
          after.hosts.mappings.any((m) => m.subsystemId == id) ||
          _proofWithout(after, id) != _proof(before)) {
        return _unknown();
      }
      return NvmeCreateResult(
        NvmeCreateOutcome.completed,
        'Unbound subsystem #$id was found in fresh reads. No host, port or namespace association was returned; client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeCreateResult(
              NvmeCreateOutcome.rejected,
              'NVMe-oF preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeCreateResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeCreateResult(
      NvmeCreateOutcome.unknown,
      'Creation may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}

String _proof(_Snapshot value) => _proofWithout(value, null);

String _proofWithout(_Snapshot snapshot, int? omitSubsystemId) {
  final value = snapshot.topology;
  final subsystems =
      value.subsystems
          .where((s) => s.id != omitSubsystemId)
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
            ],
          )
          .toList()
        ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
  final ports = value.ports.map((p) => [p.id, p.transport, p.enabled]).toList()
    ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
  final namespaces =
      value.namespaces
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
  final mappings =
      value.portMappings.map((m) => [m.id, m.portId, m.subsystemId]).toList()
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
    mappings,
    hosts,
    hostMappings,
  ]);
}
