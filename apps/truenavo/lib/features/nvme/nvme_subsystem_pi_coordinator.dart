import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemPiCoordinatorProvider =
    Provider<NvmeSubsystemPiCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmeSubsystemPiCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum NvmePiChoice { serverDefault, on, off }

extension on NvmePiChoice {
  bool? get wireValue => switch (this) {
    NvmePiChoice.serverDefault => null,
    NvmePiChoice.on => true,
    NvmePiChoice.off => false,
  };

  String get label => switch (this) {
    NvmePiChoice.serverDefault => 'server default',
    NvmePiChoice.on => 'on',
    NvmePiChoice.off => 'off',
  };

  String get confirmationToken => switch (this) {
    NvmePiChoice.serverDefault => 'DEFAULT',
    NvmePiChoice.on => 'ON',
    NvmePiChoice.off => 'OFF',
  };
}

enum NvmePiOutcome { completed, rejected, unknown }

final class NvmePiResult {
  const NvmePiResult(this.outcome, this.message);
  final NvmePiOutcome outcome;
  final String message;
}

final class NvmePiReview {
  NvmePiReview._({
    required this.endpoint,
    required this.id,
    required this.name,
    required this.subnqn,
    required this.oldPi,
    required this.choice,
    required this.proof,
    required this.issuedAt,
  });

  final String endpoint, name, subnqn, proof;
  final int id;
  final bool? oldPi;
  final NvmePiChoice choice;
  final DateTime issuedAt;

  String get oldLabel => switch (oldPi) {
    true => 'on',
    false => 'off',
    null => 'server default',
  };
  String get newLabel => choice.label;
  String get confirmation =>
      'SET NVME PI $id $name ${choice.confirmationToken}';
}

/// Changes only PI on an unbound restricted subsystem. Inventory reads are
/// sequential and cannot exclude another administrator's concurrent change.
final class NvmeSubsystemPiCoordinator {
  NvmeSubsystemPiCoordinator({
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
  final _issued = <NvmePiReview>{};
  bool _busy = false;

  bool get locked => _busy || NvmeWriteFence.isUncertain(session);
  // The generic host query is intentionally policy-blocked; the typed,
  // secret-stripping hostsApi path reads the advertised method instead.
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
        !target.piReported ||
        snapshot.topology.namespaces.any((n) => n.subsystemId == id) ||
        snapshot.topology.portMappings.any((m) => m.subsystemId == id) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == id)) {
      throw StateError(
        'Only a restricted subsystem with a returned NQN and PI setting and no namespace, port or host associations can be edited. Nothing was sent.',
      );
    }
    return target;
  }

  Future<NvmePiReview> prepare(int id, NvmePiChoice choice) async {
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
      if (target.piEnable == choice.wireValue) {
        throw StateError(
          'The requested PI setting is already configured. Nothing was sent.',
        );
      }
      final review = NvmePiReview._(
        endpoint: session.endpoint!,
        id: id,
        name: target.name,
        subnqn: target.subnqn!,
        oldPi: target.piEnable,
        choice: choice,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe-oF PI preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmePiReview review) => _issued.remove(review);

  Future<NvmePiResult> execute(NvmePiReview review, String confirmation) async {
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
      return const NvmePiResult(
        NvmePiOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmePiResult(
        NvmePiOutcome.rejected,
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
          target.piEnable != review.oldPi ||
          before.proof() != review.proof) {
        return const NvmePiResult(
          NvmePiOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.subsys.update');
      if (method == null || !method.supported) {
        return const NvmePiResult(
          NvmePiOutcome.rejected,
          'Update method is unavailable. Nothing was sent.',
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
        return const NvmePiResult(
          NvmePiOutcome.rejected,
          'The server denied the PI change. No change was confirmed.',
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
          !returned.containsKey('pi_enable') ||
          returned['pi_enable'] != review.choice.wireValue) {
        return _unknown();
      }
      final after = await _snapshot();
      final changed = after.topology.subsystems.where((s) => s.id == review.id);
      if (changed.length != 1 ||
          changed.single.name != review.name ||
          changed.single.subnqn != review.subnqn ||
          changed.single.allowAnyHost ||
          !changed.single.piReported ||
          changed.single.piEnable != review.choice.wireValue ||
          changed.single.anaReported != target.anaReported ||
          changed.single.ana != target.ana ||
          changed.single.qidReported != target.qidReported ||
          changed.single.qidMax != target.qidMax ||
          changed.single.ieeeOuiReported != target.ieeeOuiReported ||
          changed.single.ieeeOui != target.ieeeOui ||
          after.topology.subsystems.length !=
              before.topology.subsystems.length ||
          after.proof(omitSubsystemId: review.id) !=
              before.proof(omitSubsystemId: review.id) ||
          after.topology.namespaces.any((n) => n.subsystemId == review.id) ||
          after.topology.portMappings.any((m) => m.subsystemId == review.id) ||
          after.hosts.mappings.any((m) => m.subsystemId == review.id)) {
        return _unknown();
      }
      return NvmePiResult(
        NvmePiOutcome.completed,
        'Subsystem #${review.id} PI is configured ${review.newLabel} in a fresh read. Data integrity was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmePiResult(
              NvmePiOutcome.rejected,
              'NVMe-oF PI preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmePiResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmePiResult(
      NvmePiOutcome.unknown,
      'PI may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
