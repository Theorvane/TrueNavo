import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiInitiatorDeleteCoordinatorProvider =
    Provider<IscsiInitiatorDeleteCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiInitiatorDeleteCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiInitiatorDeleteOutcome { completed, rejected, unknown }

final class IscsiInitiatorDeleteResult {
  const IscsiInitiatorDeleteResult(this.outcome, this.message);
  final IscsiInitiatorDeleteOutcome outcome;
  final String message;
}

final class IscsiInitiatorDeleteReview {
  IscsiInitiatorDeleteReview._({
    required this.endpoint,
    required this.id,
    required this.names,
    required this.comment,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, comment, proof;
  final int id;
  final List<String> names;
  final DateTime issuedAt;
  String get confirmation => 'DELETE ISCSI INITIATOR #$id';
}

final class _Group {
  const _Group(this.id, this.names, this.comment);
  final int id;
  final List<String> names;
  final String comment;
  Object get proof => [id, names, comment];
}

final class _Snapshot {
  const _Snapshot(this.groups, this.targets, this.service);
  final List<_Group> groups;
  final List<Object> targets;
  final IscsiServiceStatus service;
  String get proof => jsonEncode([
    for (final group in groups) group.proof,
    targets,
    service.state,
    service.enabledOnBoot,
  ]);
  bool references(int id) => targets.any(
    (target) =>
        ((target as List)[4] as List).any((group) => (group as List)[1] == id),
  );
}

/// Deletes an unreferenced initiator group only after repeated topology reads.
/// This cannot atomically exclude concurrent edits by other administrators.
final class IscsiInitiatorDeleteCoordinator {
  IscsiInitiatorDeleteCoordinator({
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
  final _issued = <IscsiInitiatorDeleteReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.initiator.query',
        'iscsi.initiator.delete',
        'iscsi.target.query',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI initiator methods are unavailable.');
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
    final rawGroups = await _read('iscsi.initiator.query', const []);
    final rawTargets = await _read('iscsi.target.query', const []);
    if (rawGroups is! List ||
        rawGroups.length >= 100 ||
        rawTargets is! List ||
        rawTargets.length >= 100 ||
        rawGroups.any((row) => row is! Map) ||
        rawTargets.any((row) => row is! Map)) {
      throw StateError('The initiator or target inventory is incomplete.');
    }
    final groups = <_Group>[];
    final groupIds = <int>{};
    for (final item in rawGroups) {
      final row = item as Map;
      final id = row['id'];
      final names = row['initiators'];
      final comment = row['comment'];
      if (id is! int ||
          id < 1 ||
          !groupIds.add(id) ||
          names is! List ||
          names.length >= 100 ||
          names.any(
            (name) =>
                name is! String ||
                name.isEmpty ||
                name.length > 255 ||
                name == '[truncated]' ||
                name == '[redacted]',
          ) ||
          comment is! String ||
          comment.length > 1024 ||
          comment == '[truncated]' ||
          comment == '[redacted]') {
        throw StateError('The initiator inventory is incomplete.');
      }
      groups.add(_Group(id, List<String>.from(names), comment));
    }
    groups.sort((a, b) => a.id.compareTo(b.id));
    final targets = <Object>[];
    final targetIds = <int>{};
    for (final item in rawTargets) {
      final row = item as Map;
      final id = row['id'];
      final name = row['name'];
      final mode = row['mode'];
      final access = row['groups'];
      final networks = row['auth_networks'];
      if (id is! int ||
          id < 1 ||
          !targetIds.add(id) ||
          name is! String ||
          name.isEmpty ||
          name.length > 120 ||
          (mode != 'ISCSI' && mode != 'FC' && mode != 'BOTH') ||
          access is! List ||
          access.length >= 100 ||
          access.any((entry) => entry is! Map) ||
          networks is! List ||
          networks.length >= 100 ||
          networks.any(
            (network) => network is! String || network.length > 255,
          )) {
        throw StateError('The target inventory is incomplete.');
      }
      final refs = <Object>[];
      for (final item in access) {
        final entry = item as Map;
        final portal = entry['portal'];
        final initiator = entry['initiator'];
        final method = entry['authmethod'];
        final auth = entry['auth'];
        if (portal is! int ||
            portal < 1 ||
            (initiator != null && (initiator is! int || initiator < 1)) ||
            method is! String ||
            (auth != null && (auth is! int || auth < 1))) {
          throw StateError('The target access inventory is incomplete.');
        }
        refs.add([portal, initiator, method, auth]);
      }
      targets.add([id, name, mode, networks, refs]);
    }
    targets.sort(
      (a, b) => ((a as List)[0] as int).compareTo((b as List)[0] as int),
    );
    final service = IscsiServiceStatus.parse(
      await _read('service.query', const [
        [
          ['service', '=', 'iscsitarget'],
        ],
        {'limit': 2},
      ]),
    );
    final sessions = await _read('iscsi.global.sessions', const []);
    if (service == null ||
        service.state != 'STOPPED' ||
        sessions is! List ||
        sessions.length > 100 ||
        sessions.isNotEmpty) {
      throw StateError(
        'Stop iSCSI and disconnect all clients before deleting a group.',
      );
    }
    final snapshot = _Snapshot(groups, targets, service);
    if (snapshot.proof.length > 32768) {
      throw StateError('The iSCSI dependency inventory is too large.');
    }
    return snapshot;
  }

  _Group _candidate(_Snapshot snapshot, int id) {
    final matches = snapshot.groups.where((group) => group.id == id).toList();
    if (matches.length != 1) {
      throw StateError('The initiator group is unavailable.');
    }
    final group = matches.single;
    if (group.names.length > 10) {
      throw StateError(
        'This workflow cannot safely review more than 10 initiators.',
      );
    }
    if (snapshot.references(id)) {
      throw StateError(
        'Remove target references independently before deleting the group.',
      );
    }
    return group;
  }

  Future<IscsiInitiatorDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id < 1) {
      throw StateError('Group deletion is unavailable.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final group = _candidate(snapshot, id);
      final review = IscsiInitiatorDeleteReview._(
        endpoint: session.endpoint!,
        id: id,
        names: List.unmodifiable(group.names),
        comment: group.comment,
        proof: snapshot.proof,
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The initiator preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiInitiatorDeleteReview review) => _issued.remove(review);

  Future<IscsiInitiatorDeleteResult> execute(
    IscsiInitiatorDeleteReview review,
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
      return const IscsiInitiatorDeleteResult(
        IscsiInitiatorDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiInitiatorDeleteResult(
        IscsiInitiatorDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _candidate(before, review.id);
      if (before.proof != review.proof) {
        return const IscsiInitiatorDeleteResult(
          IscsiInitiatorDeleteOutcome.rejected,
          'Initiator, target or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.initiator.delete'),
          arguments: [review.id],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiInitiatorDeleteResult(
          IscsiInitiatorDeleteOutcome.rejected,
          'The server denied deletion. Nothing was confirmed.',
        );
      }
      if (result is! AdminCompleted || result.value != true) return _unknown();
      final after = await _snapshot();
      if (after.groups.any((group) => group.id == review.id) ||
          after.groups.length != before.groups.length - 1 ||
          jsonEncode(after.targets) != jsonEncode(before.targets) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot ||
          jsonEncode([for (final group in after.groups) group.proof]) !=
              jsonEncode([
                for (final group in before.groups)
                  if (group.id != review.id) group.proof,
              ])) {
        return _unknown();
      }
      return IscsiInitiatorDeleteResult(
        IscsiInitiatorDeleteOutcome.completed,
        'Initiator group #${review.id} is absent from a fresh inventory; target associations were unchanged.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiInitiatorDeleteResult(
              IscsiInitiatorDeleteOutcome.rejected,
              'The initiator preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiInitiatorDeleteResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiInitiatorDeleteResult(
      IscsiInitiatorDeleteOutcome.unknown,
      'Deletion may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
