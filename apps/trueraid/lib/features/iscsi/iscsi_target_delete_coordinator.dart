import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiTargetDeleteCoordinatorProvider =
    Provider<IscsiTargetDeleteCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiTargetDeleteCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiTargetDeleteOutcome { completed, rejected, unknown }

final class IscsiTargetDeleteResult {
  const IscsiTargetDeleteResult(this.outcome, this.message);
  final IscsiTargetDeleteOutcome outcome;
  final String message;
}

final class IscsiTargetDeleteReview {
  IscsiTargetDeleteReview._(
    this.endpoint,
    this.id,
    this.name,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, name, proof;
  final int id;
  final DateTime issuedAt;
  String get confirmation => 'DELETE ISCSI TARGET #$id $name';
}

final class _Target {
  const _Target(this.id, this.name, this.mode, this.groups, this.networks);
  final int id;
  final String name, mode;
  final List groups, networks;
  Object get proof => [id, name, mode, groups, networks];
}

final class _Snapshot {
  const _Snapshot(this.targets, this.mappings, this.service, this.sessions);
  final List<_Target> targets;
  final List<List<int>> mappings;
  final IscsiServiceStatus service;
  final bool sessions;
  String get proof => jsonEncode([
    for (final target in targets) target.proof,
    mappings,
    service.state,
    service.enabledOnBoot,
    sessions,
  ]);
}

/// Deletes only a stopped, unbound, unmapped iSCSI target. A fresh server
/// snapshot is required at review and immediately before the one write.
final class IscsiTargetDeleteCoordinator {
  IscsiTargetDeleteCoordinator({
    required this.session,
    required this.api,
    required this.lock,
    required this.isCurrent,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AuthenticatedSession session;
  final AuthenticatedAdminSession api;
  final ServerOperationLock lock;
  final bool Function() isCurrent;
  final DateTime Function() _now;
  final _issued = <IscsiTargetDeleteReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.target.query',
        'iscsi.targetextent.query',
        'iscsi.target.delete',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI target methods are unavailable.');
    }
    return method;
  }

  void _guard() {
    if (!isCurrent() || session.endpoint == null) {
      throw StateError('The server connection changed.');
    }
    if (IscsiWriteFence.isUncertain(session)) {
      throw StateError(
        'An iSCSI update is unverified. Reconnect before editing.',
      );
    }
  }

  Future<Object?> _read(String name, List<Object?> args) async {
    _guard();
    final result = await api.invokeAdmin(
      AdminRequest(method: _method(name), arguments: args),
    );
    _guard();
    if (result is! AdminCompleted) {
      throw StateError('The iSCSI preflight is unavailable.');
    }
    return result.value;
  }

  Future<_Snapshot> _snapshot() async {
    final rawTargets = await _read('iscsi.target.query', const []);
    final rawMappings = await _read('iscsi.targetextent.query', const []);
    if (rawTargets is! List ||
        rawTargets.length >= 100 ||
        rawMappings is! List ||
        rawMappings.length >= 100) {
      throw StateError('The target or LUN inventory is incomplete.');
    }
    final targets = <_Target>[];
    final targetIds = <int>{};
    for (final item in rawTargets) {
      if (item is! Map) throw StateError('The target inventory is incomplete.');
      final id = item['id'];
      final name = item['name'];
      final mode = item['mode'];
      final groups = item['groups'];
      final networks = item['auth_networks'];
      if (id is! int ||
          id < 1 ||
          !targetIds.add(id) ||
          name is! String ||
          name.isEmpty ||
          name.length > 120 ||
          mode is! String ||
          !['ISCSI', 'FC', 'BOTH'].contains(mode) ||
          groups is! List ||
          groups.length >= 100 ||
          networks is! List ||
          networks.length >= 100) {
        throw StateError('The target inventory is incomplete.');
      }
      targets.add(_Target(id, name, mode, groups, networks));
    }
    targets.sort((a, b) => a.id.compareTo(b.id));
    final mappings = <List<int>>[];
    final mappingIds = <int>{};
    for (final item in rawMappings) {
      if (item is! Map) throw StateError('The LUN inventory is incomplete.');
      final id = item['id'];
      final target = item['target'];
      final extent = item['extent'];
      final lun = item['lunid'];
      if (id is! int ||
          id < 1 ||
          !mappingIds.add(id) ||
          target is! int ||
          target < 1 ||
          extent is! int ||
          extent < 1 ||
          lun is! int ||
          lun < 0) {
        throw StateError('The LUN inventory is incomplete.');
      }
      mappings.add([id, target, extent, lun]);
    }
    mappings.sort((a, b) => a.first.compareTo(b.first));
    final service = IscsiServiceStatus.parse(
      await _read('service.query', const [
        [
          ['service', '=', 'iscsitarget'],
        ],
        {'limit': 2},
      ]),
    );
    final sessions = await _read('iscsi.global.sessions', const []);
    if (service == null || sessions is! List || sessions.length > 100) {
      throw StateError('The iSCSI service or session state is unavailable.');
    }
    return _Snapshot(targets, mappings, service, sessions.isNotEmpty);
  }

