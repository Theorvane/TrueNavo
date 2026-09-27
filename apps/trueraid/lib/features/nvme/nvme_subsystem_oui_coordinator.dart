import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'nvme_mutation_snapshot.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart' show NvmeWriteFence;

final nvmeSubsystemOuiCoordinatorProvider =
    Provider<NvmeSubsystemOuiCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      final repository = session?.repository;
      if (session?.endpoint == null ||
          repository is! AuthenticatedAdminSession ||
          repository is! AuthenticatedNvmeHostSession) {
        return null;
      }
      return NvmeSubsystemOuiCoordinator(
        session: session!,
        api: repository as AuthenticatedAdminSession,
        hostsApi: repository as AuthenticatedNvmeHostSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

final class NvmeOuiChoice {
  const NvmeOuiChoice(this.wireValue);

  final String? wireValue;
  // Deliberately narrower than the API's string contract: safe to display in
  // an exact confirmation phrase and supported by the read projection.
  bool get valid =>
      wireValue == null ||
      RegExp(r'^[A-Za-z0-9._:-]{1,32}$').hasMatch(wireValue!);
  String get label => wireValue ?? 'server default';
  String get confirmationToken => wireValue ?? 'DEFAULT';
}

enum NvmeOuiOutcome { completed, rejected, unknown }

final class NvmeOuiResult {
  const NvmeOuiResult(this.outcome, this.message);
  final NvmeOuiOutcome outcome;
  final String message;
}

final class NvmeOuiReview {
  NvmeOuiReview._({
    required this.endpoint,
    required this.id,
    required this.name,
    required this.subnqn,
    required this.oldOui,
    required this.choice,
    required this.proof,
    required this.issuedAt,
  });

  final String endpoint, name, subnqn, proof;
  final int id;
  final String? oldOui;
  final NvmeOuiChoice choice;
  final DateTime issuedAt;

  String get oldLabel => oldOui ?? 'server default';
  String get newLabel => choice.label;
  String get confirmation =>
      'SET NVME OUI $id $name ${choice.confirmationToken}';
}

/// Changes only IEEE OUI on an unbound restricted subsystem. Reads are
/// sequential and cannot exclude another administrator's concurrent change.
final class NvmeSubsystemOuiCoordinator {
  NvmeSubsystemOuiCoordinator({
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
  final _issued = <NvmeOuiReview>{};
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
        !target.ieeeOuiReported ||
        snapshot.topology.namespaces.any((n) => n.subsystemId == id) ||
        snapshot.topology.portMappings.any((m) => m.subsystemId == id) ||
        snapshot.hosts.mappings.any((m) => m.subsystemId == id)) {
      throw StateError(
        'Only a restricted subsystem with a returned NQN and IEEE OUI field and no namespace, port or host associations can be edited. Nothing was sent.',
      );
    }
    return target;
  }

  Future<NvmeOuiReview> prepare(int id, NvmeOuiChoice choice) async {
    _guard();
    if (!available || _busy || id <= 0 || !choice.valid) {
      throw StateError(
        'Select a positive subsystem ID and an IEEE OUI of 1–32 safe ASCII characters, or server default. Nothing was sent.',
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
      if (target.ieeeOui == choice.wireValue) {
        throw StateError(
          'The requested OUI setting is already configured. Nothing was sent.',
        );
      }
      final review = NvmeOuiReview._(
        endpoint: session.endpoint!,
        id: id,
        name: target.name,
        subnqn: target.subnqn!,
        oldOui: target.ieeeOui,
        choice: choice,
        proof: before.proof(),
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('NVMe-oF OUI preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(NvmeOuiReview review) => _issued.remove(review);

  Future<NvmeOuiResult> execute(
    NvmeOuiReview review,
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
      return const NvmeOuiResult(
        NvmeOuiOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const NvmeOuiResult(
        NvmeOuiOutcome.rejected,
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
          target.ieeeOui != review.oldOui ||
          before.proof() != review.proof) {
        return const NvmeOuiResult(
          NvmeOuiOutcome.rejected,
          'NVMe-oF configuration changed since review. Nothing was sent.',
        );
      }
      final method = api.adminCatalog.method('nvmet.subsys.update');
      if (method == null || !method.supported) {
        return const NvmeOuiResult(
          NvmeOuiOutcome.rejected,
          'Update method is unavailable. Nothing was sent.',
        );
      }
      sent = true;
      final response = await api.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            review.id,
            {'ieee_oui': review.choice.wireValue},
          ],
        ),
      );
      if (response is AdminFailed &&
          response.reason == AdminFailureReason.denied) {
        return const NvmeOuiResult(
          NvmeOuiOutcome.rejected,
          'The server denied the OUI change. No change was confirmed.',
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
          !returned.containsKey('ieee_oui') ||
          returned['ieee_oui'] != review.choice.wireValue) {
        return _unknown();
      }
      final after = await _snapshot();
      final changed = after.topology.subsystems.where((s) => s.id == review.id);
      if (changed.length != 1 ||
          changed.single.name != review.name ||
          changed.single.subnqn != review.subnqn ||
          changed.single.allowAnyHost ||
          !changed.single.ieeeOuiReported ||
          changed.single.ieeeOui != review.choice.wireValue ||
          changed.single.anaReported != target.anaReported ||
          changed.single.ana != target.ana ||
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
      return NvmeOuiResult(
        NvmeOuiOutcome.completed,
        'Subsystem #${review.id} IEEE OUI is ${review.newLabel} in a fresh read. Client behavior was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const NvmeOuiResult(
              NvmeOuiOutcome.rejected,
              'NVMe-oF OUI preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  NvmeOuiResult _unknown() {
    NvmeWriteFence.markUncertain(session);
    _issued.clear();
    return const NvmeOuiResult(
      NvmeOuiOutcome.unknown,
      'OUI may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
