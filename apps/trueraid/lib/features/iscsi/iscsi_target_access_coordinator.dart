import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiTargetAccessCoordinatorProvider =
    Provider<IscsiTargetAccessCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiTargetAccessCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiTargetAccessOutcome { completed, rejected, unknown }

final class IscsiTargetAccessResult {
  const IscsiTargetAccessResult(this.outcome, this.message);
  final IscsiTargetAccessOutcome outcome;
  final String message;
}

final class IscsiTargetAccessReview {
  IscsiTargetAccessReview._(
    this.endpoint,
    this.targetId,
    this.targetName,
    this.portalId,
    this.portalIp,
    this.initiatorId,
    this.initiatorNames,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, targetName, portalIp, proof;
  final int targetId, portalId, initiatorId;
  final List<String> initiatorNames;
  final DateTime issuedAt;
  String get confirmation =>
      'ATTACH ISCSI TARGET #$targetId PORTAL #$portalId INITIATOR #$initiatorId';
}

final class _Snapshot {
  const _Snapshot(
    this.targets,
    this.portals,
    this.initiators,
    this.mappings,
    this.targetDigest,
    this.portalDigest,
    this.initiatorDigest,
    this.mappingDigest,
    this.service,
  );
  final Map<int, Map> targets, portals, initiators;
  final List<Map> mappings;
  final String targetDigest, portalDigest, initiatorDigest, mappingDigest;
  final IscsiServiceStatus service;
  String get proof => jsonEncode([
    targetDigest,
    portalDigest,
    initiatorDigest,
    mappingDigest,
    service.state,
    service.enabledOnBoot,
  ]);
}

/// Associates an explicit initiator and portal with a target that has no LUN.
/// Sequential inventory reads cannot exclude another administrator's race.
final class IscsiTargetAccessCoordinator {
  IscsiTargetAccessCoordinator({
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
  final _issued = <IscsiTargetAccessReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.target.query',
        'iscsi.target.update',
        'iscsi.portal.query',
        'iscsi.initiator.query',
        'iscsi.targetextent.query',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI access methods are unavailable.');
    }
    return method;
  }

  void _guard() {
    if (!isCurrent() || session.endpoint == null) {
      throw StateError('The server connection changed.');
    }
    if (IscsiWriteFence.isUncertain(session)) {
      throw StateError(
        'An iSCSI change is unverified. Reconnect before editing.',
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
      throw StateError('The iSCSI access preflight is unavailable.');
    }
    return result.value;
  }

  String _digest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  ({Map<int, Map> rows, String digest}) _rows(Object? raw, String kind) {
    if (raw is! List || raw.length >= 100 || raw.any((row) => row is! Map)) {
      throw StateError('The $kind inventory is incomplete.');
    }
    final rows = <int, Map>{};
    for (final item in raw) {
      final row = item as Map;
      final id = row['id'];
      if (id is! int || id < 1 || rows.containsKey(id)) {
        throw StateError('The $kind inventory is incomplete.');
      }
      rows[id] = row;
    }
    final ordered = rows.keys.toList()..sort();
    final encoded = jsonEncode([for (final id in ordered) rows[id]]);
    if (encoded.length > 262144 ||
        encoded.contains('[truncated]') ||
        encoded.contains('[redacted]')) {
      throw StateError('The $kind inventory is incomplete.');
    }
    return (rows: rows, digest: _digest([for (final id in ordered) rows[id]]));
  }

  Future<_Snapshot> _snapshot() async {
    final targets = _rows(
      await _read('iscsi.target.query', const []),
      'target',
    );
    final portals = _rows(
      await _read('iscsi.portal.query', const []),
      'portal',
    );
    final initiators = _rows(
      await _read('iscsi.initiator.query', const []),
      'initiator',
    );
    final mappingRows = _rows(
      await _read('iscsi.targetextent.query', const []),
      'mapping',
    );
    final mappingIds = mappingRows.rows.keys.toList()..sort();
    final mappings = [for (final id in mappingIds) mappingRows.rows[id]!];
    for (final mapping in mappings) {
      if (mapping['target'] is! int ||
          !targets.rows.containsKey(mapping['target']) ||
          mapping['extent'] is! int ||
          (mapping['extent'] as int) < 1 ||
          mapping['lunid'] is! int ||
          (mapping['lunid'] as int) < 0) {
        throw StateError('The mapping inventory is incomplete.');
      }
    }
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
      throw StateError('Stop iSCSI and disconnect all clients before editing.');
    }
    return _Snapshot(
      targets.rows,
      portals.rows,
      initiators.rows,
      mappings,
      targets.digest,
      portals.digest,
      initiators.digest,
      mappingRows.digest,
      service,
    );
  }