  _Target _candidate(_Snapshot snapshot, int id) {
    if (snapshot.service.state != 'STOPPED' || snapshot.sessions) {
      throw StateError(
        'Stop iSCSI and disconnect all clients before deleting a target.',
      );
    }
    final matches = snapshot.targets
        .where((target) => target.id == id)
        .toList();
    if (matches.length != 1) throw StateError('The target is unavailable.');
    final target = matches.single;
    if (target.mode != 'ISCSI' ||
        target.groups.isNotEmpty ||
        target.networks.isNotEmpty ||
        snapshot.mappings.any((mapping) => mapping[1] == id)) {
      throw StateError(
        'Only an iSCSI target with no access groups, networks or LUN mappings can be deleted here.',
      );
    }
    return target;
  }

  Future<IscsiTargetDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id < 1) {
      throw StateError('Target deletion is unavailable.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final target = _candidate(snapshot, id);
      final review = IscsiTargetDeleteReview._(
        session.endpoint!,
        id,
        target.name,
        snapshot.proof,
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The target preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiTargetDeleteReview review) => _issued.remove(review);

  Future<IscsiTargetDeleteResult> execute(
    IscsiTargetDeleteReview review,
    String confirmation,
  ) async {
    final issued = _issued.remove(review);
    final now = _now().toUtc();
    if (!issued ||
        _busy ||
        !isCurrent() ||
        IscsiWriteFence.isUncertain(session) ||
        review.endpoint != session.endpoint ||
        confirmation != review.confirmation ||
        now.isBefore(review.issuedAt) ||
        now.difference(review.issuedAt) >= const Duration(minutes: 5)) {
      return const IscsiTargetDeleteResult(
        IscsiTargetDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiTargetDeleteResult(
        IscsiTargetDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _candidate(before, review.id);
      if (before.proof != review.proof) {
        return const IscsiTargetDeleteResult(
          IscsiTargetDeleteOutcome.rejected,
          'Target, LUN or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.target.delete'),
          arguments: [review.id, false, false],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiTargetDeleteResult(
          IscsiTargetDeleteOutcome.rejected,
          'The server denied deletion. Nothing was confirmed.',
        );
      }
      if (result is! AdminCompleted || result.value != true) return _unknown();
      final after = await _snapshot();
      if (after.service.state != 'STOPPED' ||
          after.service.enabledOnBoot != before.service.enabledOnBoot ||
          after.sessions ||
          after.targets.any((target) => target.id == review.id) ||
          after.targets.length != before.targets.length - 1 ||
          after.mappings.length != before.mappings.length ||
          jsonEncode(after.mappings) != jsonEncode(before.mappings) ||
          jsonEncode([for (final target in after.targets) target.proof]) !=
              jsonEncode([
                for (final target in before.targets)
                  if (target.id != review.id) target.proof,
              ])) {
        return _unknown();
      }
      return IscsiTargetDeleteResult(
        IscsiTargetDeleteOutcome.completed,
        'Target #${review.id} is absent from a fresh inventory. No extents were requested for deletion.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiTargetDeleteResult(
              IscsiTargetDeleteOutcome.rejected,
              'The target preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiTargetDeleteResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiTargetDeleteResult(
      IscsiTargetDeleteOutcome.unknown,
      'Deletion may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
