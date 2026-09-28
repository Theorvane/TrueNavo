import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_tcp_bind_address.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePortCreateCoordinatorProvider = Provider<NvmePortCreateCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession) {
    return null;
  }
  return NvmePortCreateCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

/// Deliberately excludes wildcard, scoped/link-local IPv6, RDMA and FC.
final class NvmePortCreateChoice {
  const NvmePortCreateChoice(this.address, this.servicePort);
  final String address;
  final int servicePort;
  bool get valid =>
      servicePort >= 1024 &&
      servicePort <= 65535 &&
      NvmeTcpBindAddress.parse(address)?.creatable == true;
  String get bindingLabel => address.contains(':')
      ? '[$address]:$servicePort'
      : '$address:$servicePort';
}

enum NvmePortCreateOutcome { completed, rejected, unknown }

final class NvmePortCreateResult {
  const NvmePortCreateResult(this.outcome, this.message);
  final NvmePortCreateOutcome outcome;
  final String message;
}

final class NvmePortCreateReview {
  NvmePortCreateReview._(this.endpoint, this.choice, this.proof, this.issuedAt);
  final String endpoint, proof;
  final NvmePortCreateChoice choice;
  final DateTime issuedAt;
  String get confirmation => 'CREATE DISABLED NVME TCP ${choice.bindingLabel}';
}

final class _Binding {
  const _Binding(
    this.id,
    this.transport,
    this.address,
    this.service,
    this.enabled,
  );
  final int id;
  final String transport, address;
  final Object? service;
  final bool enabled;
  List<Object?> get proof => [id, transport, address, service, enabled];
  bool matches(NvmePortCreateChoice choice) =>
      transport == 'TCP' &&
      NvmeTcpBindAddress.equivalent(address, choice.address) &&
      service == choice.servicePort &&
      !enabled;
}

final class _Snapshot {
  const _Snapshot(this.inventory, this.bindings);
  final NvmeMutationSnapshot inventory;
  final List<_Binding> bindings;
  String proof({int? omitPortId}) => jsonEncode([
    inventory.proof(omitPortId: omitPortId),
    for (final b in bindings)
      if (b.id != omitPortId) b.proof,
  ]);
}

