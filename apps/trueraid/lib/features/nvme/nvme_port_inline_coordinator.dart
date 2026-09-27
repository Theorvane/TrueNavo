import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmePortInlineCoordinatorProvider = Provider<NvmePortInlineCoordinator?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedAdminSession ||
      repository is! AuthenticatedNvmeHostSession) {
    return null;
  }
  return NvmePortInlineCoordinator(
    session: session!,
    api: repository as AuthenticatedAdminSession,
    hostsApi: repository as AuthenticatedNvmeHostSession,
    lock: ref.read(serverOperationLockProvider),
    isCurrent: () =>
        identical(ref.read(dashboardActiveSessionProvider), session),
  );
});

final class NvmePortInlineChoice {
  const NvmePortInlineChoice(this.wireValue);
  final int? wireValue;
  bool get valid =>
      wireValue == null || (wireValue! >= 0 && wireValue! <= 2147483647);
  String get label => wireValue?.toString() ?? 'server default';
  String get token => wireValue?.toString() ?? 'DEFAULT';
}

enum NvmePortInlineOutcome { completed, rejected, unknown }

final class NvmePortInlineResult {
  const NvmePortInlineResult(this.outcome, this.message);
  final NvmePortInlineOutcome outcome;
  final String message;
}

final class NvmePortInlineReview {
  NvmePortInlineReview._({
    required this.endpoint,
    required this.id,
    required this.transport,
    required this.oldInline,
    required this.choice,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, transport, proof;
  final int id;
  final DateTime issuedAt;
  final int? oldInline;
  final NvmePortInlineChoice choice;
  String get oldLabel => oldInline?.toString() ?? 'server default';
  String get newLabel => choice.label;
  String get confirmation =>
      'SET NVME PORT INLINE $id $transport ${choice.token}';
}

/// Changes only inline data size on a disabled port without a subsystem association.
/// These separate reads cannot exclude a concurrent administrator's race.
final class NvmePortInlineCoordinator {
  NvmePortInlineCoordinator({
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
  final _issued = <NvmePortInlineReview>{};
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
        !port.inlineDataSizeReported ||
        snapshot.topology.portMappings.any((m) => m.portId == id)) {
      throw StateError(
        'Only an existing disabled port with a returned inline data size field and no subsystem associations can be edited. Nothing was sent.',
      );
    }
    return port;
  }

  Future<NvmePortInlineReview> prepare(
    int id,
    NvmePortInlineChoice choice,
  ) async {
    _guard();
    if (!available || _busy || id <= 0 || !choice.valid) {
      throw StateError(
        'Select a positive port ID and inline data size from 0 to 2147483647, or server default. Nothing was sent.',
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
      if (port.inlineDataSize == choice.wireValue) {
        throw StateError(
          'The requested port inline data size setting is already configured. Nothing was sent.',
        );
      }
      final review = NvmePortInlineReview._(
        endpoint: session.endpoint!,
        id: port.id,
        transport: port.transport,
        oldInline: port.inlineDataSize,
        choice: choice,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError(
        'NVMe-oF port inline data size preflight failed. Nothing was sent.',
      );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmePortInlineReview review) => _issued.remove(review);

  Future<NvmePortInlineResult> execute(
    NvmePortInlineReview review,
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
      return const NvmePortInlineResult(
        NvmePortInlineOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmePortInlineResult(
        NvmePortInlineOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final port = _target(before, review.id);
      if (port.transport != review.transport ||
          port.inlineDataSize != review.oldInline ||
          before.proof() != review.proof) {
        return const NvmePortInlineResult(
          NvmePortInlineOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.port.update');
      if (method == null || !method.supported) {
        return const NvmePortInlineResult(
          NvmePortInlineOutcome.rejected,
          'Port update method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'inline_data_size': review.choice.wireValue},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmePortInlineResult(
          NvmePortInlineOutcome.rejected,
          'The server denied port inline data size. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = response.value as Map;
      if (returned['id'] != review.id ||
          returned['addr_trtype'] != review.transport ||
          returned['enabled'] != false ||
          !returned.containsKey('inline_data_size') ||
          returned['inline_data_size'] != review.choice.wireValue) {
        return _unknown();
      }
      final after = await _snapshot();
      final changed = after.topology.ports.where((p) => p.id == review.id);
      if (changed.length != 1 ||
          changed.single.transport != review.transport ||
          changed.single.enabled ||
          changed.single.maxQueueSizeReported != port.maxQueueSizeReported ||
          changed.single.maxQueueSize != port.maxQueueSize ||
          changed.single.piReported != port.piReported ||
          changed.single.piEnable != port.piEnable ||
          !changed.single.inlineDataSizeReported ||
          changed.single.inlineDataSize != review.choice.wireValue ||
          after.topology.ports.length != before.topology.ports.length ||
          after.proof(omitPortId: review.id) !=
              before.proof(omitPortId: review.id) ||
          after.topology.portMappings.any((m) => m.portId == review.id)) {
        return _unknown();
      }
      return NvmePortInlineResult(
        NvmePortInlineOutcome.completed,
        'Disabled unassociated port #${review.id} inline data size is ${review.newLabel} in a fresh read. Client inline-data behavior was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmePortInlineResult(
              NvmePortInlineOutcome.rejected,
              'NVMe-oF port inline data size preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePortInlineResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePortInlineResult(
      NvmePortInlineOutcome.unknown,
      'Port inline data size may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
