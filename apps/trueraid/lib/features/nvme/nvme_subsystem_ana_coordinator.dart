import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemAnaCoordinatorProvider =
    Provider<NvmeSubsystemAnaCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmeSubsystemAnaCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmeAnaChoice { inherit, on, off }

extension on NvmeAnaChoice {
  bool? get wireValue => switch (this) {
    NvmeAnaChoice.inherit => null,
    NvmeAnaChoice.on => true,
    NvmeAnaChoice.off => false,
  };
  String get label => switch (this) {
    NvmeAnaChoice.inherit => 'inherit',
    NvmeAnaChoice.on => 'on',
    NvmeAnaChoice.off => 'off',
  };
}

enum NvmeAnaOutcome { completed, rejected, unknown }

final class NvmeAnaResult {
  const NvmeAnaResult(this.outcome, this.message);
  final NvmeAnaOutcome outcome;
  final String message;
}

final class NvmeAnaReview {
  NvmeAnaReview._({
    required this.endpoint,
    required this.id,
    required this.name,
    required this.subnqn,
    required this.oldAna,
    required this.choice,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, name, subnqn, proof;
  final int id;
  final bool? oldAna;
  final NvmeAnaChoice choice;
  final DateTime issuedAt;
  String get oldLabel => switch (oldAna) {
    true => 'on',
    false => 'off',
    null => 'inherit',
  };
  String get newLabel => choice.label;
  String get confirmation =>
      'SET NVME ANA $id $name ${choice.label.toUpperCase()}';
}

/// Changes only an unbound restricted subsystem. Sequential reads cannot
/// exclude another administrator changing the server between calls.
final class NvmeSubsystemAnaCoordinator {
  NvmeSubsystemAnaCoordinator({
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
  final _issued = <NvmeAnaReview>{};
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
        'nvmet.subsys.update',
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

  NvmeSubsystem _target(NvmeMutationSnapshot snapshot, int id) {
    final matches = snapshot.topology.subsystems.where((s) => s.id == id);
    if (matches.length != 1) {
      throw StateError('Subsystem was not found. Nothing was sent.');
    }
    final target = matches.single;
    if (target.allowAnyHost ||
        target.subnqn == null ||
        !target.anaReported ||
        snapshot.topology.namespaces.any((n) => n.subsystemId == id) ||
        snapshot.topology.portMappings.any((m) => m.subsystemId == id) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == id)) {
      throw StateError(
        'Only a restricted subsystem with a returned NQN and ANA setting and no namespace, port or host associations can be edited. Nothing was sent.',
      );
    }
    return target;
  }

  Future<NvmeAnaReview> prepare(int id, NvmeAnaChoice choice) async {
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
      if (target.ana == choice.wireValue) {
        throw StateError(
          'The requested ANA setting is already configured. Nothing was sent.',
        );
      }
      final review = NvmeAnaReview._(
        endpoint: session.endpoint!,
        id: id,
        name: target.name,
        subnqn: target.subnqn!,
        oldAna: target.ana,
        choice: choice,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe-oF ANA preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeAnaReview review) => _issued.remove(review);

  Future<NvmeAnaResult> execute(
    NvmeAnaReview review,
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
      return const NvmeAnaResult(
        NvmeAnaOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeAnaResult(
        NvmeAnaOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final target = _target(before, review.id);
      if (target.name != review.name ||
          target.subnqn != review.subnqn ||
          target.ana != review.oldAna ||
          before.proof() != review.proof) {
        return const NvmeAnaResult(
          NvmeAnaOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.subsys.update');
      if (method == null || !method.supported) {
        return const NvmeAnaResult(
          NvmeAnaOutcome.rejected,
          'Update method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'ana': review.choice.wireValue},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmeAnaResult(
          NvmeAnaOutcome.rejected,
          'The server denied the ANA change. No change was confirmed.',
        );
      }
      if (response is! AdminCompleted || response.value is! Map) {
        return _unknown();
      }
      final returned = response.value as Map;
      if (returned['id'] != review.id ||
          returned['name'] != review.name ||
          returned['subnqn'] != review.subnqn ||
          returned['allow_any_host'] != false ||
          !returned.containsKey('ana') ||
          returned['ana'] != review.choice.wireValue) {
        return _unknown();
      }
      final after = await _snapshot();
      final changed = after.topology.subsystems.where((s) => s.id == review.id);
      if (changed.length != 1 ||
          changed.single.name != review.name ||
          changed.single.subnqn != review.subnqn ||
          changed.single.allowAnyHost ||
          !changed.single.anaReported ||
          changed.single.ana != review.choice.wireValue ||
          changed.single.piReported != target.piReported ||
          changed.single.piEnable != target.piEnable ||
          changed.single.qidReported != target.qidReported ||
          changed.single.qidMax != target.qidMax ||
          after.topology.subsystems.length !=
              before.topology.subsystems.length ||
          after.proof(omitSubsystemId: review.id) !=
              before.proof(omitSubsystemId: review.id) ||
          after.topology.namespaces.any((n) => n.subsystemId == review.id) ||
          after.topology.portMappings.any((m) => m.subsystemId == review.id) ||
          after.hosts.mappings.any((m) => m.subsystemId == review.id)) {
        return _unknown();
      }
      return NvmeAnaResult(
        NvmeAnaOutcome.completed,
        'Subsystem #${review.id} ANA is configured ${review.newLabel} in a fresh read. Active paths were not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeAnaResult(
              NvmeAnaOutcome.rejected,
              'NVMe-oF ANA preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeAnaResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeAnaResult(
      NvmeAnaOutcome.unknown,
      'ANA may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