/// Creates only a disabled TCP/IP port, never mappings or existing objects.
/// Bounded sequential reads cannot exclude a concurrent administrator's race.
final class NvmePortCreateCoordinator {
  NvmePortCreateCoordinator({
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
  final _issued = <NvmePortCreateReview>{};
  bool _busy = false;
  bool get locked => _busy || NvmeWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      api.adminCatalog.method('nvmet.host.query') != null &&
      [
        'nvmet.host_subsys.query',
        'nvmet.subsys.query',
        'nvmet.port.query',
        'nvmet.namespace.query',
        'nvmet.port_subsys.query',
        'nvmet.port.create',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  void _guard() {
    if (!isCurrent() ||
        session.endpoint == null ||
        NvmeWriteFence.isUncertain(session)) {
      throw StateError(
        'Connection changed or an NVMe-oF change is unverified. Nothing was sent.',
      );
    }
  }

  Future<_Snapshot> _snapshot() async {
    final inventory = await NvmeMutationSnapshot.load(
      api: api,
      hostsApi: hostsApi,
      isCurrent: () => isCurrent() && session.endpoint != null,
    );
    _guard();
    final method = api.adminCatalog.method('nvmet.port.query');
    if (method == null || !method.supported) {
      throw StateError('Port inventory unavailable.');
    }
    final response = await api.invokeAdmin(
      AdminRequest(
        method: method,
        arguments: [
          const [],
          {
            'select': [
              'id',
              'addr_trtype',
              'addr_traddr',
              'addr_trsvcid',
              'enabled',
            ],
            'limit': 101,
          },
        ],
      ),
    );
    _guard();
    if (response is! AdminCompleted || response.value is! List) {
      throw StateError('Port binding inventory unavailable.');
    }
    final rows = response.value as List;
    if (rows.length > 100) {
      throw StateError('Port inventory exceeds the verification bound.');
    }
    final bindings = <_Binding>[];
    final ids = <int>{};
    for (final row in rows) {
      if (row is! Map) throw StateError('Malformed port binding inventory.');
      final id = row['id'],
          transport = row['addr_trtype'],
          address = row['addr_traddr'];
      final service = row['addr_trsvcid'], enabled = row['enabled'];
      if (id is! int ||
          id <= 0 ||
          !ids.add(id) ||
          !const {'TCP', 'RDMA', 'FC'}.contains(transport) ||
          address is! String ||
          address.length > 256 ||
          address.contains(RegExp(r'[\x00-\x1f\x7f]')) ||
          enabled is! bool ||
          !row.containsKey('addr_trsvcid') ||
          (service != null && service is! int && service is! String) ||
          (service is String &&
              (service.length > 128 ||
                  service.contains(RegExp(r'[\x00-\x1f\x7f]'))))) {
        throw StateError('Malformed port binding inventory.');
      }
      bindings.add(
        _Binding(id, transport as String, address, service, enabled),
      );
    }
    bindings.sort((a, b) => a.id.compareTo(b.id));
    final ports = inventory.topology.ports;
    if (ports.length != bindings.length ||
        bindings.any(
          (b) => !ports.any(
            (p) =>
                p.id == b.id &&
                p.transport == b.transport &&
                p.enabled == b.enabled,
          ),
        )) {
      throw StateError('Port inventories disagree. Nothing was sent.');
    }
    return _Snapshot(inventory, bindings);
  }

  void _canCreate(_Snapshot snapshot, NvmePortCreateChoice choice) {
    if (snapshot.bindings.length >= 100) {
      throw StateError(
        'The bounded port inventory cannot verify another create.',
      );
    }
    if (snapshot.bindings.any(
      (b) =>
          b.transport == 'TCP' && NvmeTcpBindAddress.parse(b.address) == null,
    )) {
      throw StateError(
        'An existing TCP bind address cannot be compared safely. Nothing was sent.',
      );
    }
    if (snapshot.bindings.any(
      (b) =>
          b.transport == 'TCP' &&
          b.service.toString() == choice.servicePort.toString() &&
          (NvmeTcpBindAddress.equivalent(b.address, choice.address) ||
              NvmeTcpBindAddress.parse(b.address)?.wildcard == true),
    )) {
      throw StateError(
        'An existing TCP port conflicts with this binding. Nothing was sent.',
      );
    }
  }

  Future<NvmePortCreateReview> prepare(NvmePortCreateChoice choice) async {
    _guard();
    if (!available || _busy || !choice.valid) {
      throw StateError(
        'Enter an explicit IPv4 or global/ULA IPv6 address and a port from 1024 to 65535. Nothing was sent.',
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
      _canCreate(before, choice);
      final review = NvmePortCreateReview._(
        session.endpoint!,
        choice,
        before.proof(),
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('Port creation preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmePortCreateReview review) => _issued.remove(review);

  Future<NvmePortCreateResult> execute(
    NvmePortCreateReview review,
    String confirmation,
  ) async {
    final issued = _issued.remove(review), now = _now().toUtc();
    if (!issued ||
        _busy ||
        !available ||
        !isCurrent() ||
        NvmeWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const NvmePortCreateResult(
        NvmePortCreateOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmePortCreateResult(
        NvmePortCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _canCreate(before, review.choice);
      if (before.proof() != review.proof) {
        return const NvmePortCreateResult(
          NvmePortCreateOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.port.create');
      if (method == null || !method.supported) {
        throw StateError('Port creation is unavailable.');
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            {
              'addr_trtype': 'TCP',
              'addr_traddr': review.choice.address,
              'addr_trsvcid': review.choice.servicePort,
              'enabled': false,
            },
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmePortCreateResult(
          NvmePortCreateOutcome.rejected,
          'The server denied creation. No port was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final row = response.value as Map, id = row['id'];
      final returnedPort = NvmePort.parse(row);
      if (returnedPort == null ||
          id is! int ||
          id <= 0 ||
          before.bindings.any((b) => b.id == id) ||
          row['addr_trtype'] != 'TCP' ||
          row['addr_traddr'] is! String ||
          !NvmeTcpBindAddress.equivalent(
            row['addr_traddr'] as String,
            review.choice.address,
          ) ||
          row['addr_trsvcid'] != review.choice.servicePort ||
          row['enabled'] != false) {
        return _unknown();
      }
      final after = await _snapshot();
      final binding = after.bindings.where((b) => b.id == id).singleOrNull;
      final port = after.inventory.topology.portById(id);
      if (binding == null ||
          !binding.matches(review.choice) ||
          port == null ||
          port.inlineDataSizeReported != returnedPort.inlineDataSizeReported ||
          port.inlineDataSize != returnedPort.inlineDataSize ||
          port.maxQueueSizeReported != returnedPort.maxQueueSizeReported ||
          port.maxQueueSize != returnedPort.maxQueueSize ||
          port.piReported != returnedPort.piReported ||
          port.piEnable != returnedPort.piEnable ||
          after.bindings.length != before.bindings.length + 1 ||
          after.proof(omitPortId: id) != before.proof() ||
          after.inventory.topology.portMappings.any((m) => m.portId == id)) {
        return _unknown();
      }
      return NvmePortCreateResult(
        NvmePortCreateOutcome.completed,
        'Disabled unassociated TCP port #$id was confirmed in fresh reads. Listener reachability was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmePortCreateResult(
              NvmePortCreateOutcome.rejected,
              'Port creation preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePortCreateResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePortCreateResult(
      NvmePortCreateOutcome.unknown,
      'Port creation may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
