import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePortPiCoordinatorProvider = Provider<NvmePortPiCoordinator?>((ref) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession) {
    return null;
  }
  return NvmePortPiCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

enum NvmePortPiChoice { serverDefault, on, off }

extension on NvmePortPiChoice {
  bool? get wireValue => switch (this) {
    NvmePortPiChoice.serverDefault => null,
    NvmePortPiChoice.on => true,
    NvmePortPiChoice.off => false,
  };
  String get label => switch (this) {
    NvmePortPiChoice.serverDefault => 'server default',
    NvmePortPiChoice.on => 'on',
    NvmePortPiChoice.off => 'off',
  };
  String get token => switch (this) {
    NvmePortPiChoice.serverDefault => 'DEFAULT',
    NvmePortPiChoice.on => 'ON',
    NvmePortPiChoice.off => 'OFF',
  };
}

enum NvmePortPiOutcome { completed, rejected, unknown }

final class NvmePortPiResult {
  const NvmePortPiResult(this.outcome, this.message);
  final NvmePortPiOutcome outcome;
  final String message;
}

final class NvmePortPiReview {
  NvmePortPiReview._({
    required this.endpoint,
    required this.id,
    required this.transport,
    required this.oldPi,
    required this.choice,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, transport, proof;
  final int id;
  final DateTime issuedAt;
  final bool? oldPi;
  final NvmePortPiChoice choice;
  String get oldLabel => oldPi == null
      ? 'server default'
      : oldPi!
      ? 'on'
      : 'off';
  String get newLabel => choice.label;
  String get confirmation => 'SET NVME PORT PI $id $transport ${choice.token}';
}

/// Changes only PI on a disabled port without a subsystem association.
/// These separate reads cannot exclude a concurrent administrator's race.
final class NvmePortPiCoordinator {
  NvmePortPiCoordinator({
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
  final _issued = <NvmePortPiReview>{};
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
        port.enabled ||
        !port.piReported ||
        snapshot.topology.portMappings.any((m) => m.portId == id)) {
      throw StateError(
        'Only an existing disabled port with a returned PI field and no subsystem associations can be edited. Nothing was sent.',
      );
    }
    return port;
  }

  Future<NvmePortPiReview> prepare(int id, NvmePortPiChoice choice) async {
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
      if (port.piEnable == choice.wireValue) {
        throw StateError(
          'The requested port PI setting is already configured. Nothing was sent.',
        );
      }
      final review = NvmePortPiReview._(
        endpoint: session.endpoint!,
        id: port.id,
        transport: port.transport,
        oldPi: port.piEnable,
        choice: choice,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe-oF port PI preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmePortPiReview review) => _issued.remove(review);

  Future<NvmePortPiResult> execute(
    NvmePortPiReview review,
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
      return const NvmePortPiResult(
        NvmePortPiOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmePortPiResult(
        NvmePortPiOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final port = _target(before, review.id);
      if (port.transport != review.transport ||
          port.piEnable != review.oldPi ||
          before.proof() != review.proof) {
        return const NvmePortPiResult(
          NvmePortPiOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.port.update');
      if (method == null || !method.supported) {
        return const NvmePortPiResult(
          NvmePortPiOutcome.rejected,
          'Port update method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'pi_enable': review.choice.wireValue},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmePortPiResult(
          NvmePortPiOutcome.rejected,
          'The server denied port PI. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = response.value as Map;
      if (returned['id'] != review.id ||
          returned['addr_trtype'] != review.transport ||
          returned['enabled'] != false ||
          !returned.containsKey('pi_enable') ||
          returned['pi_enable'] != review.choice.wireValue) {
        return _unknown();
      }
      final after = await _snapshot();
      final changed = after.topology.ports.where((p) => p.id == review.id);
      if (changed.length != 1 ||
          changed.single.transport != review.transport ||
          changed.single.enabled ||
          changed.single.inlineDataSizeReported !=
              port.inlineDataSizeReported ||
          changed.single.inlineDataSize != port.inlineDataSize ||
          changed.single.maxQueueSizeReported != port.maxQueueSizeReported ||
          changed.single.maxQueueSize != port.maxQueueSize ||
          !changed.single.piReported ||
          changed.single.piEnable != review.choice.wireValue ||
          after.topology.ports.length != before.topology.ports.length ||
          after.proof(omitPortId: review.id) !=
              before.proof(omitPortId: review.id) ||
          after.topology.portMappings.any((m) => m.portId == review.id)) {
        return _unknown();
      }
      return NvmePortPiResult(
        NvmePortPiOutcome.completed,
        'Disabled unassociated port #${review.id} PI is ${review.newLabel} in a fresh read. Actual data protection was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmePortPiResult(
              NvmePortPiOutcome.rejected,
              'NVMe-oF port PI preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePortPiResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePortPiResult(
      NvmePortPiOutcome.unknown,
      'Port PI may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
