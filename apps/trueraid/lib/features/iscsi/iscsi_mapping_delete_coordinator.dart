import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';
import 'iscsi_global.dart';
import 'iscsi_write_fence.dart';

final iscsiMappingDeleteCoordinatorProvider =
    Provider<IscsiMappingDeleteCoordinator?>((ref) {
      final session = ref.watch(dashboardActiveSessionProvider);
      if (session?.endpoint == null ||
          session!.repository is! AuthenticatedAdminSession) {
        return null;
      }
      return IscsiMappingDeleteCoordinator(
        session: session,
        api: session.repository as AuthenticatedAdminSession,
        lock: ref.read(serverOperationLockProvider),
        isCurrent: () =>
            identical(ref.read(dashboardActiveSessionProvider), session),
      );
    });

enum IscsiMappingDeleteOutcome { completed, rejected, unknown }

final class IscsiMappingDeleteResult {
  const IscsiMappingDeleteResult(this.outcome, this.message);
  final IscsiMappingDeleteOutcome outcome;
  final String message;
}

final class IscsiMappingDeleteReview {
  IscsiMappingDeleteReview._(
    this.endpoint,
    this.id,
    this.targetId,
    this.targetName,
    this.extentId,
    this.extentName,
    this.lun,
    this.proof,
    this.issuedAt,
  );
  final String endpoint, targetName, extentName, proof;
  final int id, targetId, extentId, lun;
  final DateTime issuedAt;
  String get confirmation =>
      'UNMAP ISCSI LUN #$id TARGET #$targetId EXTENT #$extentId';
}

final class _Mapping {
  const _Mapping(this.id, this.targetId, this.extentId, this.lun);
  final int id, targetId, extentId, lun;
  List<int> get proof => [id, targetId, extentId, lun];
}

final class _Snapshot {
  const _Snapshot(
    this.targets,
    this.targetModes,
    this.extents,
    this.mappings,
    this.service,
    this.targetDigest,
    this.extentDigest,
  );
  final Map<int, String> targets, targetModes, extents;
  final List<_Mapping> mappings;
  final IscsiServiceStatus service;
  final String targetDigest, extentDigest;
  String get proof => jsonEncode([
    targetDigest,
    extentDigest,
    for (final mapping in mappings) mapping.proof,
    service.state,
    service.enabledOnBoot,
  ]);
  _Mapping mapping(int id) => mappings.singleWhere(
    (mapping) => mapping.id == id,
    orElse: () => throw StateError('The LUN mapping is unavailable.'),
  );
}

/// Removes one exact target-to-extent association, never an extent or target.
/// Sequential server reads cannot exclude concurrent external administration.
final class IscsiMappingDeleteCoordinator {
  IscsiMappingDeleteCoordinator({
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
  final _issued = <IscsiMappingDeleteReview>{};
  bool _busy = false;

  bool get locked => _busy || IscsiWriteFence.isUncertain(session);
  bool get available =>
      session.endpoint != null &&
      api.adminCatalog.versionSupported &&
      [
        'iscsi.target.query',
        'iscsi.extent.query',
        'iscsi.targetextent.query',
        'iscsi.targetextent.delete',
        'service.query',
        'iscsi.global.sessions',
      ].every((name) => api.adminCatalog.method(name)?.supported == true);

  AdminMethodSpec _method(String name) {
    final method = api.adminCatalog.method(name);
    if (!available || method == null || !method.supported) {
      throw StateError('Required iSCSI mapping methods are unavailable.');
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
      throw StateError('The iSCSI mapping preflight is unavailable.');
    }
    return result.value;
  }

  ({Map<int, String> labels, Map<int, String> modes, String digest}) _inventory(
    Object? raw,
    String kind,
  ) {
    if (raw is! List || raw.length >= 100 || raw.any((row) => row is! Map)) {
      throw StateError('The $kind inventory is incomplete.');
    }
    final rows = <Map>[];
    final labels = <int, String>{};
    final modes = <int, String>{};
    for (final item in raw) {
      final row = item as Map;
      final id = row['id'], name = row['name'];
      if (id is! int ||
          id < 1 ||
          labels.containsKey(id) ||
          name is! String ||
          name.isEmpty ||
          name.length > 120 ||
          name == '[truncated]' ||
          name == '[redacted]') {
        throw StateError('The $kind inventory is incomplete.');
      }
      if (kind == 'target' && !['ISCSI', 'FC', 'BOTH'].contains(row['mode'])) {
        throw StateError('The target inventory is incomplete.');
      }
      labels[id] = name;
      if (kind == 'target') modes[id] = row['mode'] as String;
      rows.add(row);
    }
    rows.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    final encoded = jsonEncode(rows);
    if (encoded.length > 262144 ||
        encoded.contains('[truncated]') ||
        encoded.contains('[redacted]')) {
      throw StateError('The $kind inventory is incomplete.');
    }
    return (
      labels: labels,
      modes: modes,
      digest: sha256.convert(utf8.encode(encoded)).toString(),
    );
  }

  Future<_Snapshot> _snapshot() async {
    final targetRows = await _read('iscsi.target.query', const []);
    final extentRows = await _read('iscsi.extent.query', const []);
    final rawMappings = await _read('iscsi.targetextent.query', const []);
    final targetInventory = _inventory(targetRows, 'target');
    final extentInventory = _inventory(extentRows, 'extent');
    if (rawMappings is! List ||
        rawMappings.length >= 100 ||
        rawMappings.any((row) => row is! Map)) {
      throw StateError('The LUN mapping inventory is incomplete.');
    }
    final mappings = <_Mapping>[];
    final ids = <int>{};
    for (final item in rawMappings) {
      final row = item as Map;
      final id = row['id'], target = row['target'];
      final extent = row['extent'], lun = row['lunid'];
      if (id is! int ||
          id < 1 ||
          !ids.add(id) ||
          target is! int ||
          !targetInventory.labels.containsKey(target) ||
          extent is! int ||
          !extentInventory.labels.containsKey(extent) ||
          lun is! int ||
          lun < 0) {
        throw StateError('The LUN mapping inventory is incomplete.');
      }
      mappings.add(_Mapping(id, target, extent, lun));
    }
    mappings.sort((a, b) => a.id.compareTo(b.id));
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
        'Stop iSCSI and disconnect all clients before unmapping a LUN.',
      );
    }
    final snapshot = _Snapshot(
      targetInventory.labels,
      targetInventory.modes,
      extentInventory.labels,
      mappings,
      service,
      targetInventory.digest,
      extentInventory.digest,
    );
    if (snapshot.proof.length > 32768) {
      throw StateError('The iSCSI dependency inventory is too large.');
    }
    return snapshot;
  }

