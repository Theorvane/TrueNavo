import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_listener_choices.dart';
import 'iscsi_write_fence.dart';

final iscsiPortalCreateCoordinatorProvider =
    Provider<IscsiPortalCreateCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiPortalCreateCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiPortalCreateOutcome { completed, rejected, unknown }

final class IscsiPortalCreateResult {
  const IscsiPortalCreateResult(this.outcome, this.message);
  final IscsiPortalCreateOutcome outcome;
  final String message;
}

final class IscsiPortalCreateReview {
  IscsiPortalCreateReview._({
    required this.endpoint,
    required this.ip,
    required this.comment,
    required this.proof,
    required this.issuedAt,
  });
  final String endpoint, ip, comment, proof;
  final DateTime issuedAt;
  String get confirmation => 'CREATE ISCSI PORTAL $ip';
}

final class _Snapshot {
  const _Snapshot(this.portals, this.targets, this.choices, this.service);
  final List<List<Object>> portals, targets;
  final Set<String> choices;
  final IscsiServiceStatus service;
  String get proof => jsonEncode([
    portals,
    targets,
    choices.toList()..sort(),
    service.state,
    service.enabledOnBoot,
  ]);
  bool usesIp(String ip) => portals.any(
    (portal) => (portal[2] as List).cast<List<Object>>().any(
      (listener) => listener[0] == ip,
    ),
  );
  bool references(int id) => targets.any(
    (target) => (target[4] as List).cast<List<Object?>>().any(
      (access) => access[0] == id,
    ),
  );
}

/// Creates one unassigned portal on a server-offered static IPv4 address.
/// Sequential preflight reads cannot exclude another administrator's races.
final class IscsiPortalCreateCoordinator {
  IscsiPortalCreateCoordinator({
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
  final _issued = <IscsiPortalCreateReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.portal.query',
        'iscsi.portal.create',
        'iscsi.portal.listen_ip_choices',
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

  static bool validIp(String ip) {
    final octets = ip.split('.');
    if (octets.length != 4 || ip == '0.0.0.0' || ip == '255.255.255.255') {
      return false;
    }
    return octets.every((part) {
      if (!RegExp(r'^(?:0|[1-9][0-9]{0,2})$').hasMatch(part)) return false;
      return int.parse(part) <= 255;
    });
  }

  Future<_Snapshot> _snapshot() async {
    final rawPortals = await _read('iscsi.portal.query', const []);
    final rawTargets = await _read('iscsi.target.query', const []);
    final rawChoices = await _read('iscsi.portal.listen_ip_choices', const []);
    if (rawPortals is! List ||
        rawPortals.length >= 100 ||
        rawTargets is! List ||
        rawTargets.length >= 100 ||
        rawPortals.any((row) => row is! Map) ||
        rawTargets.any((row) => row is! Map) ||
        rawChoices is! Map ||
        rawChoices.length >= 100) {
      throw StateError(
        'The portal, target or address inventory is incomplete.',
      );
    }
    final choices = IscsiListenerChoices.parse(rawChoices).addresses;
    if (choices.any((ip) => ip == '[truncated]' || ip == '[redacted]')) {
      throw StateError('The listener choices are incomplete.');
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
          listen.isEmpty ||
          listen.length >= 100) {
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
        'Stop iSCSI and disconnect all clients before creating a portal.',
      );
    }
    final snapshot = _Snapshot(portals, targets, choices, service);
    if (snapshot.proof.length > 32768) {
      throw StateError('The iSCSI dependency inventory is too large.');
    }
    return snapshot;
  }

  void _candidate(_Snapshot snapshot, String ip) {
    if (!snapshot.choices.contains(ip)) {
      throw StateError(
        'The server does not offer this static listener address.',
      );
    }
    if (snapshot.usesIp(ip)) {
      throw StateError('This address is already used by a portal.');
    }
    if (snapshot.portals.length >= 99) {
      throw StateError('The bounded inventory cannot verify another portal.');
    }
  }

  Future<IscsiPortalCreateReview> prepare(String ip, String comment) async {
    _guard();
    if (!available ||
        _busy ||
        !validIp(ip) ||
        comment.length > 128 ||
        comment.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError(
        'Enter one server-offered IPv4 address and a short comment.',
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
      _candidate(snapshot, ip);
      final review = IscsiPortalCreateReview._(
        endpoint: session.endpoint!,
        ip: ip,
        comment: comment,
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

  void cancel(IscsiPortalCreateReview review) => _issued.remove(review);

  Future<IscsiPortalCreateResult> execute(
    IscsiPortalCreateReview review,
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
      return const IscsiPortalCreateResult(
        IscsiPortalCreateOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiPortalCreateResult(
        IscsiPortalCreateOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _candidate(before, review.ip);
      if (before.proof != review.proof) {
        return const IscsiPortalCreateResult(
          IscsiPortalCreateOutcome.rejected,
          'Portal, target, address or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.portal.create'),
          arguments: [
            {
              'listen': [
                {'ip': review.ip},
              ],
              'comment': review.comment,
            },
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiPortalCreateResult(
          IscsiPortalCreateOutcome.rejected,
          'The server denied creation. No portal was confirmed.',
        );
      }
      if (result is! AdminCompleted || result.value is! Map) return _unknown();
      final created = result.value as Map;
      final id = created['id'],
          tag = created['tag'],
          listen = created['listen'];
      if (id is! int ||
          id < 1 ||
          tag is! int ||
          tag < 1 ||
          listen is! List ||
          listen.length != 1 ||
          listen.single is! Map ||
          (listen.single as Map)['ip'] != review.ip ||
          (listen.single as Map)['port'] is! int ||
          ((listen.single as Map)['port'] as int) < 1 ||
          ((listen.single as Map)['port'] as int) > 65535 ||
          created['comment'] != review.comment ||
          before.portals.any((portal) => portal[0] == id || portal[1] == tag)) {
        return _unknown();
      }
      final after = await _snapshot();
      final expectedNew = <Object>[
        id,
        tag,
        <List<Object>>[
          [review.ip, (listen.single as Map)['port'] as int],
        ],
        review.comment,
      ];
      final newRows = after.portals.where((portal) => portal[0] == id).toList();
      if (newRows.length != 1 ||
          jsonEncode(newRows.single) != jsonEncode(expectedNew) ||
          after.portals.length != before.portals.length + 1 ||
          jsonEncode([
                for (final portal in after.portals)
                  if (portal[0] != id) portal,
              ]) !=
              jsonEncode(before.portals) ||
          jsonEncode(after.targets) != jsonEncode(before.targets) ||
          after.references(id) ||
          jsonEncode(after.choices.toList()..sort()) !=
              jsonEncode(before.choices.toList()..sort()) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return IscsiPortalCreateResult(
        IscsiPortalCreateOutcome.completed,
        'Portal #$id was found unassigned at ${review.ip} in a fresh inventory. Client reachability was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiPortalCreateResult(
              IscsiPortalCreateOutcome.rejected,
              'The portal preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiPortalCreateResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiPortalCreateResult(
      IscsiPortalCreateOutcome.unknown,
      'Creation may have changed the server. Do not retry; inspect the server and reconnect.',
    );
  }
}
