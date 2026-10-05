import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiTargetCreateCoordinatorProvider =
    Provider<IscsiTargetCreateCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiTargetCreateCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiTargetCreateOutcome { completed, rejected, unknown }

final class IscsiTargetCreateResult {
  const IscsiTargetCreateResult(this.outcome, this.message);
  final IscsiTargetCreateOutcome outcome;
  final String message;
}

final class IscsiTargetCreateReview {
  IscsiTargetCreateReview._({
    required this.endpoint,
    required this.name,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, name, proof;
  final DateTime issuedAt;
  String get confirmation => 'CREATE ISCSI TARGET $name';
}

final class _TargetRow {
  const _TargetRow(this.id, this.name, this.mode, this.groups, this.networks);
  final int id;
  final String name, mode;
  final List groups, networks;
}

final class _TargetSnapshot {
  const _TargetSnapshot(this.rows, this.service, this.noSessions);
  final List<_TargetRow> rows;
  final IscsiServiceStatus service;
  final bool noSessions;
  String get proof => jsonEncode([
    for (final row in rows) [row.id, row.name],
    service.state,
    service.enabledOnBoot,
    noSessions,
  ]);
}

/// Creates only an unbound iSCSI target. No portal, initiator, CHAP or LUN is
/// selected, and a stopped service with zero sessions is required twice.
final class IscsiTargetCreateCoordinator {
  IscsiTargetCreateCoordinator({
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
  final _issued = <IscsiTargetCreateReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.target.query',
        'iscsi.target.validate_name',
        'iscsi.target.create',
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

  Future<Object?> _read(String method, List<Object?> arguments) async {
    _guard();
    final result = await api.invokeAdmin(
      AdminRequest(method: _method(method), arguments: arguments),
    );
    _guard();
    if (result is! AdminCompleted) {
      throw StateError('The iSCSI preflight is unavailable.');
    }
    return result.value;
  }

  Future<_TargetSnapshot> _snapshot() async {
    final raw = await _read('iscsi.target.query', const []);
    if (raw is! List || raw.length >= 100 || raw.any((row) => row is! Map)) {
      throw StateError('The target inventory is incomplete.');
    }
    final rows = <_TargetRow>[];
    final ids = <int>{};
    for (final item in raw) {
      final row = item as Map;
      final id = row['id'];
      final name = row['name'];
      final mode = row['mode'];
      final groups = row['groups'];
      final networks = row['auth_networks'];
      if (id is! int ||
          id < 1 ||
          !ids.add(id) ||
          name is! String ||
          name.isEmpty ||
          name.length > 120 ||
          (mode != 'ISCSI' && mode != 'FC' && mode != 'BOTH') ||
          groups is! List ||
          groups.length >= 100 ||
          networks is! List ||
          networks.length >= 100) {
        throw StateError('The target inventory is incomplete.');
      }
      rows.add(_TargetRow(id, name, mode as String, groups, networks));
    }
    rows.sort((a, b) => a.id.compareTo(b.id));
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
    return _TargetSnapshot(List.unmodifiable(rows), service, sessions.isEmpty);
  }

  Future<void> _validateName(String name) async {
    final value = await _read('iscsi.target.validate_name', [name]);
    if (value != null) {
      throw StateError('The server did not accept this target name.');
    }
  }

  void _requireStopped(_TargetSnapshot snapshot) {
    if (snapshot.service.state != 'STOPPED' || !snapshot.noSessions) {
      throw StateError(
        'Stop iSCSI and disconnect all clients independently before creating a target.',
      );
    }
  }

  Future<IscsiTargetCreateReview> prepare(String name) async {
    _guard();
    if (!available ||
        _busy ||
        name.isEmpty ||
        name.length > 120 ||
        name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Enter a target name of 1–120 characters without control characters.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      _requireStopped(snapshot);
      if (snapshot.rows.length >= 99) {
        throw StateError(
          'The bounded target inventory has no room for a verified create readback.',
        );
      }
      if (snapshot.rows.any(
        (row) => row.name.toLowerCase() == name.toLowerCase(),
      )) {
        throw StateError('A target with this name is already configured.');
      }
      await _validateName(name);
      final review = IscsiTargetCreateReview._(
        endpoint: session.endpoint!,
        name: name,
        proof: snapshot.proof,
        issuedAt: _now().toUtc(),
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

  void cancel(IscsiTargetCreateReview review) => _issued.remove(review);

  Future<IscsiTargetCreateResult> execute(
    IscsiTargetCreateReview review,
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
      return const IscsiTargetCreateResult(
        IscsiTargetCreateOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiTargetCreateResult(
        IscsiTargetCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _requireStopped(before);
      if (before.rows.length >= 99) {
        return const IscsiTargetCreateResult(
          IscsiTargetCreateOutcome.rejected,
          'The bounded target inventory cannot verify another target. Nothing was sent.',
        );
      }
      if (before.proof != review.proof) {
        return const IscsiTargetCreateResult(
          IscsiTargetCreateOutcome.rejected,
          'Target or service state changed since review. Nothing was sent.',
        );
      }
      await _validateName(review.name);
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.target.create'),
          arguments: [
            {
              'name': review.name,
              'mode': 'ISCSI',
              'groups': <Object?>[],
              'auth_networks': <Object?>[],
            },
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiTargetCreateResult(
          IscsiTargetCreateOutcome.rejected,
          'The server denied creation. No target was confirmed.',
        );
      }
      if (result is! AdminCompleted || result.value is! Map) {
        return _unknown();
      }
      final created = result.value as Map;
      final id = created['id'];
      if (id is! int || id < 1 || created['name'] != review.name) {
        return _unknown();
      }
      final after = await _snapshot();
      _requireStopped(after);
      final matches = after.rows.where((row) => row.id == id).toList();
      if (matches.length != 1 ||
          matches.single.name != review.name ||
          matches.single.mode != 'ISCSI' ||
          matches.single.groups.isNotEmpty ||
          matches.single.networks.isNotEmpty ||
          after.rows.length != before.rows.length + 1) {
        return _unknown();
      }
      final existingAfter = after.rows.where((row) => row.id != id).toList();
      if (jsonEncode([
            for (final row in existingAfter) [row.id, row.name],
          ]) !=
          jsonEncode([
            for (final row in before.rows) [row.id, row.name],
          ])) {
        return _unknown();
      }
      return IscsiTargetCreateResult(
        IscsiTargetCreateOutcome.completed,
        'Target #$id was found with no access groups in a fresh read. Client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiTargetCreateResult(
              IscsiTargetCreateOutcome.rejected,
              'The target preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiTargetCreateResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiTargetCreateResult(
      IscsiTargetCreateOutcome.unknown,
      'Creation may have changed the server. Do not retry; inspect the original server and reconnect.',
    );
  }
}