  Future<IscsiMappingDeleteReview> prepare(int id) async {
    _guard();
    if (!available || _busy || id < 1) {
      throw StateError('Choose a LUN mapping to review.');
    }
    final owner = lock.acquire();
    if (owner == null) {
      throw StateError('Another server operation is in progress.');
    }
    _busy = true;
    _issued.clear();
    try {
      final snapshot = await _snapshot();
      final mapping = snapshot.mapping(id);
      if (snapshot.targetModes[mapping.targetId] != 'ISCSI') {
        throw StateError(
          'Only iSCSI-only targets are supported for this unmap.',
        );
      }
      final review = IscsiMappingDeleteReview._(
        session.endpoint!,
        id,
        mapping.targetId,
        snapshot.targets[mapping.targetId]!,
        mapping.extentId,
        snapshot.extents[mapping.extentId]!,
        mapping.lun,
        snapshot.proof,
        _now().toUtc(),
      );
      _issued.add(review);
      return review;
    } on StateError {
      rethrow;
    } on Object {
      throw StateError('The LUN mapping preflight failed. Nothing was sent.');
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  void cancel(IscsiMappingDeleteReview review) => _issued.remove(review);

  Future<IscsiMappingDeleteResult> execute(
    IscsiMappingDeleteReview review,
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
      return const IscsiMappingDeleteResult(
        IscsiMappingDeleteOutcome.rejected,
        'Review expired or confirmation did not match. Nothing was sent.',
      );
    }
    final owner = lock.acquire();
    if (owner == null) {
      return const IscsiMappingDeleteResult(
        IscsiMappingDeleteOutcome.rejected,
        'Another server operation is in progress. Nothing was sent.',
      );
    }
    _busy = true;
    var sent = false;
    try {
      final before = await _snapshot();
      final mapping = before.mapping(review.id);
      if (before.targetModes[mapping.targetId] != 'ISCSI') {
        return const IscsiMappingDeleteResult(
          IscsiMappingDeleteOutcome.rejected,
          'The target mode changed. Nothing was sent.',
        );
      }
      if (before.proof != review.proof) {
        return const IscsiMappingDeleteResult(
          IscsiMappingDeleteOutcome.rejected,
          'Target, extent, LUN or service state changed since review. Nothing was sent.',
        );
      }
      sent = true;
      final result = await api.invokeAdmin(
        AdminRequest(
          method: _method('iscsi.targetextent.delete'),
          arguments: [review.id, false],
        ),
      );
      if (result is AdminFailed && result.reason == AdminFailureReason.denied) {
        return const IscsiMappingDeleteResult(
          IscsiMappingDeleteOutcome.rejected,
          'The server denied the unmap. No change was confirmed.',
        );
      }
      if (result is! AdminCompleted || result.value != true) return _unknown();
      final after = await _snapshot();
      final expected = [
        for (final mapping in before.mappings)
          if (mapping.id != review.id) mapping.proof,
      ];
      if (after.targetDigest != before.targetDigest ||
          after.extentDigest != before.extentDigest ||
          jsonEncode([for (final mapping in after.mappings) mapping.proof]) !=
              jsonEncode(expected) ||
          after.service.state != before.service.state ||
          after.service.enabledOnBoot != before.service.enabledOnBoot) {
        return _unknown();
      }
      return const IscsiMappingDeleteResult(
        IscsiMappingDeleteOutcome.completed,
        'Only the selected LUN mapping disappeared; targets and extents remained unchanged.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const IscsiMappingDeleteResult(
              IscsiMappingDeleteOutcome.rejected,
              'The LUN mapping preflight failed. Nothing was sent.',
            );
    } finally {
      _busy = false;
      lock.release(owner);
    }
  }

  IscsiMappingDeleteResult _unknown() {
    IscsiWriteFence.markUncertain(session);
    _issued.clear();
    return const IscsiMappingDeleteResult(
      IscsiMappingDeleteOutcome.unknown,
      'The unmap may have changed the server. Do not retry; inspect the server and reconnect.',
    );
  }
}