  ({String name, String ip, List<String> initiators}) _candidate(
    _Snapshot snapshot,
    int targetId,
    int portalId,
    int initiatorId,
  ) {
    final target = snapshot.targets[targetId];
    final portal = snapshot.portals[portalId];
    final initiator = snapshot.initiators[initiatorId];
    if (target == null || portal == null || initiator == null) {
      throw StateError(
        'Choose an existing target, portal and initiator group.',
      );
    }
    final name = target['name'];
    if (target['mode'] != 'ISCSI' ||
        name is! String ||
        name.isEmpty ||
        name.length > 120 ||
        target['groups'] is! List ||
        (target['groups'] as List).isNotEmpty ||
        target['auth_networks'] is! List ||
        (target['auth_networks'] as List).isNotEmpty ||
        snapshot.mappings.any((row) => row['target'] == targetId)) {
      throw StateError('Only an unbound iSCSI target without LUNs qualifies.');
    }
    final listeners = portal['listen'];
    if (listeners is! List ||
        listeners.length != 1 ||
        listeners.single is! Map) {
      throw StateError('Choose a portal with one explicit IPv4 listener.');
    }
    final ip = (listeners.single as Map)['ip'];
    final port = (listeners.single as Map)['port'];
    if (ip is! String ||
        !_explicitIpv4(ip) ||
        port is! int ||
        port < 1 ||
        port > 65535) {
      throw StateError('Choose a portal with one explicit IPv4 listener.');
    }
    final names = initiator['initiators'];
    if (names is! List ||
        names.isEmpty ||
        names.length > 10 ||
        names.any(
          (name) =>
              name is! String ||
              name.length > 223 ||
              !RegExp(r'^(iqn\.|eui\.|naa\.)[a-z0-9.:-]+$').hasMatch(name),
        )) {
      throw StateError('Choose an initiator group with explicit valid names.');
    }
    final unique = names.cast<String>().toSet();
    if (unique.length != names.length) {
      throw StateError('The initiator group has duplicate names.');
    }
    return (
      name: name,
      ip: ip,
      initiators: List.unmodifiable(names.cast<String>()),
    );
  }

  bool _explicitIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return false;
    final numbers = <int>[];
    for (final part in parts) {
      if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) return false;
      final value = int.parse(part);
      if (value > 255) return false;
      numbers.add(value);
    }
    return numbers[0] != 0 &&
        numbers[0] != 127 &&
        numbers[0] < 224 &&
        numbers[3] != 0 &&
        numbers[3] != 255;
  }

  Future<IscsiTargetAccessReview> prepare(
    int targetId,
    int portalId,
    int initiatorId,
  ) async {
    _guard();
    if (!available ||
        _busy ||
        targetId < 1 ||
        portalId < 1 ||
        initiatorId < 1) {
      throw StateError('Choose a target, portal and initiator group.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final candidate = _candidate(snapshot, targetId, portalId, initiatorId);
      final review = IscsiTargetAccessReview._(
        session.endpoint!,
        targetId,
        candidate.name,
        portalId,
        candidate.ip,
        initiatorId,
        candidate.initiators,
        snapshot.proof,
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The access preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiTargetAccessReview review) => _issued.remove(review);

  Future<IscsiTargetAccessResult> execute(
    IscsiTargetAccessReview review,
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
      return const IscsiTargetAccessResult(
        IscsiTargetAccessOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiTargetAccessResult(
        IscsiTargetAccessOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      _candidate(before, review.targetId, review.portalId, review.initiatorId);
      if (before.proof != review.proof) {
        return const IscsiTargetAccessResult(
          IscsiTargetAccessOutcome.rejected,
          'Target or access dependencies changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.target.update'),
          arguments: [
            review.targetId,
            {
              'groups': [_group(review.portalId, review.initiatorId)],
            },
          ],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiTargetAccessResult(
          IscsiTargetAccessOutcome.rejected,
          'The server denied the association. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted ||
          result.value is! Map ||
          !_matchesGroup(result.value as Map, review)) {
        return _unknown();
      }
      final after = await _snapshot();
      final selected = after.targets[review.targetId];
      if (selected == null ||
          !_matchesGroup(selected, review) ||
          _stableTargetDigest(after, review.targetId) !=
              _stableTargetDigest(before, review.targetId) ||
          after.portalDigest != before.portalDigest ||
          after.initiatorDigest != before.initiatorDigest ||
          after.mappingDigest != before.mappingDigest ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return const IscsiTargetAccessResult(
        IscsiTargetAccessOutcome.completed,
        'Only the reviewed portal/initiator group appeared. No LUN was mapped; client access was not tested.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiTargetAccessResult(
              IscsiTargetAccessOutcome.rejected,
              'The access preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  Map<String, Object?> _group(int portalId, int initiatorId) => {
    'portal': portalId,
    'initiator': initiatorId,
    'authmethod': 'NONE',
    'auth': null,
  };

  bool _matchesGroup(Map row, IscsiTargetAccessReview review) {
    final groups = row['groups'];
    if (groups is! List || groups.length != 1 || groups.single is! Map) {
      return false;
    }
    final group = groups.single as Map;
    if (group.keys.any(
      (key) =>
          !const {'portal', 'initiator', 'authmethod', 'auth'}.contains(key),
    )) {
      return false;
    }
    return row['id'] == review.targetId &&
        row['name'] == review.targetName &&
        row['mode'] == 'ISCSI' &&
        group['portal'] == review.portalId &&
        group['initiator'] == review.initiatorId &&
        group['authmethod'] == 'NONE' &&
        group['auth'] == null;
  }

  String _stableTargetDigest(_Snapshot snapshot, int targetId) {
    final ordered = snapshot.targets.keys.toList()..sort();
    return _digest([
      for (final id in ordered)
        if (id == targetId)
          Map<Object?, Object?>.from(snapshot.targets[id]!)..remove('groups')
        else
          snapshot.targets[id],
    ]);
  }

  IscsiTargetAccessResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiTargetAccessResult(
      IscsiTargetAccessOutcome.unknown,
      'The target may have changed. Do not retry; inspect the server and reconnect.',
    );
  }
}
