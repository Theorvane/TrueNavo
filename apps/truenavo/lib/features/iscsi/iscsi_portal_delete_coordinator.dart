import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiPortalDeleteCoordinatorProvider =
    Provider<IscsiPortalDeleteCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiPortalDeleteCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiPortalDeleteOutcome { completed, rejected, unknown }

final class IscsiPortalDeleteResult {
  const IscsiPortalDeleteResult(this.outcome, this.message);
  final IscsiPortalDeleteOutcome outcome;
  final String message;
}

final class IscsiPortalDeleteReview {
  IscsiPortalDeleteReview._({
    required this.endpoint,
    required this.id,
    required this.tag,
    required this.listeners,
    required this.comment,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, comment, proof;
  final int id, tag;
  final List<String> listeners;
  final DateTime issuedAt;
  String get confirmation => 'DELETE ISCSI PORTAL #$id TAG $tag';
}

final class _Snapshot {
  const _Snapshot(this.portals, this.targets, this.service);
  final List<List<Object>> portals, targets;
  final IscsiServiceStatus service;
  String get proof =>
      jsonEncode([portals, targets, service.state, service.enabledOnBoot]);
  List<Object> portal(int id) => portals.singleWhere(
    (row) => row[0] == id,
    orElse: () => throw StateError('The portal is unavailable.'),
  );
  bool references(int id) => targets.any(
    (target) => (target[4] as List).cast<List<Object?>>().any(
      (access) => access[0] == id,
    ),
  );
}

/// Deletes only a portal not referenced by any returned target. Server reads
/// are sequential and cannot exclude concurrent changes by other admins.
final class IscsiPortalDeleteCoordinator {
  IscsiPortalDeleteCoordinator({
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
  final _issued = <IscsiPortalDeleteReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.portal.query',
        'iscsi.portal.delete',
        'iscsi.target.query',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI portal methods are unavailable.');
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
    final rawPortals = await _read('iscsi.portal.query', const []);
    final rawTargets = await _read('iscsi.target.query', const []);
    if (rawPortals is! List ||
        rawPortals.length >= 100 ||
        rawTargets is! List ||
        rawTargets.length >= 100 ||
        rawPortals.any((row) => row is! Map) ||
        rawTargets.any((row) => row is! Map)) {
      throw StateError('The portal or target inventory is incomplete.');
    }
    final portals = <List<Object>>[];
    final portalIds = <int>{};
    final tags = <int>{};
    for (final item in rawPortals) {
      final row = item as Map;
      final id = row['id'], tag = row['tag'];
      final comment = row['comment'], listen = row['listen'];
      if (id is! int ||
          id < 1 ||
          !portalIds.add(id) ||
          tag is! int ||
          tag < 1 ||
          !tags.add(tag) ||
          comment is! String ||
          comment.length > 1024 ||
          comment == '[redacted]' ||
          comment == '[truncated]' ||
          listen is! List ||
          listen.length >= 100 ||
          listen.isEmpty) {
        throw StateError('The portal inventory is incomplete.');
      }
      final listeners = <List<Object>>[];
      for (final item in listen) {
        if (item is! Map ||
            item['ip'] is! String ||
            (item['ip'] as String).isEmpty ||
            (item['ip'] as String).length > 255 ||
            item['ip'] == '[redacted]' ||
            item['ip'] == '[truncated]' ||
            item['port'] is! int ||
            (item['port'] as int) < 1 ||
            (item['port'] as int) > 65535) {
          throw StateError('The portal listeners are incomplete.');
        }
        listeners.add([item['ip'] as String, item['port'] as int]);
      }
      portals.add([id, tag, listeners, comment]);
    }
    portals.sort((a, b) => (a[0] as int).compareTo(b[0] as int));
    final targets = <List<Object>>[];
    final targetIds = <int>{};
    for (final item in rawTargets) {
      final row = item as Map;
      final id = row['id'], name = row['name'], mode = row['mode'];
      final access = row['groups'], networks = row['auth_networks'];
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
      final refs = <List<Object?>>[];
      for (final item in access) {
        final entry = item as Map;
        final portal = entry['portal'], initiator = entry['initiator'];
        final method = entry['authmethod'], auth = entry['auth'];
        if (portal is! int ||
            portal < 1 ||
            (initiator != null && (initiator is! int || initiator < 1)) ||
            method is! String ||
            (auth != null && (auth is! int || auth < 1))) {
          throw StateError('The target access inventory is incomplete.');
        }
        refs.add([portal, initiator, method, auth]);
      }
      targets.add([id, name, mode, List<String>.from(networks), refs]);
    }
    targets.sort((a, b) => (a[0] as int).compareTo(b[0] as int));
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
        'Stop iSCSI and disconnect all clients before deleting a portal.',
      );
    }
    final snapshot = _Snapshot(portals, targets, service);
    if (snapshot.proof.length > 32768) {
      throw StateError('The iSCSI dependency inventory is too large.');
    }
    return snapshot;
  }

  List<Object> _candidate(_Snapshot snapshot, int id) {
    final portal = snapshot.portal(id);
    if (snapshot.references(id)) {
      throw StateError(
        'Remove target references independently before deleting the portal.',
      );
    }
    return portal;
  }

  Future<IscsiPortalDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id < 1) {
      throw StateError('Portal deletion is unavailable.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final portal = _candidate(snapshot, id);
      final listeners = <String>[
        for (final listener in (portal[2] as List).cast<List<Object>>())
          '${listener[0]}:${listener[1]}',
      ];
      final review = IscsiPortalDeleteReview._(
        endpoint: session.endpoint!,
        id: id,
        tag: portal[1] as int,
        listeners: List.unmodifiable(listeners),
        comment: portal[3] as String,
        proof: snapshot.proof,
        issuedAt: _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The portal preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiPortalDeleteReview review) => _issued.remove(review);

  Future<IscsiPortalDeleteResult> execute(
    IscsiPortalDeleteReview review,
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
      return const IscsiPortalDeleteResult(
        IscsiPortalDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiPortalDeleteResult(
        IscsiPortalDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _candidate(before, review.id);
      if (before.proof != review.proof) {
        return const IscsiPortalDeleteResult(
          IscsiPortalDeleteOutcome.rejected,
          'Portal, target or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.portal.delete'),
          arguments: [review.id],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiPortalDeleteResult(
          IscsiPortalDeleteOutcome.rejected,
          'The server denied deletion. Nothing was confirmed.',
        );
      }
      if (result is! AdminCompleted || result.value != true) return _unknown();
      final after = await _snapshot();
      if (after.portals.any((portal) => portal[0] == review.id) ||
          after.portals.length != before.portals.length - 1 ||
          jsonEncode(after.portals) !=
              jsonEncode([
                for (final portal in before.portals)
                  if (portal[0] != review.id) portal,
              ]) ||
          jsonEncode(after.targets) != jsonEncode(before.targets) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return IscsiPortalDeleteResult(
        IscsiPortalDeleteOutcome.completed,
        'Portal #${review.id} is absent from a fresh inventory; target associations were unchanged.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiPortalDeleteResult(
              IscsiPortalDeleteOutcome.rejected,
              'The portal preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiPortalDeleteResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiPortalDeleteResult(
      IscsiPortalDeleteOutcome.unknown,
      'Deletion may have changed the server. Do not retry; inspect the server and reconnect.',
    );
  }
}
